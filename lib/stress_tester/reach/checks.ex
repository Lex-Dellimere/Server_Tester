defmodule StressTester.Reach.Checks do
  @moduledoc """
  One-off correctness tests of the server's doors, run once before the load
  while the server is quiet. A load test that passes on a server that cannot
  log anyone in, or that never encrypts correctly, is worth nothing; these say
  so first.

  They use bot names ending `-9990` to `-9998`, which load users never reach.
  Each is independent and they run at the same time.

      health            GET /health answers ok
      meta              /v1/meta says protocol 2 and a tick length
      bad-password      a wrong password is refused with 401
      unauthenticated   /v1/me without a good token is refused with 401
      login             a login returns tokens and /v1/me knows them
      refresh-rotation  a refresh token works once; reusing it ends that login
      lobby             hello is welcomed and ping is answered
      bad-hello         a lobby hello with a bad token is refused
      fight             ticket → accept → snapshots decode, own body present, no decode errors
      replace           a second fight by the same character replaces the first
      rejoin            (all) go quiet, come back, and find the same body where it was left (takes ~9 s)
  """

  alias StressTester.Reach.Checks.Still
  alias StressTester.Reach.{Api, Bot, Fight, Lobby}
  alias StressTester.WebSocket

  @default ~w(health meta bad-password unauthenticated login refresh-rotation lobby bad-hello fight replace)
  @all @default ++ ~w(rejoin)

  def names, do: @all

  def list(shared, which) do
    ids =
      case which do
        :default -> @default
        :all -> @all
        :none -> []
        names when is_list(names) -> names
      end

    Enum.flat_map(ids, fn id ->
      if id in @all,
        do: [{id, fn -> run(id, shared) end}],
        else: [{id, fn -> {:error, "no such check"} end}]
    end)
  end

  defp run("health", s), do: health(s)
  defp run("meta", s), do: meta(s)
  defp run("bad-password", s), do: bad_password(s)
  defp run("unauthenticated", s), do: unauthenticated(s)
  defp run("login", s), do: login(s)
  defp run("refresh-rotation", s), do: refresh(s)
  defp run("lobby", s), do: lobby(s)
  defp run("bad-hello", s), do: bad_hello(s)
  defp run("fight", s), do: fight(s)
  defp run("replace", s), do: replace(s)
  defp run("rejoin", s), do: rejoin(s)

  # -- HTTP

  defp health(s) do
    case Api.call(s, "GET", "/health") do
      {:ok, 200, body} when body in ["ok", "ok\n"] -> :ok
      {:ok, status, body} -> {:error, "status #{status}, body #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp meta(s) do
    case Api.call(s, "GET", "/v1/meta") do
      {:ok, 200, %{"protocol" => 2, "tick_ms" => tick}} when is_integer(tick) and tick > 0 ->
        :ok

      {:ok, 200, %{"protocol" => other}} ->
        {:error, "the server speaks protocol #{inspect(other)}, this tester speaks 2"}

      {:ok, status, _} ->
        {:error, "status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bad_password(s) do
    case Api.call(s, "POST", "/v1/auth/login", %{
           "account" => bot("vigil", 9998),
           "password" => "not-the-password"
         }) do
      {:ok, 401, _} -> :ok
      {:ok, status, body} -> {:error, "wanted 401, got #{status} #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unauthenticated(s) do
    with {:ok, 401, _} <- Api.call(s, "GET", "/v1/me"),
         {:ok, 401, _} <- Api.call(s, "GET", "/v1/me", nil, "r1.not.atoken") do
      :ok
    else
      {:ok, status, _} -> {:error, "wanted 401, got #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp login(s) do
    name = bot("accord", 9991)

    with {:ok, tokens} <- Api.login(s, name),
         :ok <- present(tokens, ["access_token", "refresh_token"]),
         {:ok, 200, %{"account" => ^name}} <-
           Api.call(s, "GET", "/v1/me", nil, tokens["access_token"]) do
      :ok
    else
      {:ok, status, body} -> {:error, "/v1/me answered #{status} #{inspect(body)}"}
      {:error, reason} -> {:error, Api.explain(reason)}
    end
  end

  defp present(map, keys) do
    case Enum.reject(keys, &is_binary(map[&1])) do
      [] -> :ok
      missing -> {:error, "the answer lacks #{Enum.join(missing, ", ")}"}
    end
  end

  defp refresh(s) do
    with {:ok, first} <- Api.login(s, bot("vigil", 9990)),
         {:ok, 200, second} <-
           Api.call(s, "POST", "/v1/auth/refresh", %{"refresh_token" => first["refresh_token"]}),
         :ok <-
           if(second["refresh_token"] not in [nil, first["refresh_token"]],
             do: :ok,
             else: {:error, "the refresh token did not change"}
           ),
         {:ok, 401, _} <-
           Api.call(s, "POST", "/v1/auth/refresh", %{"refresh_token" => first["refresh_token"]}),
         {:ok, 401, _} <-
           Api.call(s, "POST", "/v1/auth/refresh", %{"refresh_token" => second["refresh_token"]}) do
      :ok
    else
      {:ok, 200, _} -> {:error, "a used or revoked refresh token was accepted"}
      {:ok, status, body} -> {:error, "refresh answered #{status} #{inspect(body)}"}
      {:error, reason} -> {:error, Api.explain(reason)}
    end
  end

  # -- the lobby

  defp lobby(s) do
    name = bot("vigil", 9992)

    with {:ok, tokens} <- Api.login(s, name),
         {:ok, ws, welcome, _} <- Lobby.connect(s, tokens["access_token"], name),
         :ok <-
           if(welcome["character"] == name,
             do: :ok,
             else: {:error, "welcome is for #{inspect(welcome["character"])}"}
           ),
         :ok <- Lobby.send_op(ws, %{"op" => "ping", "id" => 7}),
         {:ok, ws, %{"ok" => true, "now" => _}, _} <- Lobby.await(ws, 7, s.timeout) do
      WebSocket.close(ws)
      :ok
    else
      {:ok, _ws, reply, _} -> {:error, "ping answered #{inspect(reply)}"}
      {:error, reason} -> {:error, Api.explain(reason)}
    end
  end

  defp bad_hello(s) do
    opts = Map.put(s.tls, :path, "/v1/lobby")

    with {:ok, ws, _} <- WebSocket.connect(s.origin, opts, s.timeout),
         :ok <-
           Lobby.send_op(ws, %{
             "op" => "hello",
             "id" => 1,
             "token" => "r1.not.atoken",
             "character" => bot("vigil", 9992)
           }) do
      result =
        case Lobby.await(ws, 1, 3_000) do
          {:ok, _ws, %{"ok" => false}, _} -> :ok
          {:error, {:closed, 4002, _}} -> :ok
          {:error, {:closed, code, _}} -> {:error, "closed with #{code}, not 4002"}
          {:ok, _ws, reply, _} -> {:error, "a bad token was welcomed: #{inspect(reply)}"}
          {:error, reason} -> {:error, reason}
        end

      WebSocket.close(ws)
      result
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # -- the fight

  defp fight(s) do
    name = bot("accord", 9993)

    with {:ok, tokens} <- Api.login(s, name),
         {:ok, ws, _, _} <- Lobby.connect(s, tokens["access_token"], name),
         {:ok, ws, ticket, _} <- Lobby.ticket(s, ws, s.place),
         :ok <- reachable(s, ticket),
         {:ok, f} <- Fight.open(ticket, opts(s)) do
      f = pump(f, 1_500, Bot)
      Fight.bye(f)
      WebSocket.close(ws)
      judge(f)
    else
      {:error, reason} -> {:error, Api.explain(reason)}
    end
  end

  defp judge(f) do
    c = f.counts

    cond do
      c.decode_errors > 0 ->
        {:error, "#{c.decode_errors} snapshots could not be decoded"}

      c.snapshots < 10 ->
        {:error, "only #{c.snapshots} snapshots in 1.5 s (30 a second expected)"}

      Fight.self(f) == nil ->
        {:error, "the snapshots do not contain our own body (slot #{f.slot})"}

      f.me == nil ->
        {:error, "no player state in the snapshots"}

      true ->
        :ok
    end
  end

  # a ticket that points at the server's own loopback is no use to anyone else
  defp reachable(%{udp_host: host}, _ticket) when is_binary(host), do: :ok

  defp reachable(s, ticket) do
    advertised = get_in(ticket, ["udp", "host"])

    with true <- is_binary(advertised),
         {:ok, ip} <- StressTester.Net.resolve(advertised),
         true <- loopback?(ip) and not loopback?(s.origin.ip) do
      {:error,
       "the ticket says to send UDP to #{advertised}, but the server is at #{s.origin.host}: " <>
         "set REACH_ADVERTISE_HOST on the server (or pass --udp-host here)"}
    else
      _ -> :ok
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp replace(s) do
    name = bot("vigil", 9994)

    with {:ok, tokens} <- Api.login(s, name),
         {:ok, ws, _, _} <- Lobby.connect(s, tokens["access_token"], name),
         {:ok, ws, t1, _} <- Lobby.ticket(s, ws, s.place),
         {:ok, first} <- Fight.open(t1, opts(s)),
         {:ok, ws, t2, _} <- Lobby.ticket(s, ws, s.place),
         {:ok, second} <- Fight.open(t2, opts(s)) do
      {first, ended} = pump_until_bye(first, 3_000)
      second = pump(second, 600, Bot)
      Fight.bye(second)
      WebSocket.close(ws)

      cond do
        ended != :replaced ->
          {:error, "the first fight ended with #{inspect(ended)}, not :replaced"}

        second.counts.snapshots == 0 ->
          {:error, "the new fight got no snapshots"}

        true ->
          Fight.close(first) && :ok
      end
    else
      {:error, reason} -> {:error, Api.explain(reason)}
    end
  end

  # go quiet without a bye; once the server calls us dropped, the body waits and a rejoin gets it back
  defp rejoin(s) do
    name = bot("accord", 9995)

    with {:ok, tokens} <- Api.login(s, name),
         {:ok, ws, _, _} <- Lobby.connect(s, tokens["access_token"], name),
         {:ok, ws, ticket, _} <- Lobby.ticket(s, ws, s.place),
         {:ok, f} <- Fight.open(ticket, opts(s)) do
      f = pump(f, 600, Bot)
      left_at = Fight.self(f)
      Fight.close(f)
      # silence until the server's idle timer has fired (idle_ms 5 s by default)
      Process.sleep(7_000)

      with {:ok, ws, again, _} <- Lobby.rejoin(s, ws),
           {:ok, g} <- Fight.open(again, opts(s)) do
        # read it before we move it: stand still until the first snapshots arrive
        g = pump(g, 300, Still)
        now_at = Fight.self(g)
        Fight.bye(g)
        WebSocket.close(ws)

        # the body comes back on the new connection's slot, where it was left
        cond do
          not g.rejoined ->
            {:error, "the server did not say this was a rejoin (accept flags)"}

          g.counts.snapshots == 0 ->
            {:error, "no snapshots after rejoining"}

          left_at == nil or now_at == nil ->
            {:error, "own body missing from the snapshots"}

          moved(left_at, now_at) > 150 ->
            {:error,
             "the body moved #{round(moved(left_at, now_at))} cm while we were gone (a new body?)"}

          true ->
            :ok
        end
      end
    else
      {:error, reason} -> {:error, Api.explain(reason)}
    end
  end

  defp moved(a, b),
    do: :math.sqrt(:math.pow(a.x - b.x, 2) + :math.pow(a.y - b.y, 2) + :math.pow(a.z - b.z, 2))

  # -- running a fight inside a check

  defp opts(s), do: %{timeout: s.timeout, udp_host: s.udp_host}

  defp bot(side, number), do: side <> "-" <> Integer.to_string(number)

  # play for ms: read what arrives, send an input about every 33 ms
  defp pump(f, ms, brain) do
    deadline = now() + ms
    loop(f, deadline, brain, now())
  end

  defp loop(f, deadline, brain, next) do
    if now() >= deadline do
      f
    else
      wait = max(min(next, deadline) - now(), 0)
      sock = f.sock

      receive do
        {:udp, ^sock, _ip, _port, data} ->
          case Fight.packet(f, data) do
            {:ok, f} -> loop(f, deadline, brain, next)
            {:bye, _reason, f} -> f
          end

        {:udp_passive, ^sock} ->
          Fight.rearm(f)
          loop(f, deadline, brain, next)
      after
        wait ->
          loop(brain.drive(f), deadline, brain, now() + (f.tick_ms || 33))
      end
    end
  end

  defp pump_until_bye(f, ms) do
    deadline = now() + ms
    sock = f.sock

    Stream.repeatedly(fn -> :go end)
    |> Enum.reduce_while(f, fn _, f ->
      left = deadline - now()

      if left <= 0 do
        {:halt, {f, :still_running}}
      else
        receive do
          {:udp, ^sock, _ip, _port, data} ->
            case Fight.packet(f, data) do
              {:ok, f} -> {:cont, f}
              {:bye, reason, f} -> {:halt, {f, reason}}
            end

          {:udp_passive, ^sock} ->
            Fight.rearm(f)
            {:cont, f}
        after
          left -> {:halt, {f, :still_running}}
        end
      end
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end

defmodule StressTester.Reach.Checks.Still do
  @moduledoc false
  # a player who sends nothing
  def drive(fight), do: fight
end
