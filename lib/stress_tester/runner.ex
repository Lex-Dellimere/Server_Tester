defmodule StressTester.Runner do
  @moduledoc """
  Runs a plan: the target's one-off checks, then the load on every machine,
  then the report. The checks run before the load so they see a quiet server,
  and all at once so they cost the slowest one.
  """

  alias StressTester.{Agent, Collector, Generator, History, Html, Load, Report, Scrape, Target}

  def run(plan) do
    target = plan.target

    with {:ok, shared} <- init(target, plan.options),
         {:ok, nodes} <- Agent.nodes(plan) do
      describe = Target.describe(target, shared)
      tell(plan, {:stress_started, %{target: describe, load: Load.describe(plan.load)}})
      checks = checks(target, shared, plan)
      tell(plan, {:stress_checks, checks})

      if checks != [],
        do:
          say(
            plan,
            "checks: #{Enum.count(checks, &(elem(&1, 1) == :ok))}/#{length(checks)} passed"
          )

      spec = scrape_spec(plan, shared)
      before = if spec, do: Scrape.fetch(spec)

      listener = plan.options[:listener]
      {:ok, root} = Collector.start(%{live: plan.live, watch: plan.watch, listener: listener})
      started = System.monotonic_time(:millisecond)
      generators = start(plan, shared, nodes, root)
      tell(plan, {:stress_generators, Enum.map(generators, &elem(&1, 0))})
      watcher = if spec && listener, do: watch_server(spec, listener, started)
      lost = await(generators, Load.duration(plan.load) + plan.load.grace_ms + 120_000)
      # linked so it dies with a crashed run; unlinked first so stopping it does not stop us
      if watcher do
        Process.unlink(watcher)
        Process.exit(watcher, :kill)
      end

      # a run stopped early is judged on the time it ran
      ran = min(Load.duration(plan.load), System.monotonic_time(:millisecond) - started)
      after_ = if spec, do: Scrape.fetch(spec)
      collected = Collector.finish(root)
      server = server_view(spec, before, after_, ran / 1_000)
      collected = %{collected | totals: lost_machines(collected.totals, lost)}

      derived = Target.derive(target, collected.totals.c, shared)

      report =
        plan
        |> Report.build(collected, checks, derived, describe, server, ran)
        |> History.add()

      if plan.print, do: IO.puts(Report.text(report))
      if plan.out, do: File.write!(plan.out, Report.json(report))
      if path = plan.options[:html], do: Html.write(report, path)
      {:ok, report}
    end
  end

  # the server's own metrics: --scrape URL, --scrape off, or what the target knows about its server
  defp scrape_spec(plan, shared) do
    opts = plan.options

    case opts[:scrape] do
      "off" ->
        nil

      url when is_binary(url) ->
        %{url: url, headers: headers(opts[:scrape_header]), insecure: opts[:insecure] == true}

      nil ->
        case Target.scrape(plan.target, shared) do
          nil ->
            nil

          spec ->
            Map.update(
              spec,
              :headers,
              headers(opts[:scrape_header]),
              &(&1 ++ headers(opts[:scrape_header]))
            )
        end
    end
  end

  defp headers(nil), do: []

  defp headers(list) do
    for text <- List.wrap(list),
        [k, v] <- [String.split(text, ":", parts: 2)],
        do: {String.downcase(String.trim(k)), String.trim(v)}
  end

  defp server_view(nil, _before, _after, _seconds), do: nil

  defp server_view(spec, {:ok, b}, {:ok, a}, seconds),
    do: %{url: spec.url, diff: Scrape.diff(b, a, seconds)}

  defp server_view(spec, {:error, reason}, _, _), do: %{url: spec.url, error: reason}
  defp server_view(spec, _, {:error, reason}, _), do: %{url: spec.url, error: reason}

  defp init(target, opts) do
    case target.init(opts) do
      {:ok, shared} -> {:ok, shared}
      {:error, reason} -> {:error, StressTester.Metrics.reason(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp checks(_target, _shared, %{checks: :none}), do: []

  defp checks(target, shared, plan) do
    list = Target.checks(target, shared, plan.checks)

    list
    |> Task.async_stream(fn {name, fun} -> {name, safe(fun)} end,
      timeout: 60_000,
      on_timeout: :kill_task,
      max_concurrency: max(length(list), 1),
      ordered: true
    )
    |> Enum.zip(list)
    |> Enum.map(fn
      {{:ok, result}, _} -> result
      {{:exit, _}, {name, _}} -> {name, {:error, "took longer than 60s"}}
    end)
  end

  defp safe(fun) do
    case fun.() do
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, {:bad_return, other}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp start(plan, shared, nodes, root) do
    count = length(nodes)

    nodes
    |> Enum.with_index()
    |> Enum.map(fn {node, index} ->
      spec = %{
        target: plan.target,
        shared: shared,
        load: plan.load,
        index: index,
        count: count,
        root: root,
        coordinator: self(),
        shards: plan.shards || :erpc.call(node, System, :schedulers_online, [])
      }

      pid =
        if node == node(),
          do: Generator.start(spec),
          else: :erpc.call(node, Generator, :start, [spec])

      {pid, Process.monitor(pid)}
    end)
  end

  defp await(generators, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait(Map.new(generators), deadline, [])
  end

  defp wait(left, _deadline, lost) when map_size(left) == 0, do: lost

  defp wait(left, deadline, lost) do
    receive do
      {:generator_done, pid} ->
        {ref, left} = Map.pop(left, pid)
        if ref, do: Process.demonitor(ref, [:flush])
        wait(left, deadline, lost)

      {:DOWN, _ref, :process, pid, reason} ->
        wait(Map.delete(left, pid), deadline, [{node(pid), reason} | lost])
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Enum.each(left, fn {pid, _} -> send(pid, :abort) end)
        Enum.map(left, fn {pid, _} -> {node(pid), :timeout} end) ++ lost
    end
  end

  defp lost_machines(totals, []), do: totals

  defp lost_machines(totals, lost) do
    Enum.reduce(lost, totals, fn {node, reason}, t ->
      key = {"machine", "#{node}: #{StressTester.Metrics.reason(reason)}"}
      %{t | e: Map.update(t.e, key, 1, &(&1 + 1)), c: Map.update(t.c, "errors", 1, &(&1 + 1))}
    end)
  end

  defp tell(plan, message) do
    if pid = plan.options[:listener], do: send(pid, message)
    :ok
  end

  # the server's /metrics every two seconds while the load runs, as numbers for that interval
  defp watch_server(spec, listener, started) do
    spawn_link(fn -> watch_loop(spec, listener, started, nil) end)
  end

  defp watch_loop(spec, listener, started, prev) do
    now = System.monotonic_time(:millisecond)

    prev =
      case Scrape.fetch(spec) do
        {:ok, page} ->
          if prev do
            {at, last} = prev
            secs = max((now - at) / 1_000, 0.001)

            send(
              listener,
              {:stress_server, server_sample(Scrape.diff(last, page, secs), page, now - started)}
            )
          end

          {now, page}

        {:error, _} ->
          prev
      end

    Process.sleep(2_000)
    watch_loop(spec, listener, started, prev)
  end

  defp server_sample(diff, page, ms) do
    %{
      "t" => round(ms / 1_000),
      "histograms" =>
        Map.new(diff.histograms, fn {name, h} ->
          ps = StressTester.Histogram.percentiles(h, [50, 99])
          {name, %{"p50" => ps[50], "p99" => ps[99], "count" => h.count, "unit" => h.unit}}
        end),
      # how fast each counter grew in the interval
      "rates" => Map.new(diff.series, fn s -> {s.name, s.delta / max(diff.seconds, 0.001)} end),
      "values" => Map.reject(page, fn {k, _} -> String.contains?(k, "{") end)
    }
  end

  defp say(%{print: false}, _text), do: :ok
  defp say(_plan, text), do: IO.puts(text)
end
