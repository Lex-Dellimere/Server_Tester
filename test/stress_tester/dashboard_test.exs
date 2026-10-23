defmodule StressTester.DashboardTest do
  use ExUnit.Case, async: false

  # The dashboard against the Reach server booted in this VM: the page, the API,
  # and the live stream a browser reads, from Run to the result.

  alias StressTester.{Dashboard, History}

  @moduletag timeout: 120_000

  setup_all do
    {:ok, _pid, _url} = Dashboard.start(port: 0, address: "127.0.0.1:#{Reach.Web.port()}")
    on_exit(fn -> Dashboard.stop() end)
    :ok
  end

  setup do
    History.clear()
    wait_idle()
    :ok
  end

  defp port, do: StressTester.Dashboard.Server.port()
  defp address, do: "127.0.0.1:#{Reach.Web.port()}"

  # -- a tiny client

  defp request(method, path, body \\ nil) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port(), [:binary, active: false])
    payload = if body, do: JSON.encode!(body), else: ""

    :ok =
      :gen_tcp.send(sock, [
        "#{method} #{path} HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\n",
        "content-length: #{byte_size(payload)}\r\n\r\n",
        payload
      ])

    raw = read_all(sock, <<>>)
    [head, body] = :binary.split(raw, "\r\n\r\n")
    [_, code | _] = String.split(head, " ")
    {String.to_integer(code), body}
  end

  defp read_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} -> read_all(sock, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp json(method, path, body \\ nil) do
    {code, text} = request(method, path, body)
    {code, JSON.decode!(text)}
  end

  # the live stream: collect events until `stop?` says so
  defp stream(stop?, timeout \\ 60_000) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port(), [:binary, active: false])
    :ok = :gen_tcp.send(sock, "GET /api/events HTTP/1.1\r\nhost: x\r\n\r\n")
    deadline = System.monotonic_time(:millisecond) + timeout
    events = collect(sock, <<>>, [], stop?, deadline)
    :gen_tcp.close(sock)
    events
  end

  defp collect(sock, buf, acc, stop?, deadline) do
    {events, rest} = parse(buf)

    case Enum.split_while(events, &(not stop?.(&1))) do
      {before, [last | _]} ->
        acc ++ before ++ [last]

      {_, []} ->
        wait(sock, rest, acc ++ events, stop?, deadline)
    end
  end

  defp wait(sock, rest, acc, stop?, deadline) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "stream ended without the event wanted; got #{inspect(Enum.map(acc, &elem(&1, 0)))}"
        )

      true ->
        case :gen_tcp.recv(sock, 0, 2_000) do
          {:ok, data} -> collect(sock, rest <> data, acc, stop?, deadline)
          {:error, :timeout} -> collect(sock, rest, acc, stop?, deadline)
          {:error, :closed} -> acc
        end
    end
  end

  defp parse(buf) do
    parts = String.split(buf, "\n\n")
    {whole, [rest]} = Enum.split(parts, -1)

    events =
      for chunk <- whole,
          lines = String.split(chunk, "\n"),
          event =
            Enum.find_value(
              lines,
              &(String.starts_with?(&1, "event: ") && String.trim_leading(&1, "event: "))
            ),
          data =
            Enum.find_value(
              lines,
              &(String.starts_with?(&1, "data: ") && String.trim_leading(&1, "data: "))
            ),
          do: {event, JSON.decode!(data)}

    {events, rest}
  end

  defp done?({"done", _}), do: true
  defp done?(_), do: false

  defp start_and_watch(params, extra_stop \\ &done?/1) do
    me = self()

    watcher =
      Task.async(fn ->
        send(me, :watching)
        stream(extra_stop)
      end)

    assert_receive :watching
    # the stream is subscribed once its first event (the snapshot) can arrive
    Process.sleep(200)
    assert {202, %{"test" => _}} = json("POST", "/api/run", params)
    Task.await(watcher, 90_000)
  end

  defp wait_idle(tries \\ 200) do
    case json("GET", "/api/state") do
      {200, %{"status" => %{"status" => "idle"}}} ->
        :ok

      _ when tries > 0 ->
        Process.sleep(100)
        wait_idle(tries - 1)

      other ->
        flunk("dashboard never went idle: #{inspect(other)}")
    end
  end

  # -- the tests

  test "the page and what it offers" do
    assert {200, page} = request("GET", "/")
    assert page =~ "<title>Reach Load Tests</title>"
    assert page =~ "EventSource"

    assert {200, state} = json("GET", "/api/state")

    assert Enum.map(state["tests"], & &1["id"]) ==
             ~w(battle ladder queue checks api logins scenario)

    assert "rejoin" in state["checks"]
    assert "reach-50v50" in state["scenarios"]
    assert state["status"]["status"] == "idle"
    assert {404, _} = request("GET", "/nowhere")
  end

  test "it says whether the server is up" do
    assert {200, %{"up" => true}} = json("GET", "/api/health?address=#{address()}")
    {:ok, l} = :gen_tcp.listen(0, [])
    {:ok, dead} = :inet.port(l)
    :gen_tcp.close(l)

    assert {200, %{"up" => false, "detail" => _}} =
             json("GET", "/api/health?address=127.0.0.1:#{dead}")
  end

  test "a battle from Run to the result, live, then as a report" do
    events =
      start_and_watch(%{
        "test" => "battle",
        "address" => address(),
        "players" => 4,
        "duration" => 3,
        "ramp" => 0,
        "checks" => "none"
      })

    names = Enum.map(events, &elem(&1, 0))

    assert hd(names) == "snapshot"
    assert "started" in names
    assert "status" in names
    assert Enum.count(names, &(&1 == "point")) >= 2
    assert "server" in names

    point =
      Enum.find_value(events, fn {n, d} ->
        n == "point" && d["counters"]["reach.snapshot"] && d
      end)

    assert point["vus"] == 4
    assert point["counters"]["reach.bytes_in"] > 0
    assert %{"p99" => _} = point["metrics"]["reach.rtt"]

    sample = Enum.find_value(events, fn {n, d} -> n == "server" && d end)
    assert %{"reach_tick_ms" => %{"p99" => _}} = sample["histograms"]

    {"done", done} = List.last(events)
    assert done["ok"]
    assert done["stopped"] == false
    assert done["counters"]["vu.connected"] == 4
    assert [%{"label" => "Battle · 4 players", "report" => report}] = done["history"]

    assert {200, page} = request("GET", report)
    assert page =~ "PASS"
    assert {404, _} = request("GET", "/reports/999")
    assert {404, _} = request("GET", "/reports/x")
  end

  test "Stop ends a run early, and it is judged on the time it ran" do
    me = self()
    watcher = Task.async(fn -> send(me, :watching) && stream(&done?/1) end)
    assert_receive :watching
    Process.sleep(200)

    assert {202, _} =
             json("POST", "/api/run", %{
               "test" => "battle",
               "address" => address(),
               "players" => 3,
               "duration" => 60,
               "ramp" => 0,
               "checks" => "none"
             })

    # one run at a time
    assert {409, %{"error" => error}} =
             json("POST", "/api/run", %{"test" => "battle", "players" => 1})

    assert error =~ "already running"

    Process.sleep(3_000)
    assert {200, %{"ok" => true}} = json("POST", "/api/stop")
    events = Task.await(watcher, 60_000)

    {"done", done} = List.last(events)
    assert done["stopped"]
    assert done["seconds"] < 20
    assert Enum.any?(events, &match?({"status", %{"status" => "stopping"}}, &1))
    assert {409, _} = json("POST", "/api/stop")
  end

  test "checks only, with the checks you choose" do
    events =
      start_and_watch(%{
        "test" => "checks",
        "address" => address(),
        "checks" => ["login", "lobby"]
      })

    {"checks", checks} = Enum.find(events, &match?({"checks", _}, &1))
    assert Enum.map(checks, & &1["check"]) == ["login", "lobby"]
    {"done", done} = List.last(events)
    assert done["ok"]
    assert [%{"label" => "Checks only"}] = done["history"]
  end

  test "find the limit, step by step" do
    events =
      start_and_watch(%{
        "test" => "ladder",
        "address" => address(),
        "steps" => "2, 3",
        "duration" => 2,
        "ramp" => 0
      })

    rungs = for {"rung", r} <- events, do: r
    assert [%{"players" => 2, "ok" => true}, %{"players" => 3, "ok" => true}] = rungs
    {"done", done} = List.last(events)
    assert done["best"] == 3
    assert length(done["ladder"]) == 2

    # newest first, as the page lists them
    assert Enum.map(done["history"], & &1["label"]) == [
             "Find the limit · 3 players",
             "Find the limit · 2 players"
           ]
  end

  test "the HTTP API test and a scenario run from their files" do
    events =
      start_and_watch(%{
        "test" => "api",
        "address" => address(),
        "players" => 2,
        "duration" => 2,
        "ramp" => 0
      })

    {"done", done} = List.last(events)
    assert done["ok"], inspect(done["errors"])
    assert done["metrics"]["http me"]["count"] > 0
  end

  test "mistakes in the form are answered at once" do
    assert {400, %{"error" => e1}} = json("POST", "/api/run", %{"test" => "teleport"})
    assert e1 =~ "unknown test"

    assert {400, %{"error" => e2}} =
             json("POST", "/api/run", %{"test" => "ladder", "steps" => "lots"})

    assert e2 =~ "player counts"

    assert {400, %{"error" => e3}} =
             json("POST", "/api/run", %{"test" => "scenario", "scenario" => "nope"})

    assert e3 =~ "choose a scenario"

    assert {400, %{"error" => e4}} = json_raw("POST", "/api/run", "[1,2]")
    assert e4 =~ "JSON object"
    assert {400, _} = json_raw("POST", "/api/run", "{not json")
  end

  test "a server that is down fails the run, and says why" do
    {:ok, l} = :gen_tcp.listen(0, [])
    {:ok, dead} = :inet.port(l)
    :gen_tcp.close(l)

    events =
      start_and_watch(%{
        "test" => "battle",
        "address" => "127.0.0.1:#{dead}",
        "players" => 2,
        "duration" => 2,
        "ramp" => 0,
        "checks" => "none"
      })

    {"done", done} = List.last(events)
    refute done["ok"]
    assert done["errors"] != [] or done["error"]
  end

  defp json_raw(method, path, raw) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port(), [:binary, active: false])

    :ok =
      :gen_tcp.send(sock, [
        "#{method} #{path} HTTP/1.1\r\nhost: x\r\ncontent-length: #{byte_size(raw)}\r\n\r\n",
        raw
      ])

    [head, body] = :binary.split(read_all(sock, <<>>), "\r\n\r\n")
    [_, code | _] = String.split(head, " ")
    {String.to_integer(code), JSON.decode!(body)}
  end

  test "a page opened mid-run gets everything so far" do
    assert {202, _} =
             json("POST", "/api/run", %{
               "test" => "battle",
               "address" => address(),
               "players" => 2,
               "duration" => 4,
               "ramp" => 0,
               "checks" => "none"
             })

    Process.sleep(2_500)
    [{"snapshot", snap} | _] = stream(fn {n, _} -> n == "snapshot" end, 5_000)
    assert snap["status"]["status"] == "running"
    assert length(snap["points"]) >= 1
    wait_idle()
  end
end
