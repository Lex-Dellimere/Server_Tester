defmodule StressTester.HistogramTest do
  use ExUnit.Case, async: true

  alias StressTester.Histogram

  defp from(values, unit \\ :us),
    do: Enum.reduce(values, Histogram.new(unit), &Histogram.add(&2, &1))

  # the nearest-rank percentile of exact samples
  defp exact(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, max(ceil(p / 100 * length(sorted)) - 1, 0))
  end

  test "small values are exact" do
    h = from(1..100)
    assert Histogram.percentile(h, 50) == 50
    assert Histogram.percentile(h, 99) == 99
    assert Histogram.percentile(h, 100) == 100
    assert Histogram.percentile(h, 0) == 1
    assert h.count == 100 and h.min == 1 and h.max == 100
  end

  test "an empty histogram has no percentiles" do
    h = Histogram.new()
    assert Histogram.percentile(h, 50) == nil
    assert Histogram.mean(h) == nil
    assert Histogram.percentiles(h, [50, 99]) == %{50 => nil, 99 => nil}
    assert Histogram.stats(h)["count"] == 0
  end

  test "large values land within one percent of the truth" do
    :rand.seed(:exsss, {1, 2, 3})
    values = for _ <- 1..20_000, do: round(:math.pow(10, :rand.uniform() * 7))

    h = from(values)

    for p <- [50, 90, 95, 99, 99.9] do
      want = exact(values, p)
      got = Histogram.percentile(h, p)
      assert_in_delta got, want, max(want * 0.01, 1), "p#{p}: got #{got}, want #{want}"
    end
  end

  test "the middle of every bucket is inside the bucket" do
    for v <- [0, 1, 127, 128, 129, 255, 256, 1_000, 65_535, 65_536, 123_456_789, 4_000_000_000] do
      mid = Histogram.value(Histogram.index(v))
      assert_in_delta mid, v, max(v * 0.008, 0.5), "value #{v} reported as #{mid}"
    end
  end

  test "bucket numbers never go backwards" do
    indexes = for v <- 0..5_000, do: Histogram.index(v)
    assert indexes == Enum.sort(indexes)
    assert Histogram.index(1_000_000) < Histogram.index(1_000_001) + 1
  end

  test "merging two histograms equals one that saw everything" do
    a = from(1..500)
    b = from(400..2_000)
    both = from(Enum.to_list(1..500) ++ Enum.to_list(400..2_000))

    merged = Histogram.merge(a, b)
    assert merged.count == both.count
    assert merged.sum == both.sum
    assert merged.min == both.min and merged.max == both.max
    assert merged.buckets == both.buckets
    assert Histogram.merge(Histogram.new(), a) == a
    assert Histogram.merge(a, Histogram.new()) == a
  end

  test "percentiles never leave the range of what was seen" do
    h = from([5_000, 5_001, 5_002])
    assert Histogram.percentile(h, 1) >= 5_000
    assert Histogram.percentile(h, 99) <= 5_002
  end

  test "negative samples count as zero and floats are rounded" do
    h = from([-5, 2.4])
    assert h.min == 0 and h.max == 2
  end

  test "stats has every key a report needs" do
    stats = from(1..10, :bytes) |> Histogram.stats()
    assert stats["unit"] == "bytes"

    assert Map.keys(stats) |> Enum.sort() ==
             ~w(count max mean min p50 p90 p95 p99 p99.9 unit) |> Enum.sort()
  end
end
