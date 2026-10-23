defmodule StressTester.Histogram do
  @moduledoc """
  Counts samples in log-linear buckets: exact below 128, then 64 buckets per
  doubling, so a reported value is within 0.8 % of the real one. Memory stays
  small however many samples go in, and two histograms add bucket by bucket,
  which is how a thousand users' numbers become one without keeping every sample.

  Values are non-negative integers: microseconds for times, bytes for sizes.
  """

  import Bitwise

  defstruct unit: :us, count: 0, sum: 0, min: nil, max: 0, buckets: %{}

  def new(unit \\ :us), do: %__MODULE__{unit: unit}

  # `n` samples of the same value
  def add(h, value, n \\ 1)

  def add(%__MODULE__{} = h, value, n) when is_integer(value) and n > 0 do
    v = max(value, 0)

    %{
      h
      | count: h.count + n,
        sum: h.sum + v * n,
        min: if(h.min == nil or v < h.min, do: v, else: h.min),
        max: if(v > h.max, do: v, else: h.max),
        buckets: Map.update(h.buckets, index(v), n, &(&1 + n))
    }
  end

  def add(h, value, n) when is_float(value), do: add(h, round(value), n)
  def add(h, _value, _n), do: h

  def merge(%__MODULE__{count: 0}, b), do: b
  def merge(a, %__MODULE__{count: 0}), do: a

  def merge(a, b) do
    %{
      a
      | count: a.count + b.count,
        sum: a.sum + b.sum,
        min: min(a.min, b.min),
        max: max(a.max, b.max),
        buckets: Map.merge(a.buckets, b.buckets, fn _i, x, y -> x + y end)
    }
  end

  def mean(%__MODULE__{count: 0}), do: nil
  def mean(h), do: h.sum / h.count

  def percentile(h, p), do: h |> percentiles([p]) |> Map.fetch!(p)

  # one sort for many percentiles
  def percentiles(%__MODULE__{count: 0}, ps), do: Map.new(ps, &{&1, nil})

  def percentiles(h, ps) do
    sorted = Enum.sort(h.buckets)

    Map.new(ps, fn p ->
      cond do
        p >= 100 -> {p, h.max}
        p <= 0 -> {p, h.min}
        true -> {p, sorted |> walk(max(ceil(p / 100 * h.count), 1), 0) |> clamp(h)}
      end
    end)
  end

  def stats(h) do
    ps = percentiles(h, [50, 90, 95, 99, 99.9])

    %{
      "unit" => Atom.to_string(h.unit),
      "count" => h.count,
      "min" => h.min,
      "mean" => mean(h),
      "p50" => ps[50],
      "p90" => ps[90],
      "p95" => ps[95],
      "p99" => ps[99],
      "p99.9" => ps[99.9],
      "max" => if(h.count == 0, do: nil, else: h.max)
    }
  end

  defp walk([{i, n} | rest], rank, seen) do
    if seen + n >= rank, do: value(i), else: walk(rest, rank, seen + n)
  end

  defp walk([], _rank, _seen), do: nil

  defp clamp(nil, h), do: h.max
  defp clamp(v, h), do: v |> max(h.min) |> min(h.max)

  def index(v) when v < 128, do: v

  def index(v) do
    shift = bits(v, 0) - 7
    (shift <<< 6) + (v >>> shift)
  end

  # the middle of a bucket
  def value(i) when i < 128, do: i

  def value(i) do
    shift = (i >>> 6) - 1
    low = ((i &&& 63) ||| 64) <<< shift
    low + ((1 <<< shift) >>> 1)
  end

  defp bits(0, n), do: n
  defp bits(v, n) when v >= 0x10000, do: bits(v >>> 16, n + 16)
  defp bits(v, n) when v >= 0x100, do: bits(v >>> 8, n + 8)
  defp bits(v, n), do: bits(v >>> 1, n + 1)
end
