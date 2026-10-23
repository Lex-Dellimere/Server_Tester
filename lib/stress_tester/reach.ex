defmodule StressTester.Reach do
  @moduledoc """
  The Reach game server, protocol 2: the path a real player takes.

    1. log in over HTTP (`/v1/auth/login`)
    2. open the lobby socket and say hello (`/v1/lobby`)
    3. get a seat: `battle.join` for a place, or `mm.queue` and wait for the match
    4. connect over encrypted UDP with the ticket and fight

  One iteration is one tick of play (default every 33 ms): the bot sends an
  input packet, and everything the server sends is read, decoded, and acked in
  between. When a battle ends the bot goes back to the lobby and takes another
  seat, so a long run keeps joining and leaving fights.

  Users are bots named `vigil-0001`, `accord-0001`, … (sides alternate), made
  on first login with the password `stress`. That only works on a server with
  stress logins on: dev has them, and elsewhere set `REACH_STRESS=1`. Names
  `…-9990` to `…-9999` are kept for the checks.
  """

  @behaviour StressTester.Target

  alias StressTester.Reach.{Api, Bot, Checks, Fight, Lobby}
  alias StressTester.{Metrics, Net, Units, WebSocket}

  @sides ~w(host vigil accord holdfast)
  @max_bot 9_989
  @queue_wait 120_000
  @ping_ms 5_000

  @impl true
  def options do
    [
      address: :string,
      place: :string,
      planet: :string,
      mode: :string,
      sides: :string,
      password: :string,
      per_place: :integer,
      udp_host: :string,
      chat: :string,
      offset: :integer,
      timeout: :string,
      insecure: :boolean,
      metrics_token: :string
    ]
  end

  def usage do
    """
    stress reach [HOST:PORT] [options]       (default 127.0.0.1:4001)
      --mode direct|queue      take a seat in --place (default), or let the matchmaker pick
      --place crystal-gate/r1  where direct bots fight
      --planet crystal-gate    where queued bots queue
      --per-place 100          direct bots fill r1, then r2, … this many at a time
      --sides vigil,accord     bots alternate between these sides
      --chat 5s                each bot says something to its team this often (off by default)
      --offset N               start bot numbers after N, so two runs do not share bots
      --udp-host HOST          send fight packets here instead of where the ticket says
      --password stress        the bots' password
      --timeout 5s             per request, and to connect
      --insecure               do not check the TLS certificate
      --metrics-token TOKEN    for the server's /metrics when it is not on this machine (REACH_METRICS_TOKEN)
      --scrape off             do not read the server's own metrics (it is read from /metrics by default)
    The server needs stress logins on (dev has them; elsewhere REACH_STRESS=1).
    Checks (before the load): #{Enum.join(Checks.names(), ", ")}.
    """
  end

  @impl true
  def defaults(_opts) do
    %{
      vus: 10,
      pace: "33ms",
      duration: "20s",
      thresholds: [
        "vu.connect_failed:count==0",
        "vu.lost:count==0",
        "reach.snapshot:count>0",
        "reach.decode_error:count==0",
        "reach.snapshot_loss<5%",
        "iterations.failed:ratio<1%"
      ],
      live: ["reach.snapshot", "reach.rtt"]
    }
  end

  @impl true
  def init(opts) do
    address = opts[:address] || opts[:url] || "127.0.0.1:4001"
    place = opts[:place] || if(opts[:planet], do: opts[:planet] <> "/r1", else: "crystal-gate/r1")

    sides =
      (opts[:sides] || "vigil,accord")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    with {:ok, origin} <- Net.origin(address),
         {:ok, timeout} <- Units.ms(opts[:timeout] || "5s", :s),
         {:ok, chat_ms} <- Units.ms(opts[:chat], :s),
         {:ok, mode} <- mode(opts[:mode]),
         :ok <- sides_ok(sides) do
      {:ok,
       %{
         address: address,
         origin: origin,
         tls: %{insecure: opts[:insecure] == true},
         place: place,
         planet: opts[:planet] || hd(String.split(place, "/")),
         mode: mode,
         sides: sides,
         password: opts[:password] || "stress",
         per_place: opts[:per_place] || 100,
         udp_host: opts[:udp_host],
         chat_ms: chat_ms,
         offset: opts[:offset] || 0,
         timeout: timeout,
         metrics_token: opts[:metrics_token]
       }}
    end
  end

  defp mode(nil), do: {:ok, :direct}
  defp mode("direct"), do: {:ok, :direct}
  defp mode("queue"), do: {:ok, :queue}
  defp mode(other), do: {:error, "mode #{inspect(other)} is not direct or queue"}

  defp sides_ok(sides) do
    case Enum.reject(sides, &(&1 in @sides)) do
      [] ->
        if sides == [], do: {:error, "give at least one side"}, else: :ok

      bad ->
        {:error, "unknown side #{Enum.join(bad, ", ")}; sides are #{Enum.join(@sides, ", ")}"}
    end
  end

  @impl true
  def describe(s) do
    where = if s.mode == :queue, do: "queue #{s.planet}", else: s.place
    "reach #{s.address}, #{where}, sides #{Enum.join(s.sides, "+")} (protocol 2)"
  end

  @impl true
  def checks(shared, which), do: Checks.list(shared, which)

  # the server publishes tick times and packet counts at /metrics (on localhost, or with its token)
  @impl true
  def scrape(shared) do
    o = shared.origin
    url = "#{if o.tls, do: "https", else: "http"}://#{o.host}:#{o.port}/metrics"
    token = if shared.metrics_token, do: [{"x-metrics-token", shared.metrics_token}], else: []
    %{url: url, headers: token, insecure: shared.tls.insecure}
  end

  @impl true
  def derive(c, _shared) do
    snaps = c["reach.snapshot"] || 0
    inputs = c["reach.input"] || 0

    %{}
    |> put_ratio(
      "reach.decode_error_ratio",
      c["reach.decode_error"] || 0,
      snaps + (c["reach.decode_error"] || 0)
    )
    |> put_ratio("reach.correction_ratio", c["reach.correct"] || 0, inputs)
    |> put_ratio(
      "reach.snapshot_loss",
      c["reach.snapshot_lost"] || 0,
      c["reach.snapshot_expected"] || 0
    )
  end

  defp put_ratio(map, _key, _n, 0), do: map
  defp put_ratio(map, key, n, d), do: Map.put(map, key, n / d)

  # -- a user

  @impl true
  def connect(shared, vu) do
    with {:ok, name} <- bot_name(shared, vu),
         {:ok, tokens} <- Api.login(shared, name),
         {:ok, ws, _welcome, pushes} <- Lobby.connect(shared, tokens["access_token"], name),
         place = place_for(shared, vu),
         {:ok, ws, fight} <- first_fight(shared, ws, place, pushes) do
      Metrics.count("reach.rounds")
      now = mono()
      # from here on the lobby talks to us: pings, pushes, the next battle's ticket
      :ok = WebSocket.active(ws, 32)

      {:ok,
       %{
         shared: shared,
         name: name,
         place: place,
         ws: ws,
         fight: fight,
         bot: Bot.new(shared, now),
         pending: %{},
         next_id: 10,
         requested: false,
         retry_at: now,
         next_ping: now + @ping_ms
       }}
    else
      {:error, reason} -> {:error, Api.explain(reason)}
    end
  end

  defp first_fight(%{mode: :direct} = shared, ws, place, _pushes) do
    with {:ok, ws, ticket, _pushes} <- Lobby.ticket(shared, ws, place),
         {:ok, fight} <- open_fight(shared, ticket) do
      {:ok, ws, fight}
    else
      {:error, reason} -> WebSocket.close(ws) && {:error, reason}
    end
  end

  defp first_fight(%{mode: :queue} = shared, ws, _place, _pushes) do
    with {:ok, ws, ticket} <- Lobby.queue(shared, ws, shared.planet, @queue_wait),
         {:ok, fight} <- open_fight(shared, ticket) do
      {:ok, ws, fight}
    else
      {:error, reason} -> WebSocket.close(ws) && {:error, reason}
    end
  end

  defp open_fight(shared, ticket),
    do: Fight.open(ticket, %{timeout: shared.timeout, udp_host: shared.udp_host})

  @impl true
  def iterate(st) do
    now = mono()
    st = ping(st, now)

    case st.fight do
      nil ->
        {:ok, between(st, now)}

      fight ->
        {fight, bot} = Bot.tick(fight, st.bot, st.shared, now)
        {:ok, %{st | fight: fight, bot: bot}}
    end
  end

  # between battles: ask for the next seat, no faster than every couple of seconds
  defp between(%{requested: true} = st, _now), do: st
  defp between(%{retry_at: at} = st, now) when now < at, do: st

  defp between(st, now) do
    id = st.next_id

    {op, kind} =
      case st.shared.mode do
        :direct -> {%{"op" => "battle.join", "id" => id, "place" => st.place}, :ticket}
        :queue -> {%{"op" => "mm.queue", "id" => id, "planet" => st.shared.planet}, :queue}
      end

    case Lobby.send_op(st.ws, op) do
      :ok ->
        %{
          st
          | next_id: id + 1,
            requested: true,
            pending: Map.put(st.pending, id, {kind, Metrics.now()}),
            retry_at: now + 2_000
        }

      {:error, _} ->
        %{st | retry_at: now + 2_000}
    end
  end

  defp ping(%{next_ping: at} = st, now) when now >= at do
    id = st.next_id

    case Lobby.send_op(st.ws, %{"op" => "ping", "id" => id}) do
      :ok ->
        %{
          st
          | next_id: id + 1,
            next_ping: now + @ping_ms,
            pending: Map.put(st.pending, id, {:ping, Metrics.now()})
        }

      {:error, _} ->
        %{st | next_ping: now + @ping_ms}
    end
  end

  defp ping(st, _now), do: st

  # -- what arrives between iterations

  @impl true
  def handle_message({:udp, sock, _ip, _port, data}, %{fight: %{sock: sock}} = st) do
    case Fight.packet(st.fight, data) do
      {:ok, fight} -> {:ok, %{st | fight: fight}}
      {:bye, reason, fight} -> bye(st, fight, reason)
    end
  end

  def handle_message({:udp_passive, sock}, %{fight: %{sock: sock}} = st) do
    Fight.rearm(st.fight)
    {:ok, st}
  end

  def handle_message({tag, sock, data}, %{ws: %{sock: {_, sock}}} = st)
      when tag in [:tcp, :ssl] do
    case WebSocket.feed(st.ws, data) do
      {:ok, ws, msgs} -> lobby(%{st | ws: ws}, msgs)
      {:error, reason} -> {:stop, {:lobby, reason}, st}
    end
  end

  def handle_message({tag, sock}, %{ws: %{sock: {_, sock}}} = st)
      when tag in [:tcp_passive, :ssl_passive] do
    :ok = WebSocket.active(st.ws, 32)
    {:ok, st}
  end

  def handle_message({tag, sock}, %{ws: %{sock: {_, sock}}} = st)
      when tag in [:tcp_closed, :ssl_closed],
      do: {:stop, {:lobby, :closed}, st}

  def handle_message({tag, sock, reason}, %{ws: %{sock: {_, sock}}} = st)
      when tag in [:tcp_error, :ssl_error],
      do: {:stop, {:lobby, reason}, st}

  def handle_message(_other, st), do: {:ok, st}

  # a battle that ends is not an error: back to the lobby for another
  defp bye(st, fight, :closed) do
    Metrics.count("reach.rounds_ended")
    Fight.close(fight)
    {:ok, %{st | fight: nil, bot: Bot.new(st.shared, mono()), retry_at: mono() + 1_000}}
  end

  defp bye(st, fight, reason), do: {:stop, {:bye, reason}, %{st | fight: fight}}

  defp lobby(st, []), do: {:ok, st}

  defp lobby(st, [msg | rest]) do
    case msg do
      {:text, json} ->
        case lobby_message(st, Lobby.decode(json)) do
          {:ok, st} -> lobby(st, rest)
          stop -> stop
        end

      {:close, code, reason} ->
        Metrics.count("lobby.closed.#{code}")
        {:stop, {:lobby, {:closed, code, reason}}, st}

      _ ->
        lobby(st, rest)
    end
  end

  defp lobby_message(st, %{"re" => id} = m) do
    case Map.pop(st.pending, id) do
      {nil, _} ->
        {:ok, st}

      {{:ping, t0}, pending} ->
        Metrics.since("reach.lobby_rtt", t0)
        {:ok, %{st | pending: pending}}

      {{:ticket, t0}, pending} ->
        Metrics.since("reach.ticket", t0)
        got_ticket(%{st | pending: pending}, m)

      {{:queue, _}, pending} ->
        st = %{st | pending: pending}
        if m["ok"] == false, do: seat_failed(st, m["error"]), else: {:ok, st}
    end
  end

  defp lobby_message(st, %{"op" => "mm.matched"} = m), do: got_ticket(st, m)

  defp lobby_message(st, %{"op" => "mm.status", "status" => status})
       when status in ["cancelled", "timeout", "error"],
       do: seat_failed(st, status)

  defp lobby_message(st, %{"op" => op}) do
    Metrics.count("reach.push.#{op}")
    {:ok, st}
  end

  defp lobby_message(st, _), do: {:ok, st}

  defp got_ticket(st, %{"ok" => false} = m), do: seat_failed(st, m["error"])

  defp got_ticket(%{fight: nil} = st, ticket) do
    case open_fight(st.shared, ticket) do
      {:ok, fight} ->
        Metrics.count("reach.rounds")
        {:ok, %{st | fight: fight, requested: false}}

      {:error, reason} ->
        seat_failed(st, reason)
    end
  end

  defp got_ticket(st, _ticket), do: {:ok, st}

  defp seat_failed(st, reason) do
    Metrics.count("reach.seat_failed")
    Metrics.error("seat", reason)
    {:ok, %{st | requested: false, retry_at: mono() + 2_000}}
  end

  @impl true
  def disconnect(st) do
    if st.fight, do: Fight.bye(st.fight)
    WebSocket.close(st.ws)
  end

  # -- names and places

  def bot_name(shared, vu) do
    i = vu + shared.offset
    count = length(shared.sides)
    side = Enum.at(shared.sides, rem(i, count))
    n = div(i - 1, count) + 1

    if n > @max_bot,
      do:
        {:error,
         "bot #{n} of #{side}: names only go to #{@max_bot} per side (use fewer users or more sides)"},
      else: {:ok, side <> "-" <> String.pad_leading(Integer.to_string(n), 4, "0")}
  end

  # direct bots fill r1, then r2, … so a big run is many fights, not one that is full
  def place_for(shared, vu) do
    with [planet, region] <- String.split(shared.place, "/", parts: 2),
         [_, first] <- Regex.run(~r/^r(\d+)$/, region) do
      index = div(vu + shared.offset - 1, max(shared.per_place, 1))
      "#{planet}/r#{String.to_integer(first) + index}"
    else
      _ -> shared.place
    end
  end

  defp mono, do: System.monotonic_time(:millisecond)
end
