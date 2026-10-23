defmodule StressTester.TargetsTest do
  use ExUnit.Case, async: true

  alias StressTester.Test.{EchoWs, TinyServer}

  defp run!(opts) do
    {:ok, r} = StressTester.run([silent: true, threshold: ["none"], grace: "2s"] ++ opts)
    r
  end

  defp ok(body, extra \\ ""),
    do:
      {:reply, ["HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n", extra, "\r\n", body]}

  defp serve(fun), do: elem(TinyServer.start(fun), 0)

  describe "http" do
    test "a plain GET, with the numbers a person wants" do
      port = serve(fn _req, _n -> ok("hello") end)

      r =
        run!(
          target: "http",
          url: "http://127.0.0.1:#{port}/x",
          vus: 2,
          duration: "1s",
          pace: "50ms"
        )

      assert r.counters["http.status.200"] > 20
      assert r.counters["http.bytes_in"] > 100
      assert r.metrics["http.req"]["count"] == r.counters["http.status.200"]
      assert r.metrics["http.ttfb"]["p50"] > 0
      assert r.metrics["http GET /x"]["count"] > 20
      # one connection each, kept open
      assert r.metrics["http.connect"]["count"] == 2
      assert r.counters["iterations.failed"] in [nil, 0]
    end

    test "a bad status fails the iteration unless it was expected" do
      port = serve(fn _req, _n -> {:reply, "HTTP/1.1 500 Oops\r\ncontent-length: 0\r\n\r\n"} end)

      r =
        run!(
          target: "http",
          url: "http://127.0.0.1:#{port}/",
          vus: 1,
          duration: "500ms",
          pace: "50ms"
        )

      assert r.counters["iterations.failed"] > 5
      assert Enum.any?(r.errors, &(&1["reason"] =~ "status 500"))
      assert r.counters["http.status.500"] > 5

      r =
        run!(
          target: "http",
          url: "http://127.0.0.1:#{port}/",
          vus: 1,
          duration: "500ms",
          pace: "50ms",
          expect_status: "500,503"
        )

      assert r.counters["iterations.failed"] in [nil, 0]
    end

    test "POST with a JSON body filled in per user and iteration" do
      port =
        serve(fn req, _n ->
          ok(
            JSON.encode!(%{
              "method" => req.method,
              "body" => req.body,
              "type" => req.headers["content-type"],
              "x" => req.headers["x-id"]
            })
          )
        end)

      r =
        run!(
          target: "http",
          url: "http://127.0.0.1:#{port}/",
          vus: 1,
          duration: "300ms",
          pace: "100ms",
          json: ~s({"user":"u{{vu}}","n":{{iteration}}}),
          header: ["x-id: {{vu:3}}"]
        )

      assert r.counters["http.status.200"] >= 2
      assert r.counters["http.bytes_out"] > 20
    end

    test "scenario steps: setup once, steps each time, captures flow between them" do
      port =
        serve(fn req, _n ->
          case req.path do
            "/login" ->
              ok(~s({"token":"t-#{req.body |> String.length()}","etag":"abc"}), "etag: v1\r\n")

            "/me" ->
              if req.headers["authorization"] ==
                   "Bearer t-" <> Integer.to_string(String.length(~s({"u":"u1"}))),
                 do: ok(~s({"name":"me","items":[{"id":"i7"}]})),
                 else: {:reply, "HTTP/1.1 401 No\r\ncontent-length: 0\r\n\r\n"}

            "/item/i7" ->
              ok(~s({"ok":true}))

            "/etag-v1" ->
              ok("fine")

            _ ->
              {:reply, "HTTP/1.1 404 Nope\r\ncontent-length: 0\r\n\r\n"}
          end
        end)

      steps = [
        %{
          "name" => "me",
          "path" => "/me",
          "headers" => %{"authorization" => "Bearer {{token}}"},
          "expect" => %{"json" => %{"name" => "me"}},
          "capture" => %{"item" => "items.0.id"}
        },
        %{"name" => "item", "path" => "/item/{{item}}", "expect" => %{"contains" => "true"}},
        %{"name" => "by etag", "path" => "/etag-{{tag}}"}
      ]

      setup = [
        %{
          "name" => "login",
          "method" => "POST",
          "path" => "/login",
          "json" => %{"u" => "u1"},
          "capture" => %{"token" => "token", "tag" => "header:etag"}
        }
      ]

      r =
        run!(
          target: "http",
          url: "http://127.0.0.1:#{port}",
          vus: 1,
          duration: "500ms",
          pace: "50ms",
          setup: setup,
          steps: steps
        )

      assert r.metrics["http login"]["count"] == 1
      assert r.metrics["http me"]["count"] > 5
      assert r.metrics["http item"]["count"] > 5
      assert r.metrics["http by etag"]["count"] > 5
      assert r.counters["iterations.failed"] in [nil, 0], inspect(r.errors)
    end

    test "a failed setup stops that user before the load" do
      port = serve(fn _req, _n -> {:reply, "HTTP/1.1 401 No\r\ncontent-length: 0\r\n\r\n"} end)
      setup = [%{"name" => "login", "path" => "/login"}]

      r =
        run!(
          target: "http",
          url: "http://127.0.0.1:#{port}",
          vus: 1,
          duration: "300ms",
          setup: setup,
          steps: [%{"path" => "/"}]
        )

      assert r.counters["vu.connect_failed"] >= 1
      assert Enum.any?(r.errors, &(&1["where"] == "connect" and &1["reason"] =~ "login"))
    end

    test "things the response must contain, and a capture that finds nothing, fail the iteration" do
      port = serve(fn _req, _n -> ok(~s({"a":1})) end)

      r =
        run!(
          target: "http",
          url: "http://127.0.0.1:#{port}",
          vus: 1,
          duration: "300ms",
          pace: "50ms",
          steps: [%{"path" => "/", "expect" => %{"contains" => "needle"}}]
        )

      assert Enum.any?(r.errors, &(&1["reason"] =~ "body lacks"))

      r =
        run!(
          target: "http",
          url: "http://127.0.0.1:#{port}",
          vus: 1,
          duration: "300ms",
          pace: "50ms",
          steps: [%{"path" => "/", "expect" => %{"json" => %{"a" => 2}}}]
        )

      assert Enum.any?(r.errors, &(&1["reason"] =~ "a is 1"))

      r =
        run!(
          target: "http",
          url: "http://127.0.0.1:#{port}",
          vus: 1,
          duration: "300ms",
          pace: "50ms",
          steps: [%{"path" => "/", "capture" => %{"x" => "nope.nothing"}}]
        )

      assert Enum.any?(r.errors, &(&1["reason"] =~ "nothing to capture"))
    end

    test "a slow server hits the request timeout" do
      port = serve(fn _req, _n -> Process.sleep(600) && ok("late") end)

      r =
        run!(
          target: "http",
          url: "http://127.0.0.1:#{port}/",
          vus: 1,
          duration: "600ms",
          pace: "50ms",
          timeout: "150ms"
        )

      assert r.counters["iterations.failed"] >= 1
      assert r.counters["http.failed"] >= 1
      assert Enum.any?(r.errors, &(&1["reason"] =~ "timeout"))
    end

    test "setup mistakes are reported before any user starts" do
      assert {:error, message} = StressTester.run(target: "http", silent: true)
      assert message =~ "URL"

      assert {:error, message} =
               StressTester.run(
                 target: "http",
                 url: "http://127.0.0.1:1/",
                 header: ["nocolon"],
                 silent: true
               )

      assert message =~ "colon"
    end
  end

  describe "websocket" do
    test "send mode counts what goes out and what comes back" do
      port = EchoWs.start()

      r =
        run!(
          target: "ws",
          url: "ws://127.0.0.1:#{port}/",
          vus: 3,
          duration: "1s",
          pace: "100ms",
          message: "m{{vu}}.{{iteration}}"
        )

      assert r.counters["ws.sent"] > 15
      assert_in_delta r.counters["ws.received"], r.counters["ws.sent"], 6
      assert r.metrics["ws.upgrade"]["count"] == 3
      assert r.counters["ws.bytes_out"] > 50 and r.counters["ws.bytes_in"] > 50
    end

    test "reply mode times the answer" do
      port = EchoWs.start()

      r =
        run!(
          target: "ws",
          url: "ws://127.0.0.1:#{port}/",
          vus: 2,
          duration: "1s",
          pace: "100ms",
          mode: "reply",
          match: "echo:"
        )

      assert r.metrics["ws.reply"]["count"] > 10
      assert r.counters["iterations.failed"] in [nil, 0]
    end

    test "an answer that never matches fails the iteration after the timeout" do
      port = EchoWs.start()

      r =
        run!(
          target: "ws",
          url: "ws://127.0.0.1:#{port}/",
          vus: 1,
          duration: "700ms",
          mode: "reply",
          match: "never-said",
          timeout: "200ms"
        )

      assert r.counters["iterations.failed"] >= 1
      assert Enum.any?(r.errors, &(&1["reason"] == "timeout"))
    end

    test "a server that closes the socket loses the user, with its code" do
      port = EchoWs.start()

      r =
        run!(
          target: "ws",
          url: "ws://127.0.0.1:#{port}/",
          vus: 1,
          duration: "500ms",
          pace: "50ms",
          message: "bye"
        )

      assert r.counters["ws.closed.1001"] >= 1
      assert r.counters["vu.lost"] >= 1
    end

    test "mistakes in the options are refused up front" do
      assert {:error, message} = StressTester.run(target: "ws", silent: true)
      assert message =~ "ws://"
      port = EchoWs.start()

      assert {:error, message} =
               StressTester.run(
                 target: "ws",
                 url: "ws://127.0.0.1:#{port}/",
                 mode: "shout",
                 silent: true
               )

      assert message =~ "send or reply"
    end

    test "nothing to connect to is a connect failure" do
      {:ok, l} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(l)
      :gen_tcp.close(l)
      r = run!(target: "ws", url: "ws://127.0.0.1:#{port}/", vus: 1, duration: "300ms")
      assert r.counters["vu.connect_failed"] >= 1
    end
  end

  test "the mix task runs the command line and fails loudly" do
    import ExUnit.CaptureIO
    port = serve(fn _req, _n -> ok("ok") end)
    url = "http://127.0.0.1:#{port}/"

    capture_io(fn ->
      assert Mix.Tasks.Stress.run([
               "http",
               url,
               "--vus",
               "1",
               "--duration",
               "1s",
               "--pace",
               "100ms",
               "--quiet"
             ]) == :ok

      assert catch_exit(
               Mix.Tasks.Stress.run([
                 "http",
                 url,
                 "--vus",
                 "1",
                 "--duration",
                 "1s",
                 "--pace",
                 "100ms",
                 "--quiet",
                 "--threshold",
                 "http.req:p99<1us"
               ])
             ) ==
               {:shutdown, 1}
    end)
  end
end
