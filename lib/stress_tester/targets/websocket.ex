defmodule StressTester.Targets.WebSocket do
  @moduledoc """
  WebSocket services: many open sockets, each sending a message per iteration.

      stress ws ws://127.0.0.1:4001/v1/lobby --vus 1000 --pace 1s --message '{"op":"ping","id":{{iteration}}}'
      stress ws wss://chat.example.com/socket --mode reply --match '"re"'

  `--mode send` (default) sends and counts whatever comes back. `--mode reply`
  waits after each message for the next one from the server (or the next one
  that contains `--match`) and records the round trip as `ws.reply`.

  Records `ws.upgrade`, `ws.sent`, `ws.received`, the bytes each way, and
  `ws.closed.<code>` when the server closes a socket.
  """

  @behaviour StressTester.Target

  alias StressTester.{Metrics, Net, Template, Units, WebSocket}

  @impl true
  def options do
    [
      url: :string,
      address: :string,
      message: :string,
      binary: :boolean,
      mode: :string,
      match: :string,
      header: :keep,
      subprotocol: :string,
      timeout: :string,
      insecure: :boolean
    ]
  end

  def usage do
    """
    stress ws URL [options]
      --message TEXT          what each iteration sends; may use {{vu}}, {{iteration}}, {{rand:N}}
      --binary                send it as a binary frame
      --mode send|reply       reply waits for an answer and times it
      --match TEXT            in reply mode, the answer must contain this
      --header 'k: v'         on the upgrade request
      --subprotocol NAME
      --timeout 10s
      --insecure              do not check the TLS certificate
    """
  end

  @impl true
  def defaults(opts) do
    reply = (opts[:mode] || "send") == "reply"

    %{
      vus: 10,
      pace: "1s",
      thresholds:
        ["vu.connect_failed:count==0", "vu.lost:count==0"] ++
          if(reply, do: ["iterations.failed:ratio<1%"], else: []),
      live: if(reply, do: ["ws.reply"], else: ["ws.received"])
    }
  end

  @impl true
  def init(opts) do
    url = opts[:address] || opts[:url]

    with {:ok, origin} <-
           if(url, do: Net.origin(url, "ws"), else: {:error, "give a ws:// or wss:// URL"}),
         {:ok, timeout} <- Units.ms(opts[:timeout] || "10s", :s),
         mode when mode in ["send", "reply"] <- opts[:mode] || "send" do
      headers =
        (opts[:header] || [])
        |> Enum.map(&String.split(&1, ":", parts: 2))
        |> Enum.map(fn [k, v] -> {String.trim(k), String.trim(v)} end)

      {:ok,
       %{
         url: url,
         origin: origin,
         message: Template.compile(opts[:message] || "ping"),
         opcode: if(opts[:binary], do: 2, else: 1),
         reply: mode == "reply",
         match: opts[:match],
         timeout: timeout,
         ws: %{headers: headers, protocols: opts[:subprotocol], insecure: opts[:insecure] == true}
       }}
    else
      {:error, _} = e -> e
      mode -> {:error, "mode #{inspect(mode)} is not send or reply"}
    end
  end

  @impl true
  def describe(s),
    do: "websocket #{s.url} (#{if s.reply, do: "send and wait for a reply", else: "send"})"

  @impl true
  def connect(s, vu) do
    case WebSocket.connect(s.origin, s.ws, s.timeout) do
      {:ok, ws, timing} ->
        Metrics.observe("ws.upgrade", timing.upgrade_us)
        :ok = WebSocket.active(ws, 32)
        {:ok, %{s: s, ws: ws, vars: %{"vu" => vu, "iteration" => 0}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def iterate(st) do
    vars = %{st.vars | "iteration" => st.vars["iteration"] + 1}
    st = %{st | vars: vars}
    payload = Template.render(st.s.message, vars)

    case WebSocket.send_frame(st.ws, st.s.opcode, payload) do
      :ok ->
        Metrics.count("ws.sent")
        Metrics.count("ws.bytes_out", byte_size(payload))
        if st.s.reply, do: await_reply(st, Metrics.now()), else: {:ok, st}

      {:error, reason} ->
        {:stop, {:send, reason}, st}
    end
  end

  defp await_reply(st, t0) do
    sock = Net.raw(st.ws.sock)
    wait = max(st.s.timeout - div(Metrics.now() - t0, 1_000), 0)

    receive do
      {kind, ^sock, data} when kind in [:tcp, :ssl] ->
        case take(st, data) do
          {:ok, st, msgs} ->
            if Enum.any?(msgs, &reply?(&1, st.s.match)) do
              Metrics.since("ws.reply", t0)
              {:ok, st}
            else
              await_reply(st, t0)
            end

          {:stop, reason, st} ->
            {:stop, reason, st}
        end

      {kind, ^sock} when kind in [:tcp_passive, :ssl_passive] ->
        :ok = WebSocket.active(st.ws, 32)
        await_reply(st, t0)

      {kind, ^sock} when kind in [:tcp_closed, :ssl_closed] ->
        {:stop, :closed, st}
    after
      wait -> {:error, :timeout, st}
    end
  end

  defp reply?({kind, payload}, match) when kind in [:text, :binary],
    do: match == nil or String.contains?(payload, match)

  defp reply?(_, _), do: false

  @impl true
  def handle_message({kind, _sock, data}, st) when kind in [:tcp, :ssl] do
    case take(st, data) do
      {:ok, st, _msgs} -> {:ok, st}
      other -> other
    end
  end

  def handle_message({kind, _sock}, st) when kind in [:tcp_passive, :ssl_passive] do
    :ok = WebSocket.active(st.ws, 32)
    {:ok, st}
  end

  def handle_message({kind, _sock}, st) when kind in [:tcp_closed, :ssl_closed],
    do: {:stop, :closed, st}

  def handle_message(_msg, st), do: {:ok, st}

  defp take(st, data) do
    Metrics.count("ws.bytes_in", byte_size(data))

    case WebSocket.feed(st.ws, data) do
      {:ok, ws, msgs} ->
        st = %{st | ws: ws}

        Enum.reduce_while(msgs, {:ok, st, msgs}, fn
          {:close, code, _reason}, {:ok, st, _} ->
            Metrics.count("ws.closed.#{code}")
            {:halt, {:stop, {:closed, code}, st}}

          {kind, _}, acc when kind in [:text, :binary] ->
            Metrics.count("ws.received")
            {:cont, acc}

          _, acc ->
            {:cont, acc}
        end)

      {:error, reason} ->
        {:stop, {:frame, reason}, st}
    end
  end

  @impl true
  def disconnect(st), do: WebSocket.close(st.ws)
end
