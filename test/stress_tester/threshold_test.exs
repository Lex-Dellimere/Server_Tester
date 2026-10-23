defmodule StressTester.ThresholdTest do
  use ExUnit.Case, async: true

  alias StressTester.{Histogram, Threshold}

  defp parse!(text) do
    {:ok, t} = Threshold.parse(text)
    t
  end

  defp hist(values, unit \\ :us),
    do: Enum.reduce(values, Histogram.new(unit), &Histogram.add(&2, &1))

  defp summary(opts \\ []) do
    %{
      counters: Map.new(opts[:counters] || []),
      hists: Map.new(opts[:hists] || []),
      values: Map.new(opts[:values] || []),
      elapsed_ms: opts[:elapsed_ms] || 10_000
    }
  end

  test "it reads subject, statistic, operator and number" do
    t = parse!("http.req:p99 < 250ms")
    assert %{subject: "http.req", stat: "p99", op: :<, number: 250.0, unit: "ms"} = t
    assert %{subject: "vu.lost", stat: nil, op: :==, number: n} = parse!("vu.lost==0")
    assert n == 0
    assert %{stat: "ratio", unit: "%"} = parse!("iterations.failed:ratio<1%")
    assert %{op: :>=} = parse!("reach.snapshot:rate >= 1000")
  end

  test "rubbish is refused" do
    assert {:error, message} = Threshold.parse("fast please")
    assert message =~ "not a threshold"
    assert {:error, _} = Threshold.parse("x:p99 ~ 5")
  end

  test "parse_all stops at the first bad one" do
    assert {:ok, [_, _]} = Threshold.parse_all(["a<1", "b>2"])
    assert {:error, _} = Threshold.parse_all(["a<1", "nope"])
    assert {:ok, []} = Threshold.parse_all(nil)
  end

  test "percentiles compare in the histogram's own unit" do
    s = summary(hists: [{"http.req", hist(Enum.map(1..100, &(&1 * 1_000)))}])
    assert {true, p99, :us} = Threshold.eval(parse!("http.req:p99<250ms"), s)
    assert_in_delta p99, 99_000, 1_000
    assert {false, _, _} = Threshold.eval(parse!("http.req:p99<50ms"), s)
    assert {true, _, _} = Threshold.eval(parse!("http.req:p50 < 0.06s"), s)
    assert {true, _, _} = Threshold.eval(parse!("http.req:max<=100ms"), s)
    assert {true, _, _} = Threshold.eval(parse!("http.req:min>=1ms"), s)
    assert {true, _, _} = Threshold.eval(parse!("http.req:mean<60ms"), s)
    assert {true, _, _} = Threshold.eval(parse!("http.req:p99.9<101ms"), s)
  end

  test "sizes accept KB and MB" do
    s = summary(hists: [{"size", hist([2_048, 4_096], :bytes)}])
    assert {true, _, :bytes} = Threshold.eval(parse!("size:max<5KB"), s)
    assert {false, _, _} = Threshold.eval(parse!("size:max<3KB"), s)
  end

  test "counters, rates and ratios" do
    s =
      summary(
        counters: [
          {"errors", 0},
          {"iterations", 200},
          {"iterations.failed", 3},
          {"vu.started", 10},
          {"vu.lost", 1},
          {"reach.snapshot", 500}
        ]
      )

    assert {true, 0, :count} = Threshold.eval(parse!("errors==0"), s)
    assert {true, _, :count} = Threshold.eval(parse!("reach.snapshot:count>100"), s)
    assert {true, rate, :rate} = Threshold.eval(parse!("reach.snapshot:rate>40"), s)
    assert rate == 50.0
    assert {true, ratio, :ratio} = Threshold.eval(parse!("iterations.failed:ratio<2%"), s)
    assert_in_delta ratio, 0.015, 1.0e-9
    assert {false, _, _} = Threshold.eval(parse!("iterations.failed:ratio<1%"), s)
    assert {true, 0.1, :ratio} = Threshold.eval(parse!("vu.lost:ratio<=10%"), s)
  end

  test "a counter that never happened is zero" do
    assert {true, 0, :count} = Threshold.eval(parse!("vu.connect_failed==0"), summary())
    assert {true, ratio, :ratio} = Threshold.eval(parse!("iterations.failed:ratio<1%"), summary())
    assert ratio == 0
  end

  test "numbers the target worked out are used as they are" do
    s = summary(values: [{"reach.decode_error_ratio", 0.0}])
    assert {true, zero, :ratio} = Threshold.eval(parse!("reach.decode_error_ratio==0"), s)
    assert zero == 0

    # names ending _ratio or _loss are fractions, so a percent sign means what it says
    s = summary(values: [{"reach.snapshot_loss", 0.04}, {"other", 3.0}])
    assert {true, 0.04, :ratio} = Threshold.eval(parse!("reach.snapshot_loss<5%"), s)
    assert {false, _, _} = Threshold.eval(parse!("reach.snapshot_loss<3%"), s)
    assert {true, 3.0, :count} = Threshold.eval(parse!("other>=3"), s)
  end

  test "a statistic with nothing behind it fails" do
    assert {false, nil, nil} = Threshold.eval(parse!("http.req:p99<1s"), summary())

    assert {false, nil, nil} =
             Threshold.eval(
               parse!("http.req:p99<1s"),
               summary(hists: [{"http.req", Histogram.new()}])
             )
  end

  test "values print the way the report shows them" do
    assert Threshold.show(nil, nil) == "no data"
    assert Threshold.show(0.015, :ratio) == "1.50%"
    assert Threshold.show(50.0, :rate) == "50.0/s"
    assert Threshold.show(1_500, :us) == "1.50ms"
    assert Threshold.show(12, :count) == "12"
  end
end
