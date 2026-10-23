defmodule StressTester.Collector do
  @moduledoc """
  Adds up what every user recorded. Users send to a shard on their own machine;
  shards fold what they got and pass it here once a second. This process keeps
  the totals and one line per second (the timeline), and prints that line as
  the run goes.
  """

  use GenServer

  alias StressTester.{Histogram, Metrics, Report}

  @max_errors 100

  def start(opts), do: GenServer.start(__MODULE__, opts)

  def window(root, data), do: GenServer.cast(root, {:window, data})
  def window_sync(root, data), do: GenServer.call(root, {:window, data}, 60_000)
  def gauge(root, node, gauges), do: GenServer.cast(root, {:gauge, node, gauges})
  def finish(root), do: GenServer.call(root, :finish, 60_000)

  @impl true
  def init(opts) do
    Process.send_after(self(), :tick, 1_000)

    {:ok,
     %{
       t0: System.monotonic_time(:millisecond),
       totals: Metrics.empty(),
       second: Metrics.empty(),
       gauges: %{},
       peak: %{"vus" => 0, "cpu" => 0.0, "run_queue" => 0},
       timeline: [],
       live: Map.get(opts, :live, true),
       watch: Map.get(opts, :watch, [])
     }}
  end

  @impl true
  def handle_cast({:window, data}, s), do: {:noreply, add(s, data)}

  def handle_cast({:gauge, node, gauges}, s),
    do: {:noreply, %{s | gauges: Map.put(s.gauges, node, gauges)}}

  @impl true
  def handle_call({:window, data}, _from, s), do: {:reply, :ok, add(s, data)}

  # what came in after the last full second (users leaving, final counts) is a
  # partial point: in the totals, but not a second like the others
  def handle_call(:finish, _from, s) do
    s = point(s)
    s = %{s | timeline: [Map.put(hd(s.timeline), "partial", true) | tl(s.timeline)]}

    {:stop, :normal,
     %{
       totals: s.totals,
       timeline: Enum.reverse(s.timeline),
       peak: s.peak,
       nodes: map_size(s.gauges)
     }, s}
  end

  @impl true
  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, 1_000)
    s = point(s)
    if s.live, do: IO.puts(Report.live(hd(s.timeline), s.watch))
    {:noreply, s}
  end

  defp add(s, data) do
    %{
      s
      | totals: s.totals |> Metrics.merge(data) |> Metrics.cap_errors(@max_errors),
        second: s.second |> Metrics.merge(data) |> Metrics.cap_errors(@max_errors)
    }
  end

  # one line of the timeline: this second's counts, and the users right now
  defp point(s) do
    g = Map.values(s.gauges)
    vus = Enum.reduce(g, 0, &(&1["vus"] + &2))
    cpu = Enum.reduce(g, 0.0, &max(&1["cpu"], &2))
    rq = Enum.reduce(g, 0, &max(&1["run_queue"], &2))

    p = %{
      "t" => round((System.monotonic_time(:millisecond) - s.t0) / 1_000),
      "vus" => vus,
      "connecting" => Enum.reduce(g, 0, &(&1["connecting"] + &2)),
      "cpu" => cpu,
      "run_queue" => rq,
      "counters" => s.second.c,
      "metrics" =>
        Map.new(s.second.h, fn {name, h} ->
          ps = Histogram.percentiles(h, [50, 99])

          {name,
           %{
             "count" => h.count,
             "p50" => ps[50],
             "p99" => ps[99],
             "max" => h.max,
             "unit" => h.unit
           }}
        end)
    }

    peak = %{
      "vus" => max(s.peak["vus"], vus),
      "cpu" => max(s.peak["cpu"], cpu),
      "run_queue" => max(s.peak["run_queue"], rq)
    }

    %{s | timeline: [p | s.timeline], second: Metrics.empty(), peak: peak}
  end
end

defmodule StressTester.Collector.Shard do
  @moduledoc false
  # folds the numbers of the users on one machine, so the root sees one message per shard per second

  use GenServer

  alias StressTester.{Collector, Metrics}

  def start_link(root) do
    {:ok, pid} = GenServer.start_link(__MODULE__, root)
    pid
  end

  def record(shard, data), do: send(shard, {:record, data})
  def record_sync(shard, data), do: GenServer.call(shard, {:record, data}, 60_000)
  def drain(shard), do: GenServer.call(shard, :drain, 60_000)

  @impl true
  def init(root) do
    Process.send_after(self(), :pass, 1_000)
    {:ok, %{root: root, data: Metrics.empty()}}
  end

  @impl true
  def handle_info({:record, data}, s), do: {:noreply, %{s | data: Metrics.merge(s.data, data)}}

  def handle_info(:pass, s) do
    Process.send_after(self(), :pass, 1_000)
    unless Metrics.empty?(s.data), do: Collector.window(s.root, s.data)
    {:noreply, %{s | data: Metrics.empty()}}
  end

  @impl true
  def handle_call({:record, data}, _from, s),
    do: {:reply, :ok, %{s | data: Metrics.merge(s.data, data)}}

  def handle_call(:drain, _from, s) do
    unless Metrics.empty?(s.data), do: Collector.window_sync(s.root, s.data)
    {:reply, :ok, %{s | data: Metrics.empty()}}
  end
end
