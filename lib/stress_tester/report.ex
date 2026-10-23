defmodule StressTester.Report do
  @moduledoc """
  The end of a run, as data (`build/5`, `json/1`) and as text (`text/1`), plus
  the one line a second printed while it runs (`live/2`).
  """

  alias StressTester.{Histogram, Load, Scrape, Threshold, Units}

  # a struct so IEx prints one line for it, not pages; `show(r)` prints the rest
  defstruct [
    :ok,
    :run,
    :target,
    :description,
    :finished_at,
    :load,
    :seconds,
    :server,
    :tester,
    counters: %{},
    metrics: %{},
    values: %{},
    errors: [],
    watch: [],
    checks: [],
    thresholds: [],
    timeline: []
  ]

  def build(plan, collected, checks, derived, describe, server \\ nil) do
    totals = collected.totals
    elapsed_ms = Load.duration(plan.load)
    {server_c, server_h} = server_numbers(server)

    summary = %{
      counters: Map.merge(totals.c, server_c),
      hists: Map.merge(totals.h, server_h),
      values: derived,
      elapsed_ms: elapsed_ms
    }

    thresholds =
      Enum.map(plan.thresholds, fn t ->
        {ok, actual, unit} = Threshold.eval(t, summary)

        %{
          "threshold" => t.text,
          "ok" => ok,
          "actual" => actual,
          "shown" => Threshold.show(actual, unit)
        }
      end)

    checks =
      Enum.map(checks, fn {name, result} ->
        %{"check" => name, "ok" => result == :ok, "detail" => detail(result)}
      end)

    errors =
      totals.e
      |> Enum.sort_by(fn {_k, n} -> -n end)
      |> Enum.map(fn {{where, why}, n} -> %{"where" => where, "reason" => why, "count" => n} end)

    lag = Map.get(totals.h, "vu.lag")

    %__MODULE__{
      ok: Enum.all?(thresholds, & &1["ok"]) and Enum.all?(checks, & &1["ok"]),
      target: describe,
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      description: plan.options[:description],
      load: Load.describe(plan.load),
      seconds: elapsed_ms / 1_000,
      counters: totals.c,
      metrics: Map.new(totals.h, fn {name, h} -> {name, Histogram.stats(h)} end),
      values: derived,
      errors: errors,
      server: server,
      watch: plan.watch,
      checks: checks,
      thresholds: thresholds,
      tester: %{
        "machines" => max(collected.nodes, 1),
        "peak_users" => collected.peak["vus"],
        "cpu_peak" => collected.peak["cpu"],
        "run_queue_peak" => collected.peak["run_queue"],
        "lag_p99" => lag && Histogram.percentile(lag, 99),
        "pace_us" => plan.load.pace_ms && plan.load.pace_ms * 1_000
      },
      timeline: collected.timeline
    }
  end

  defp server_numbers(%{diff: diff}), do: {Scrape.counters(diff), Scrape.histograms(diff)}
  defp server_numbers(_), do: {%{}, %{}}

  defp detail(:ok), do: ""
  defp detail({:error, reason}), do: StressTester.Metrics.reason(reason)
  defp detail(other), do: StressTester.Metrics.reason(other)

  def json(report),
    do: report |> Map.from_struct() |> Map.update!(:server, &server_json/1) |> JSON.encode!()

  defp server_json(nil), do: nil
  defp server_json(%{diff: diff, url: url}), do: Map.put(Scrape.json(diff), "url", url)
  defp server_json(%{error: error, url: url}), do: %{"url" => url, "error" => error}

  # -- the end of a run, for people

  def text(r) do
    c = r.counters
    secs = max(r.seconds, 0.001)

    [
      "",
      r.target,
      r.load,
      if(r.description, do: r.description),
      "",
      users(c, r.metrics),
      iterations(c, secs),
      dropped(c),
      "",
      table(r.metrics, secs),
      counters(c, secs),
      values(r.values),
      server(r.server),
      errors(r.errors),
      checks(r.checks),
      thresholds(r.thresholds),
      tester(r.tester),
      verdict(r)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp users(c, metrics) do
    connect = metrics["vu.connect"]

    timing =
      if connect,
        do: "   connect p50 #{Units.time(connect["p50"])}  p99 #{Units.time(connect["p99"])}",
        else: ""

    "users       #{n(c["vu.started"])} started, #{n(c["vu.connected"])} connected, " <>
      "#{n(c["vu.connect_failed"])} failed, #{n(c["vu.lost"])} lost" <> timing
  end

  defp iterations(c, secs) do
    "iterations  #{n(c["iterations"])} (#{rate(c["iterations"], secs)}), #{n(c["iterations.failed"])} failed"
  end

  defp dropped(%{"dropped" => d}) when d > 0,
    do: "dropped     #{n(d)} iterations found every user busy (raise --max-vus)"

  defp dropped(_), do: nil

  @hidden ["vu.connect", "vu.lag"]

  defp table(metrics, secs) do
    rows =
      metrics
      |> Enum.reject(fn {name, _} -> name in @hidden end)
      |> Enum.sort_by(fn {name, _} -> {name != "iteration", name} end)

    if rows == [] do
      nil
    else
      width = rows |> Enum.map(fn {name, _} -> String.length(name) end) |> Enum.max() |> max(10)
      head = String.pad_trailing("", width) <> cols(["count", "rate", "p50", "p90", "p99", "max"])

      body =
        Enum.map(rows, fn {name, m} ->
          unit = String.to_existing_atom(m["unit"])

          String.pad_trailing(name, width) <>
            cols([
              n(m["count"]),
              rate(m["count"], secs),
              Units.value(m["p50"], unit),
              Units.value(m["p90"], unit),
              Units.value(m["p99"], unit),
              Units.value(m["max"], unit)
            ])
        end)

      [head | body] ++ [""]
    end
  end

  defp cols(values), do: Enum.map_join(values, "", &String.pad_leading(&1, 11))

  @shown_elsewhere ~w(vu.started vu.connected vu.connect_failed vu.lost iterations iterations.failed dropped errors)

  defp counters(c, secs) do
    rows = c |> Enum.reject(fn {k, _} -> k in @shown_elsewhere end) |> Enum.sort()

    if rows == [] do
      nil
    else
      width = rows |> Enum.map(fn {k, _} -> String.length(k) end) |> Enum.max() |> max(10)

      ["counters"] ++
        Enum.map(rows, fn {k, v} ->
          "  " <>
            String.pad_trailing(k, width) <>
            String.pad_leading(n(v), 14) <> String.pad_leading(rate(v, secs), 14)
        end) ++ [""]
    end
  end

  defp values(v) when map_size(v) == 0, do: nil

  defp values(v) do
    width = v |> Map.keys() |> Enum.map(&String.length/1) |> Enum.max()

    shown = fn k, x ->
      if Threshold.value_unit(k) == :ratio, do: Units.percent(x), else: Units.figure(x)
    end

    ["values"] ++
      Enum.map(Enum.sort(v), fn {k, x} ->
        "  " <> String.pad_trailing(k, width) <> String.pad_leading(shown.(k, x), 12)
      end) ++
      [""]
  end

  defp server(nil), do: nil
  defp server(%{error: error, url: url}), do: ["server      #{url}: unavailable (#{error})", ""]
  defp server(%{diff: diff, url: url}), do: Scrape.text(diff, url)

  defp errors([]), do: nil

  defp errors(list) do
    total = Enum.reduce(list, 0, &(&1["count"] + &2))

    ["errors (#{n(total)})"] ++
      Enum.map(Enum.take(list, 15), fn e ->
        "  #{String.pad_leading(n(e["count"]), 8)}  #{e["where"]}: #{e["reason"]}"
      end) ++ if(length(list) > 15, do: ["  … #{length(list) - 15} more kinds", ""], else: [""])
  end

  defp checks([]), do: nil

  defp checks(list) do
    ["checks"] ++
      Enum.map(list, fn c ->
        mark(c["ok"]) <> c["check"] <> if(c["detail"] == "", do: "", else: ": " <> c["detail"])
      end) ++ [""]
  end

  defp thresholds([]), do: nil

  defp thresholds(list) do
    width = list |> Enum.map(&String.length(&1["threshold"])) |> Enum.max()

    ["thresholds"] ++
      Enum.map(list, fn t ->
        mark(t["ok"]) <> String.pad_trailing(t["threshold"], width) <> "   " <> t["shown"]
      end) ++
      [""]
  end

  defp mark(true), do: "  ok    "
  defp mark(false), do: "  FAIL  "

  defp tester(t) do
    lag = if t["lag_p99"], do: ", lag p99 #{Units.time(t["lag_p99"])}", else: ""
    machines = if t["machines"] > 1, do: "#{t["machines"]} machines, ", else: ""

    line =
      "tester      #{machines}peak #{n(t["peak_users"])} users, cpu peak #{Units.percent(t["cpu_peak"])}, run queue peak #{t["run_queue_peak"]}#{lag}"

    busy? =
      t["cpu_peak"] > 0.9 or
        (t["pace_us"] != nil and t["lag_p99"] != nil and t["lag_p99"] > t["pace_us"] / 2)

    if busy?,
      do: [
        line,
        "            the tester itself was busy; the server may be better than these numbers",
        ""
      ],
      else: [line, ""]
  end

  defp verdict(%{ok: true}), do: "PASS"

  defp verdict(r) do
    t = Enum.count(r.thresholds, &(not &1["ok"]))
    c = Enum.count(r.checks, &(not &1["ok"]))

    parts =
      [{t, "threshold"}, {c, "check"}]
      |> Enum.reject(fn {k, _} -> k == 0 end)
      |> Enum.map_join(", ", fn {k, word} -> "#{k} #{word}#{if k > 1, do: "s"}" end)

    "FAIL: #{parts}"
  end

  # -- one line a second

  def live(p, watch) do
    c = p["counters"]
    it = p["metrics"]["iteration"]

    head =
      "#{String.pad_leading("#{p["t"]}s", 6)}  users #{n(p["vus"])}" <>
        if(p["connecting"] > 0, do: " (+#{n(p["connecting"])} connecting)", else: "") <>
        "  iter #{n(c["iterations"] || 0)}/s" <>
        if(it, do: " p99 #{Units.time(it["p99"])}", else: "") <>
        "  fail #{n(c["iterations.failed"] || 0)}  err #{n(c["errors"] || 0)}"

    parts =
      Enum.flat_map(watch, fn name ->
        case p["metrics"][name] do
          %{"count" => count, "p50" => p50, "p99" => p99, "unit" => unit} ->
            ["#{name} #{n(count)}/s p50 #{Units.value(p50, unit)} p99 #{Units.value(p99, unit)}"]

          nil ->
            if v = c[name], do: ["#{name} #{n(v)}/s"], else: []
        end
      end)

    Enum.join([head | parts], "  | ")
  end

  defp n(nil), do: "0"
  defp n(v), do: Units.count(v)

  defp rate(nil, _secs), do: "0/s"
  defp rate(v, secs), do: "#{Units.count(v / secs)}/s"
end

defimpl Inspect, for: StressTester.Report do
  def inspect(r, _opts) do
    verdict = if r.ok, do: "PASS", else: "FAIL"
    run = if r.run, do: "run #{r.run} · ", else: ""
    "#StressTester.Report<#{run}#{verdict} · #{r.target} · #{r.load} · show(r) prints it all>"
  end
end
