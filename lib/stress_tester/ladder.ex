defmodule StressTester.Ladder do
  @moduledoc """
  "How many can it take?" Runs the same test at a growing load, one rung at a
  time, and stops at the first rung that fails:

      stress ladder reach 127.0.0.1:4001 --steps 25,50,100,200,400 --duration 20s
      stress ladder http http://127.0.0.1:4001/v1/meta --by rate --steps 100,500,1000,2000

  Each rung is a full run (its own ramp, its own thresholds); the one-off checks
  run only before the first. Between rungs the server gets a few seconds to
  settle, so one rung's leftovers (sockets closing, battles ending) are not
  counted against the next.

  The answer is the highest rung that passed. It is only as good as the
  machine: with the tester on the same box as the server, both get slower.
  """

  alias StressTester.{Histogram, Plan, Units}

  @settle_ms 5_000

  # steps: [25, 50, ...]; by: :vus | :rate. Returns {:ok, rungs} with rungs in order.
  def run(opts, steps, by \\ :vus) do
    opts = Map.new(opts)
    keep_going = Map.get(opts, :keep_going, false)
    settle = Map.get(opts, :settle_ms, @settle_ms)
    say = if opts[:silent], do: fn _ -> :ok end, else: &IO.puts/1

    with {:ok, plan} <- Plan.build(Map.put(opts, by, hd(steps))), do: say.(header(plan, by))

    rungs =
      steps
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {step, i}, acc ->
        if i > 0, do: Process.sleep(settle)

        # the dashboard can ask the ladder to stop between rungs
        if halted?(opts) do
          {:halt, acc}
        else
          case rung(opts, step, by, i == 0) do
            {:ok, report} ->
              row = summarize(step, report, by)
              say.(if i == 0, do: table_head(row, by) <> "\n" <> line(row), else: line(row))
              if f = opts[:on_rung], do: f.(row, report)
              acc = [row | acc]

              if (row.ok or keep_going) and not halted?(opts),
                do: {:cont, acc},
                else: {:halt, acc}

            {:error, reason} ->
              {:halt, [%{step: step, error: reason, ok: false} | acc]}
          end
        end
      end)
      |> Enum.reverse()

    case Enum.find(rungs, &Map.has_key?(&1, :error)) do
      %{error: reason} -> {:error, reason}
      nil -> {:ok, rungs}
    end
  end

  defp halted?(opts), do: (f = opts[:halt?]) != nil and f.()

  defp rung(opts, step, by, first?) do
    other = if by == :vus, do: :rate, else: :vus

    opts
    |> Map.drop([other])
    |> Map.put(by, step_value(step, by))
    |> Map.drop([:on_rung, :halt?, :settle_ms, :keep_going])
    |> Map.merge(%{silent: true, quiet: true})
    |> Map.put_new(:duration, "20s")
    |> Map.put_new(:ramp, "10s")
    |> then(fn o -> if first?, do: o, else: Map.put(o, :checks, "none") end)
    |> StressTester.run()
  end

  defp step_value(step, :rate), do: step * 1.0
  defp step_value(step, :vus), do: step

  # one rung's numbers, from its report
  def summarize(step, r, by) do
    c = r.counters
    secs = max(r.seconds, 0.001)
    watch = r.watch
    failing = for t <- r.thresholds, not t["ok"], do: "#{t["threshold"]} (#{t["shown"]})"
    failing = failing ++ for ch <- r.checks, not ch["ok"], do: "check #{ch["check"]}"

    %{
      step: step,
      by: by,
      ok: r.ok,
      users: r.tester["peak_users"],
      connect_failed: c["vu.connect_failed"] || 0,
      lost: c["vu.lost"] || 0,
      iterations_per_s: (c["iterations"] || 0) / secs,
      dropped: c["dropped"] || 0,
      watch: Enum.map(watch, fn name -> {name, headline(name, r, secs)} end),
      server: server_tick(r.server),
      tester_cpu: r.tester["cpu_peak"],
      failing: failing
    }
  end

  # a histogram's p99, or a counter's rate
  defp headline(name, r, secs) do
    case r.metrics[name] do
      %{"p99" => p99, "unit" => unit} when p99 != nil ->
        {:time, p99, String.to_existing_atom(unit)}

      _ ->
        {:rate, (r.counters[name] || 0) / secs}
    end
  end

  # the first histogram the server published, as "at most" its p99
  defp server_tick(%{diff: %{histograms: hs}}) when map_size(hs) > 0 do
    {name, h} = hs |> Enum.sort() |> hd()
    {name, Histogram.percentile(h, 99), h.unit}
  end

  defp server_tick(_), do: nil

  # -- text

  defp header(plan, by) do
    "ladder: #{plan.target |> Module.split() |> List.last()}, each rung #{Units.time(StressTester.Load.duration(plan.load) * 1_000)} " <>
      "by #{if by == :rate, do: "rate (iterations a second)", else: "users"}\n"
  end

  defp table_head(row, by) do
    cols =
      [
        pad(if(by == :rate, do: "rate", else: "users"), 7),
        pad("iter/s", 9),
        pad("conn fail", 10),
        pad("lost", 6)
      ] ++
        Enum.map(row.watch, fn {name, _} -> pad(short(name), 22) end) ++
        if(row.server, do: [pad(short(elem(row.server, 0)) <> " p99", 24)], else: []) ++
        [pad("tester cpu", 11), "verdict"]

    Enum.join(cols, "")
  end

  def line(%{error: reason, step: step}),
    do: "#{pad(Integer.to_string(step), 7)}could not run: #{reason}"

  def line(row) do
    cols =
      [
        pad(Units.count(row.step), 7),
        pad(Units.figure(row.iterations_per_s), 9),
        pad(Units.count(row.connect_failed), 10),
        pad(Units.count(row.lost), 6)
      ] ++
        Enum.map(row.watch, fn
          {_, {:time, v, unit}} -> pad("p99 " <> Units.value(v, unit), 22)
          {_, {:rate, v}} -> pad(Units.figure(v) <> "/s", 22)
        end) ++
        if(row.server,
          do: [pad("≤" <> Units.value(elem(row.server, 1), elem(row.server, 2)), 24)],
          else: []
        ) ++
        [pad(Units.percent(row.tester_cpu || 0.0), 11), if(row.ok, do: "PASS", else: "FAIL")]

    Enum.join(cols, "")
  end

  defp short(name),
    do: name |> String.replace_prefix("reach.", "") |> String.replace_prefix("server.", "")

  defp pad(text, width), do: String.pad_trailing(text, width)

  @doc "The words at the end: the highest rung that passed, and why the next one did not."
  def verdict(rungs) do
    passed = Enum.filter(rungs, & &1.ok)
    failed = Enum.find(rungs, &(not &1.ok))
    best = List.last(passed)

    [
      if(best,
        do: "\nhighest rung that passed: #{Units.count(best.step)}",
        else: "\nno rung passed"
      ),
      if(failed,
        do:
          "first failure at #{Units.count(failed.step)}: " <>
            Enum.join(Map.get(failed, :failing, []), "; "),
        else: nil
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end
