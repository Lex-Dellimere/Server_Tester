defmodule StressTester.ReportTest do
  use ExUnit.Case, async: true

  alias StressTester.{Histogram, Metrics, Plan, Report}

  defp collected do
    h = Enum.reduce(1..100, Histogram.new(), &Histogram.add(&2, &1 * 1_000))
    size = Enum.reduce([100, 200], Histogram.new(:bytes), &Histogram.add(&2, &1))

    %{
      totals: %{
        c: %{
          "vu.started" => 4,
          "vu.connected" => 4,
          "iterations" => 400,
          "iterations.failed" => 2,
          "errors" => 2,
          "app.thing" => 9
        },
        h: %{"iteration" => h, "size" => size},
        e: %{{"iteration", "timeout"} => 2}
      },
      timeline: [%{"t" => 1}],
      peak: %{"vus" => 4, "cpu" => 0.25, "run_queue" => 1},
      nodes: 1
    }
  end

  defp report(opts \\ []) do
    {:ok, plan} =
      Plan.build(
        [
          target: StressTester.Test.Counter,
          vus: 4,
          duration: "10s",
          threshold: ["iteration:p99<500ms", "errors==0"]
        ] ++ opts
      )

    Report.build(
      plan,
      collected(),
      [{"login", :ok}, {"fight", {:error, "no snapshots"}}],
      %{"x" => 1.5},
      "counter"
    )
  end

  test "the verdict follows the thresholds and checks" do
    r = report()
    refute r.ok
    assert [%{"ok" => true}, %{"ok" => false, "shown" => "2"}] = r.thresholds
    assert [%{"ok" => true}, %{"ok" => false, "detail" => "no snapshots"}] = r.checks
  end

  test "the text report has the parts a person looks for" do
    text = Report.text(report())
    assert text =~ "counter"
    assert text =~ "users       4 started, 4 connected, 0 failed, 0 lost"
    assert text =~ "iterations  400 (40.0/s), 2 failed"
    assert text =~ ~r/iteration\s+100\s+10.0\/s/
    assert text =~ "size"
    assert text =~ "counters"
    assert text =~ "app.thing"
    assert text =~ "errors (2)"
    assert text =~ "iteration: timeout"
    assert text =~ "FAIL  fight: no snapshots"
    assert text =~ "ok    login"
    assert text =~ "FAIL  errors==0"
    assert text =~ "FAIL: 1 threshold, 1 check"
  end

  test "a passing run says PASS" do
    {:ok, plan} =
      Plan.build(target: StressTester.Test.Counter, vus: 1, duration: "1s", threshold: ["none"])

    c = put_in(collected(), [:totals, :e], %{})
    r = Report.build(plan, c, [], %{}, "counter")
    assert r.ok
    assert Report.text(r) =~ "PASS"
  end

  test "it warns when the tester itself was the bottleneck" do
    {:ok, plan} =
      Plan.build(target: StressTester.Test.Counter, vus: 1, duration: "1s", threshold: ["none"])

    busy = %{collected() | peak: %{"vus" => 1, "cpu" => 0.97, "run_queue" => 30}}
    assert Report.text(Report.build(plan, busy, [], %{}, "x")) =~ "tester itself was busy"
    refute Report.text(Report.build(plan, collected(), [], %{}, "x")) =~ "tester itself was busy"
  end

  test "the json report holds the same facts" do
    json = report() |> Report.json() |> JSON.decode!()
    assert json["ok"] == false
    assert json["counters"]["iterations"] == 400
    assert json["metrics"]["iteration"]["p99"] > 90_000
    assert json["metrics"]["size"]["unit"] == "bytes"
    assert [%{"where" => "iteration", "reason" => "timeout", "count" => 2}] = json["errors"]
    assert json["tester"]["peak_users"] == 4
    assert json["values"]["x"] == 1.5
  end

  test "the live line shows the second just gone" do
    point = %{
      "t" => 7,
      "vus" => 120,
      "connecting" => 3,
      "counters" => %{
        "iterations" => 3_000,
        "iterations.failed" => 1,
        "errors" => 1,
        "reach.snapshot" => 3_600
      },
      "metrics" => %{
        "iteration" => %{"count" => 3_000, "p50" => 200, "p99" => 4_000, "unit" => :us},
        "reach.rtt" => %{"count" => 100, "p50" => 1_000, "p99" => 3_000, "unit" => :us}
      }
    }

    line = Report.live(point, ["reach.snapshot", "reach.rtt", "missing"])
    assert line =~ "7s"
    assert line =~ "users 120 (+3 connecting)"
    assert line =~ "iter 3,000/s p99 4.00ms"
    assert line =~ "fail 1"
    assert line =~ "reach.snapshot 3,600/s"
    assert line =~ "reach.rtt 100/s p50 1.00ms p99 3.00ms"
    refute line =~ "missing"
  end

  test "metrics reasons are used as they are" do
    assert Metrics.reason("x") == "x"
  end
end
