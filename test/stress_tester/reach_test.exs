defmodule StressTester.ReachTest do
  use ExUnit.Case, async: false

  # These run against a real Reach server booted in this VM (the test-only
  # dependency): real HTTP, a real lobby socket, real encrypted UDP.

  alias StressTester.Reach, as: Target

  defp address, do: "127.0.0.1:#{Reach.Web.port()}"

  defp run!(opts) do
    {:ok, report} =
      StressTester.run([target: "reach", address: address(), silent: true, grace: "3s"] ++ opts)

    report
  end

  describe "the target on its own" do
    test "bots are named by side, alternating, and stay under the reserved names" do
      {:ok, shared} = Target.init(%{address: "127.0.0.1:1"})
      assert {:ok, "accord-0001"} = Target.bot_name(shared, 1)
      assert {:ok, "vigil-0001"} = Target.bot_name(shared, 2)
      assert {:ok, "accord-0002"} = Target.bot_name(shared, 3)

      {:ok, shared} = Target.init(%{address: "127.0.0.1:1", offset: 100, sides: "accord"})
      assert {:ok, "accord-0101"} = Target.bot_name(shared, 1)

      {:ok, shared} = Target.init(%{address: "127.0.0.1:1"})
      assert {:error, message} = Target.bot_name(shared, 20_000)
      assert message =~ "9989"
    end

    test "direct bots fill one place, then the next" do
      {:ok, shared} =
        Target.init(%{address: "127.0.0.1:1", place: "crystal-gate/r1", per_place: 4})

      assert Enum.map(1..9, &Target.place_for(shared, &1)) == ~w(
        crystal-gate/r1 crystal-gate/r1 crystal-gate/r1 crystal-gate/r1
        crystal-gate/r2 crystal-gate/r2 crystal-gate/r2 crystal-gate/r2
        crystal-gate/r3
      )

      {:ok, shared} = Target.init(%{address: "127.0.0.1:1", place: "crystal-gate"})
      assert Target.place_for(shared, 99) == "crystal-gate"
    end

    test "bad options are refused up front" do
      assert {:error, message} = Target.init(%{address: "127.0.0.1:1", mode: "sideways"})
      assert message =~ "direct or queue"
      assert {:error, message} = Target.init(%{address: "127.0.0.1:1", sides: "vigil,martians"})
      assert message =~ "martians"
      assert {:error, _} = Target.init(%{address: "127.0.0.1:1", timeout: "soon"})
    end
  end

  describe "the checks" do
    test "every check passes on a healthy server" do
      {:ok, shared} = Target.init(%{address: address()})

      results =
        shared
        |> Target.checks(:default)
        |> Enum.map(fn {name, fun} -> {name, fun.()} end)

      assert Enum.map(results, &elem(&1, 0)) ==
               ~w(health meta bad-password unauthenticated login refresh-rotation lobby bad-hello fight replace)

      failed = Enum.reject(results, fn {_, r} -> r == :ok end)
      assert failed == []
    end

    test "the rejoin check finds the same body where it was left" do
      {:ok, shared} = Target.init(%{address: address()})
      [{"rejoin", check}] = Target.checks(shared, ["rejoin"])
      assert check.() == :ok
    end

    test "a server that is not there fails them all in words" do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)
      {:ok, shared} = Target.init(%{address: "127.0.0.1:#{port}", timeout: "500ms"})

      for {name, fun} <- Target.checks(shared, :default) do
        assert {:error, _reason} = fun.(), "#{name} passed with nothing listening"
      end
    end

    test "an unknown check name fails by name" do
      {:ok, shared} = Target.init(%{address: address()})
      assert [{"nonsense", fun}] = Target.checks(shared, ["nonsense"])
      assert {:error, "no such check"} = fun.()
    end
  end

  describe "a load run" do
    test "bots log in, join the lobby, fight over UDP, and the numbers add up" do
      r = run!(vus: 6, duration: "3s", checks: "none")

      assert r.ok
      assert r.counters["vu.connected"] == 6
      assert r.counters["reach.rounds"] == 6
      assert r.counters["reach.snapshot"] > 6 * 30
      assert r.counters["reach.input"] > 6 * 60
      assert r.counters["reach.decode_error"] in [nil, 0]
      assert r.counters["errors"] in [nil, 0]
      # a snapshot every tick for everyone, give or take the start
      assert r.counters["reach.snapshot"] / r.counters["reach.input"] > 0.8
      assert r.metrics["reach.rtt"]["count"] > 100
      assert r.metrics["reach.rtt"]["p99"] < 100_000
      assert r.metrics["reach.snapshot_bytes"]["unit"] == "bytes"
      assert r.metrics["reach.snapshot_bytes"]["max"] < 1_200
      assert r.metrics["reach.lobby_rtt"]["count"] >= 0
      assert r.metrics["vu.connect"]["count"] == 6
      assert r.values["reach.decode_error_ratio"] == 0
      # every snapshot the server numbered arrived, within the margin the default threshold allows
      assert r.counters["reach.snapshot_expected"] >= r.counters["reach.snapshot"]
      assert r.values["reach.snapshot_loss"] < 0.05
    end

    test "default checks run first and pass" do
      r = run!(vus: 2, duration: "1s")
      assert r.ok
      assert Enum.all?(r.checks, & &1["ok"])
      assert length(r.checks) == 10
    end

    test "bots that fight see hits, kills, and corrections as the server decides them" do
      r = run!(vus: 8, duration: "6s", checks: "none", place: "crystal-gate/r2")
      assert r.ok
      # they walk to each other and shoot; the server reports what it traced
      assert r.counters["reach.hit"] > 0
      assert r.counters["reach.correct"] >= 8
    end

    test "chat goes through the reliable lane and comes back to teammates" do
      r = run!(vus: 4, duration: "3s", checks: "none", chat: "300ms", place: "crystal-gate/r2")
      assert r.ok
      assert r.counters["reach.chat_sent"] > 8
      assert r.counters["reach.chat_heard"] > 0
    end

    test "a battle that ends sends bots back to the lobby for another" do
      Application.put_env(:the_reach_backend, :battle, time_limit_ms: 1_500)
      on_exit(fn -> Application.put_env(:the_reach_backend, :battle, []) end)

      r =
        run!(
          vus: 4,
          duration: "9s",
          checks: "none",
          place: "crystal-gate/r3",
          threshold: ["none"]
        )

      assert r.counters["reach.rounds_ended"] >= 4
      assert r.counters["reach.rounds"] > 4
      assert r.counters["reach.decode_error"] in [nil, 0]
    end

    test "bots can be spread over several places" do
      r = run!(vus: 4, duration: "2s", checks: "none", place: "crystal-gate/r1", per_place: 2)
      assert r.ok
      assert r.counters["reach.rounds"] == 4
    end

    test "without stress logins the failure says why" do
      Application.put_env(:the_reach_backend, :stress_login, false)
      on_exit(fn -> Application.put_env(:the_reach_backend, :stress_login, true) end)

      # names no earlier test made, because made bots keep their password
      r = run!(vus: 1, duration: "1s", checks: "none", threshold: ["none"], offset: 7_000)
      assert r.counters["vu.connect_failed"] >= 1
      assert Enum.any?(r.errors, &(&1["reason"] =~ "stress logins"))
    end

    test "nothing listening: every user fails to connect, the verdict is FAIL" do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      {:ok, r} =
        StressTester.run(
          target: "reach",
          address: "127.0.0.1:#{port}",
          vus: 2,
          duration: "1s",
          silent: true,
          checks: "none",
          timeout: "500ms",
          grace: "1s"
        )

      refute r.ok
      assert r.counters["vu.connect_failed"] >= 2
      assert Enum.any?(r.thresholds, &(&1["ok"] == false))
    end
  end

  test "the HTTP target loads the real server and judges it" do
    {:ok, r} =
      StressTester.run(
        target: "http",
        url: "http://#{address()}/v1/meta",
        rate: 100.0,
        duration: "1s",
        silent: true,
        threshold: ["http.req:p99<500ms", "http.status.200:count>50"]
      )

    assert r.ok
    assert r.counters["http.status.200"] > 50
  end

  test "the HTTP target runs scenario steps with captured values" do
    scenario = %{
      "target" => "http",
      "url" => "http://#{address()}",
      "vus" => 3,
      "duration" => "1s",
      "pace" => "100ms",
      "setup" => [
        %{
          "name" => "login",
          "method" => "POST",
          "path" => "/v1/auth/login",
          "json" => %{"account" => "vigil-{{vu:4}}", "password" => "stress"},
          "expect" => %{"status" => 200},
          "capture" => %{"token" => "access_token"}
        }
      ],
      "steps" => [
        %{
          "name" => "me",
          "path" => "/v1/me",
          "headers" => %{"authorization" => "Bearer {{token}}"},
          "expect" => %{"status" => 200, "contains" => "vigil-"}
        },
        %{"name" => "fronts", "path" => "/v1/fronts"}
      ],
      "thresholds" => ["iterations.failed:ratio<1%"]
    }

    path =
      Path.join(System.tmp_dir!(), "stress-scenario-#{System.unique_integer([:positive])}.json")

    File.write!(path, JSON.encode!(scenario))
    on_exit(fn -> File.rm(path) end)

    {:ok, r} = StressTester.run_file(path, silent: true)
    assert r.ok, inspect(r.errors)
    assert r.metrics["http me"]["count"] > 10
    assert r.metrics["http fronts"]["count"] > 10
    assert r.counters["http.status.200"] > 20
  end

  test "the WebSocket target holds lobby sockets open and times replies" do
    # the lobby wants a hello first; send it as the message and expect the welcome
    {:ok, tokens} = StressTester.Reach.Api.login(shared(), "vigil-0099")

    hello =
      JSON.encode!(%{
        "op" => "hello",
        "id" => 1,
        "token" => tokens["access_token"],
        "character" => "vigil-0099"
      })

    {:ok, r} =
      StressTester.run(
        target: "ws",
        url: "ws://#{address()}/v1/lobby",
        vus: 1,
        duration: "1s",
        pace: "500ms",
        message: hello,
        mode: "reply",
        match: ~s("re"),
        silent: true,
        threshold: ["none"]
      )

    assert r.counters["ws.sent"] >= 1
    assert r.counters["ws.received"] >= 1
    assert r.metrics["ws.upgrade"]["count"] == 1
  end

  defp shared do
    {:ok, shared} = Target.init(%{address: address()})
    shared
  end
end
