defmodule StressTester.Scrape do
  @moduledoc """
  The server's own account of the same minute. Before the load and after it,
  fetch a Prometheus-style `/metrics` page, and report what changed: counters as
  before → after, and histograms (`name_bucket{le="…"}`) as percentiles.

  What the tester sees from outside (round trips, snapshots that arrived) and what
  the server saw (ticks that ran long, packets the kernel dropped before the
  server read them) are different views; a run needs both to say where a problem is.

  Histogram percentiles are the upper edge of the bucket they fall in, so
  "p99 ≤ 33ms" means at most that. The unit comes from the name: `_ms`,
  `_seconds`, `_us`, `_bytes`, otherwise a plain number.

  The changes also become threshold subjects, named `server.NAME`:

      server.reach_slow_ticks:count == 0
      server.reach_tick_ms:p99 < 33ms
  """

  alias StressTester.{Histogram, Http, Net, Units}

  # %{url, headers: [{k, v}], insecure, timeout}
  def fetch(%{url: url} = spec) do
    with {:ok, origin} <- Net.origin(url) do
      conn = Http.new(origin, %{insecure: spec[:insecure] == true})
      headers = [{"connection", "close"} | spec[:headers] || []]

      case Http.request(conn, "GET", origin.path, headers, nil, spec[:timeout] || 5_000) do
        {:ok, conn, %{status: 200, body: body}} ->
          Http.close(conn)
          {:ok, parse(body)}

        {:ok, conn, %{status: status}} ->
          Http.close(conn)
          {:error, "status #{status}"}

        {:error, conn, reason} ->
          Http.close(conn)
          {:error, StressTester.Metrics.reason(reason)}
      end
    end
  end

  # text → %{"name" => value, "name{labels}" => value}, in the order of the page
  def parse(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      with false <- String.starts_with?(line, "#"),
           [series, value | _] <- String.split(line, ~r/\s+/, parts: 3),
           {number, ""} <- number(value) do
        Map.put(acc, series, number)
      else
        _ -> acc
      end
    end)
  end

  defp number(text) do
    case text do
      # a value that is not a finite number has nothing to subtract
      inf when inf in ["+Inf", "-Inf", "Inf", "NaN"] -> :error
      _ -> Float.parse(text)
    end
  end

  @doc "What changed. `seconds` is how long the load ran, for rates."
  def diff(before, after_, seconds) do
    {bucket_series, plain} = Enum.split_with(Map.keys(after_), &String.contains?(&1, "_bucket{"))

    histograms =
      bucket_series
      |> Enum.group_by(&base(&1))
      |> Map.new(fn {name, keys} -> {name, histogram(name, keys, before, after_)} end)
      |> Enum.reject(fn {_name, h} -> h == nil or h.count == 0 end)
      |> Map.new()

    hist_parts = Map.keys(histograms)
    skip = fn key -> Enum.any?(hist_parts, &(key == &1 <> "_count" or key == &1 <> "_sum")) end

    series =
      plain
      |> Enum.reject(skip)
      |> Enum.sort()
      |> Enum.map(fn key ->
        # a series the server had not recorded yet is absent from the first page, not unknown
        b = Map.get(before, key, 0)
        a = Map.fetch!(after_, key)
        %{name: key, before: b, after: a, delta: a - b}
      end)

    %{series: series, histograms: histograms, seconds: seconds}
  end

  defp base(key), do: key |> String.split("_bucket{", parts: 2) |> hd()

  # cumulative bucket counts, later minus earlier, turned back into samples at each bucket's upper edge
  defp histogram(name, keys, before, after_) do
    scale = scale(name)

    bounds =
      keys
      |> Enum.map(fn key ->
        [_, le] = Regex.run(~r/le="([^"]+)"/, key)
        {bound(le), Map.fetch!(after_, key) - Map.get(before, key, 0)}
      end)
      |> Enum.sort_by(fn {bound, _} -> if bound == :infinity, do: 1.0e300, else: bound end)

    finite = for {b, _} <- bounds, b != :infinity, do: b
    top = List.last(finite) || 0

    {h, _} =
      Enum.reduce(bounds, {Histogram.new(scale.unit), 0}, fn {bound, cumulative}, {h, seen} ->
        n = round(cumulative) - seen
        # anything past the last finite edge is reported as just past it
        edge = if bound == :infinity, do: top * 1.001, else: bound
        value = round(edge * scale.factor)
        {if(n > 0, do: Histogram.add(h, value, n), else: h), max(seen, round(cumulative))}
      end)

    h
  end

  defp bound("+Inf"), do: :infinity
  defp bound(text), do: elem(Float.parse(text), 0)

  defp scale(name) do
    cond do
      String.ends_with?(name, "_ms") -> %{unit: :us, factor: 1_000}
      String.ends_with?(name, "_seconds") -> %{unit: :us, factor: 1_000_000}
      String.ends_with?(name, ["_us", "_microseconds"]) -> %{unit: :us, factor: 1}
      String.ends_with?(name, "_bytes") -> %{unit: :bytes, factor: 1}
      true -> %{unit: :count, factor: 1}
    end
  end

  # numbers for thresholds: "server.NAME" → change; and histograms as "server.NAME"
  def counters(%{series: series}) do
    Map.new(series, fn s -> {"server." <> s.name, s.delta} end)
  end

  def histograms(%{histograms: hs}), do: Map.new(hs, fn {name, h} -> {"server." <> name, h} end)

  # -- for people

  def text(%{series: series, histograms: hs, seconds: seconds}, url) do
    shown = Enum.filter(series, fn s -> s.delta != 0 or (s.after || 0) != 0 end)

    width =
      (series ++ Enum.map(hs, fn {name, _} -> %{name: name} end))
      |> Enum.map(&String.length(&1.name))
      |> Enum.max(fn -> 10 end)

    hist_rows =
      hs
      |> Enum.sort()
      |> Enum.map(fn {name, h} ->
        ps = Histogram.percentiles(h, [50, 90, 99])
        unit = h.unit

        "  " <>
          String.pad_trailing(name, width) <>
          "  #{Units.count(h.count)} samples   p50 ≤#{Units.value(ps[50], unit)}  p90 ≤#{Units.value(ps[90], unit)}  p99 ≤#{Units.value(ps[99], unit)}  max ≤#{Units.value(h.max, unit)}"
      end)

    rows =
      Enum.map(shown, fn s ->
        change =
          cond do
            s.delta == 0 ->
              "#{figure(s.after)} (unchanged)"

            true ->
              "#{figure(s.before)} → #{figure(s.after)}  (#{sign(s.delta)}#{figure(s.delta)}, #{figure(s.delta / max(seconds, 0.001))}/s)"
          end

        "  " <> String.pad_trailing(s.name, width) <> "  " <> change
      end)

    Enum.join(["server      #{url}"] ++ hist_rows ++ rows ++ [""], "\n")
  end

  defp figure(n) when is_integer(n) or (is_float(n) and n == trunc(n) and abs(n) >= 1),
    do: Units.count(trunc(n))

  defp figure(n), do: Units.figure(n * 1.0)

  defp sign(n) when n > 0, do: "+"
  defp sign(_), do: ""

  # for the JSON report
  def json(%{series: series, histograms: hs}) do
    %{
      "series" =>
        Enum.map(
          series,
          &%{"name" => &1.name, "before" => &1.before, "after" => &1.after, "delta" => &1.delta}
        ),
      "histograms" => Map.new(hs, fn {name, h} -> {name, Histogram.stats(h)} end)
    }
  end
end
