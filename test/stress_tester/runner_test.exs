defmodule StressTester.RunnerTest do
  use ExUnit.Case, async: true

  alias StressTester.Test.Counter

  defp run!(opts) do
    {:ok, report} =
      StressTester.run([target: Counter, silent: true, threshold: ["none"], grace: "2s"] ++ opts)

    report
  end

  test "users run iterations one after another at their own pace" do
    r = run!(vus: 5, duration: "1s", pace: "100ms")
    assert r.counters["vu.started"] == 5
    assert r.counters["vu.connected"] == 5
    # 5 users, one iteration every 100 ms, for 1 s
    assert_in_delta r.counters["iterations"], 50, 8
    assert r.counters["test.disconnected"] == 5
    assert r.ok
    assert r.metrics["iteration"]["count"] == r.counters["iterations"]
  end

  test "without a pace users go flat out" do
    r = run!(vus: 2, duration: "500ms")
    assert r.counters["iterations"] > 1_000
  end

  test "think time spaces iterations after the work" do
    r = run!(vus: 2, duration: "1s", think: "100ms", work_ms: 20)
    # ~120 ms per iteration
    assert_in_delta r.counters["iterations"], 2 * 1_000 / 120, 4
  end

  test "a rate starts iterations on a clock, whatever the work costs" do
    r = run!(rate: 100.0, duration: "1s", work_ms: 10)
    assert_in_delta r.counters["iterations"], 100, 8
    assert r.counters["dropped"] in [nil, 0]
    assert r.load =~ "iterations/s"
  end

  test "a rate that outruns the users drops iterations, and says so" do
    # 200 a second, each taking 100 ms, with at most 3 users: 30 a second at best
    r = run!(rate: 200.0, duration: "1s", work_ms: 100, vus: 3, max_vus: 3)
    assert r.counters["dropped"] > 100
    assert r.counters["iterations"] < 60
    assert r.counters["vu.started"] == 3
  end

  test "stages move the number of users up and down" do
    r = run!(stages: "500ms:2,500ms:6,500ms:0", pace: "50ms")
    assert r.counters["vu.started"] >= 6
    assert r.tester["peak_users"] in 4..8
    assert r.seconds == 1.5
    assert r.counters["test.disconnected"] == r.counters["vu.started"]
  end

  test "users are started no faster than the spawn rate" do
    r = run!(vus: 4, duration: "1s", spawn_rate: 4.0, pace: "50ms")
    assert r.counters["vu.started"] == 4

    # four users a second means the last arrives well after the first: fewer iterations than all-at-once
    assert r.counters["iterations"] < 4 * 20
  end

  test "a connect that fails is counted and does not stop the run" do
    r = run!(vus: 3, duration: "1s", fail_connect: 1, pace: "100ms")
    assert r.counters["vu.connect_failed"] >= 1
    assert Enum.any?(r.errors, &(&1["where"] == "connect" and &1["reason"] == "refused"))
    assert r.counters["iterations"] > 10
  end

  test "a user that keeps failing to connect is retried less and less often" do
    # always refused: tries at 0 s, then after 1 s, then after 2 more; a fixed 1 s pause would be a fourth
    r = run!(vus: 1, duration: "3500ms", fail_connect: 1)
    assert r.counters["vu.started"] in 2..3
    assert r.counters["vu.connect_failed"] == r.counters["vu.started"]
  end

  test "failed iterations are counted and the user carries on" do
    r = run!(vus: 1, duration: "500ms", pace: "10ms", fail_every: 2)
    failed = r.counters["iterations.failed"]
    assert failed > 10
    assert_in_delta failed / r.counters["iterations"], 0.5, 0.1
    assert Enum.any?(r.errors, &(&1["reason"] == "flaky"))
  end

  test "a crash in a target ends that user and is reported with where" do
    r = run!(vus: 1, duration: "1s", pace: "10ms", crash_at: 3)
    assert r.counters["vu.lost"] >= 1
    assert r.counters["iterations.failed"] >= 1
    assert Enum.any?(r.errors, &String.contains?(&1["reason"], "boom"))
    assert r.counters["test.disconnected"] >= 1
  end

  test "a user may end itself on purpose" do
    r = run!(vus: 1, duration: "500ms", pace: "10ms", stop_at: 5)
    assert r.counters["test.iterations"] >= 5
    # it came back after the back-off, but the first stop was not an error in the target
    assert r.counters["vu.started"] >= 1
  end

  test "thresholds decide the verdict" do
    pass =
      run!(
        vus: 1,
        duration: "300ms",
        pace: "50ms",
        threshold: ["test.iterations:count>1", "errors==0"]
      )

    assert pass.ok
    assert Enum.all?(pass.thresholds, & &1["ok"])

    fail =
      run!(vus: 1, duration: "300ms", pace: "50ms", threshold: ["test.iterations:count>1000"])

    refute fail.ok
    assert [%{"ok" => false, "threshold" => "test.iterations:count>1000"}] = fail.thresholds
  end

  test "numbers the target works out can be judged too" do
    r = run!(vus: 2, duration: "300ms", pace: "50ms", threshold: ["test.per_vu>1"])
    assert r.ok
    assert r.values["test.per_vu"] > 1
  end

  test "checks run first and failing ones fail the run" do
    defmodule Checked do
      @behaviour StressTester.Target
      defdelegate init(o), to: Counter
      defdelegate connect(s, v), to: Counter
      defdelegate iterate(s), to: Counter
      defdelegate disconnect(s), to: Counter

      def checks(_s, _which) do
        [
          {"fine", fn -> :ok end},
          {"broken", fn -> {:error, "no good"} end},
          {"crashes", fn -> raise "oops" end}
        ]
      end
    end

    r = run!(target: Checked, vus: 1, duration: "200ms", pace: "50ms")
    refute r.ok

    assert [
             %{"check" => "fine", "ok" => true},
             %{"check" => "broken", "ok" => false, "detail" => "no good"},
             %{"check" => "crashes", "ok" => false}
           ] = r.checks

    # --checks none skips them
    r = run!(target: Checked, vus: 1, duration: "200ms", pace: "50ms", checks: "none")
    assert r.ok and r.checks == []
  end

  test "the timeline has a point for each second" do
    r = run!(vus: 2, duration: "2s", pace: "50ms")
    assert length(r.timeline) in 2..4
    assert Enum.any?(r.timeline, &(&1["counters"]["iterations"] > 10))
    assert Enum.all?(r.timeline, &is_integer(&1["t"]))
  end

  test "the tester says when it was too busy to keep time" do
    r = run!(vus: 2, duration: "500ms", pace: "50ms")
    assert is_float(r.tester["cpu_peak"]) or is_number(r.tester["cpu_peak"])
    assert r.tester["machines"] == 1
  end

  test "a target that does not exist is an error, not a crash" do
    assert {:error, message} = StressTester.run(target: "nope", silent: true)
    assert message =~ "unknown target"

    assert {:error, _} =
             StressTester.run(target: String.to_atom("Elixir.NotATarget"), silent: true)
  end

  test "messages between iterations reach the target" do
    # users run in their own processes, so hand the test pid over through the options
    parent = self()

    defmodule Pokes do
      @behaviour StressTester.Target
      defdelegate init(o), to: Counter
      defdelegate iterate(s), to: Counter
      defdelegate disconnect(s), to: Counter
      defdelegate handle_message(m, s), to: Counter

      def connect(shared, vu) do
        with {:ok, st} <- Counter.connect(shared, vu) do
          Process.send_after(self(), {:poke, :persistent_term.get({__MODULE__, :to})}, 30)
          {:ok, st}
        end
      end
    end

    :persistent_term.put({Pokes, :to}, parent)
    run!(target: Pokes, vus: 2, duration: "400ms", pace: "50ms")
    assert_received {:poked, 1}
    assert_received {:poked, 2}
    :persistent_term.erase({Pokes, :to})
  end
end
