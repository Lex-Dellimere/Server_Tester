defmodule StressTester.Threshold do
  @moduledoc """
  A pass or fail rule on one number from the run:

      http.req:p99 < 250ms             a percentile (p50, p90, p95, p99, p99.9, any pNN), min, max, mean
      iterations.failed:ratio < 1%     failed iterations out of all iterations
      vu.connect_failed == 0           a counter; count is the stat when none is named
      reach.snapshot:rate > 1000       per second over the run
      reach.snapshot_hz > 25           a number the target works out at the end

  A bare number after a time is milliseconds; after a size, bytes.
  `:ratio` on a `vu.` counter is out of the users started.
  """

  alias StressTester.{Histogram, Units}

  defstruct [:text, :subject, :stat, :op, :number, :unit]

  @re ~r/^\s*(?<subject>[^:<>=!]+?)\s*(?::\s*(?<stat>[a-z0-9.]+))?\s*(?<op><=|>=|==|!=|<|>)\s*(?<num>-?\d+(?:\.\d+)?)\s*(?<unit>[a-zµ%\/]*)\s*$/i

  def parse(%__MODULE__{} = t), do: {:ok, t}

  def parse(text) when is_binary(text) do
    case Regex.named_captures(@re, text) do
      nil ->
        {:error, "#{inspect(text)} is not a threshold (try 'http.req:p99<250ms')"}

      m ->
        {num, _} = Float.parse(m["num"])

        {:ok,
         %__MODULE__{
           text: String.trim(text),
           subject: m["subject"],
           stat: if(m["stat"] == "", do: nil, else: String.downcase(m["stat"])),
           op: String.to_atom(m["op"]),
           number: num,
           unit: String.downcase(m["unit"])
         }}
    end
  end

  def parse_all(list) do
    Enum.reduce_while(List.wrap(list), {:ok, []}, fn text, {:ok, acc} ->
      case parse(text) do
        {:ok, t} -> {:cont, {:ok, acc ++ [t]}}
        error -> {:halt, error}
      end
    end)
  end

  # summary: %{counters, hists, values, elapsed_ms}
  def eval(%__MODULE__{} = t, summary) do
    case actual(t, summary) do
      {:ok, value, unit} -> {compare(t.op, value, limit(t, unit)), value, unit}
      :no_data -> {false, nil, nil}
    end
  end

  defp actual(t, s) do
    hist = Map.get(s.hists, t.subject)
    stat = t.stat || if(Map.has_key?(s.values, t.subject), do: "value", else: "count")

    cond do
      stat == "value" ->
        if v = s.values[t.subject], do: {:ok, v, value_unit(t.subject)}, else: :no_data

      stat == "count" ->
        {:ok, count(t.subject, s, hist), :count}

      stat == "rate" ->
        {:ok, count(t.subject, s, hist) / max(s.elapsed_ms / 1_000, 0.001), :rate}

      stat == "ratio" ->
        {:ok, ratio(t.subject, s.counters), :ratio}

      hist == nil or hist.count == 0 ->
        :no_data

      stat == "min" ->
        {:ok, hist.min, hist.unit}

      stat == "max" ->
        {:ok, hist.max, hist.unit}

      stat == "mean" ->
        {:ok, Histogram.mean(hist), hist.unit}

      String.starts_with?(stat, "p") ->
        case Float.parse(String.trim_leading(stat, "p")) do
          {p, ""} -> {:ok, Histogram.percentile(hist, p), hist.unit}
          _ -> :no_data
        end

      true ->
        :no_data
    end
  end

  # numbers a target works out: names ending _ratio or _loss are fractions (so 5% works on them)
  def value_unit(name),
    do: if(String.ends_with?(name, ["_ratio", "_loss"]), do: :ratio, else: :count)

  defp count(name, s, hist), do: Map.get(s.counters, name) || (hist && hist.count) || 0

  defp ratio("iterations." <> _ = name, c), do: share(c[name], c["iterations"])
  defp ratio("vu." <> _ = name, c), do: share(c[name], c["vu.started"])
  defp ratio("dropped", c), do: share(c["dropped"], (c["dropped"] || 0) + (c["iterations"] || 0))
  defp ratio(name, c), do: share(c[name], c["iterations"])

  defp share(nil, _), do: 0.0
  defp share(_n, d) when d in [nil, 0], do: 0.0
  defp share(n, d), do: n / d

  defp limit(t, :us) do
    case t.unit do
      u when u in ["us", "µs"] -> t.number
      "s" -> t.number * 1_000_000
      _ -> t.number * 1_000
    end
  end

  defp limit(t, :bytes) do
    case t.unit do
      "kb" -> t.number * 1_024
      "mb" -> t.number * 1_048_576
      "gb" -> t.number * 1_073_741_824
      _ -> t.number
    end
  end

  defp limit(t, :ratio), do: if(t.unit == "%", do: t.number / 100, else: t.number)
  defp limit(t, _unit), do: t.number

  defp compare(:<, a, b), do: a < b
  defp compare(:<=, a, b), do: a <= b
  defp compare(:>, a, b), do: a > b
  defp compare(:>=, a, b), do: a >= b
  defp compare(:==, a, b), do: a == b
  defp compare(:!=, a, b), do: a != b

  def show(nil, _unit), do: "no data"
  def show(v, :ratio), do: Units.percent(v)
  def show(v, :rate), do: "#{Units.count(v * 1.0)}/s"
  def show(v, :count), do: Units.count(v)
  def show(v, unit), do: Units.value(v, unit)
end
