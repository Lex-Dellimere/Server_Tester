defmodule StressTester.Generator do
  @moduledoc """
  One machine's share of a run. With n machines, machine i runs users i+1,
  i+1+n, i+1+2n… and, at a fixed rate, every n-th arrival. Names stay unique
  across machines and the ramp keeps its shape however many share it.

  Every 100 ms it compares the users it has with what the stages ask for, and
  starts or stops users (no faster than `spawn_rate`). Once a second it tells
  the root how many users are up and how busy this machine is, so a report can
  say when the tester, not the server, was the bottleneck.
  """

  alias StressTester.{Collector, Load, Metrics, Vu}
  alias StressTester.Collector.Shard

  @control_ms 100
  @backoff_ms 1_000
  @backoff_max_ms 10_000

  def start(spec), do: spawn(fn -> run(spec) end)

  defp run(spec) do
    :erlang.system_flag(:scheduler_wall_time, true)
    shards = for _ <- 1..max(spec.shards, 1), do: Shard.start_link(spec.root)
    load = spec.load
    n = spec.count

    s = %{
      spec: spec,
      shards: List.to_tuple(shards),
      t0: Metrics.now(),
      duration_us: Load.duration(load) * 1_000,
      vus: %{},
      ids: %{},
      backoff: %{},
      fails: %{},
      idle: :queue.new(),
      next_id: 0,
      tokens: spawn_burst(load),
      tokens_at: Metrics.now(),
      sample: :scheduler.sample(),
      segments: if(load.model == :open, do: Load.segments(load), else: []),
      k: spec.index + 1,
      next_at: nil,
      local_vus: share(load.vus, spec.index, n),
      local_max: max(share(load.max_vus, spec.index, n), 1)
    }

    s = if load.model == :open, do: s |> advance() |> preallocate(), else: s
    send(self(), :control)
    Process.send_after(self(), :gauge, 1_000)
    loop(s)
  end

  defp loop(s) do
    receive do
      :control -> control(s)
      :gauge -> s |> gauge() |> loop()
      {:connected, pid} -> s |> connected(pid) |> loop()
      {:idle, pid} -> s |> idle(pid) |> dispatch() |> loop()
      {:DOWN, _ref, :process, pid, reason} -> s |> down(pid, reason) |> loop()
      :abort -> shutdown(s)
    after
      timeout(s) -> s |> dispatch() |> loop()
    end
  end

  defp timeout(%{next_at: nil}), do: :infinity

  defp timeout(s) do
    wait = div(s.next_at - (Metrics.now() - s.t0) + 999, 1_000)
    max(wait, 0)
  end

  defp control(s) do
    elapsed = Metrics.now() - s.t0

    if elapsed >= s.duration_us do
      shutdown(s)
    else
      s = refill(s)
      s = if s.spec.load.model == :closed, do: adjust(s, elapsed), else: s
      Process.send_after(self(), :control, @control_ms)
      loop(s)
    end
  end

  # -- closed: as many users as the stage asks for right now

  defp adjust(s, elapsed) do
    want = share(round(Load.value_at(s.spec.load, elapsed / 1_000)), s.spec.index, s.spec.count)
    s = forget_expired(s)

    # a user that is backing off still holds its place; its own number comes back when the wait is over
    have = map_size(s.ids) + map_size(s.backoff)

    cond do
      want > have -> grow(s, want - have)
      want < have -> shrink(s, have - want)
      true -> s
    end
  end

  defp grow(s, n) do
    n = if s.tokens == :unlimited, do: n, else: min(n, trunc(s.tokens))
    now = System.monotonic_time(:millisecond)
    free = free_ids(s, n, now)

    s = Enum.reduce(free, s, fn id, s -> start_vu(s, id, nil) end)
    if s.tokens == :unlimited, do: s, else: %{s | tokens: s.tokens - length(free)}
  end

  defp free_ids(_s, 0, _now), do: []

  defp free_ids(s, n, now) do
    Stream.iterate(s.spec.index + 1, &(&1 + s.spec.count))
    |> Stream.reject(fn id -> Map.has_key?(s.ids, id) or backing_off?(s.backoff, id, now) end)
    |> Enum.take(n)
  end

  defp forget_expired(s) do
    now = System.monotonic_time(:millisecond)
    %{s | backoff: Map.reject(s.backoff, fn {_id, until} -> until <= now end)}
  end

  # monotonic time can be negative, so "no entry" is not the same as 0
  defp backing_off?(backoff, id, now) do
    case backoff do
      %{^id => until} -> until > now
      _ -> false
    end
  end

  # ramping down: users that are only waiting to come back go first
  defp shrink(s, n) do
    waiting = s.backoff |> Map.keys() |> Enum.sort(:desc) |> Enum.take(n)
    s = %{s | backoff: Map.drop(s.backoff, waiting)}

    s.ids
    |> Map.keys()
    |> Enum.sort(:desc)
    |> Enum.take(n - length(waiting))
    |> Enum.reduce(s, fn id, s ->
      pid = s.ids[id]
      send(pid, :stop)
      %{s | ids: Map.delete(s.ids, id), vus: Map.update!(s.vus, pid, &%{&1 | status: :stopping})}
    end)
  end

  defp start_vu(s, id, first) do
    spec = s.spec
    shard = elem(s.shards, rem(id, tuple_size(s.shards)))
    me = self()
    {pid, _ref} = spawn_monitor(fn -> Vu.run(spec, id, shard, me, first) end)
    status = if first, do: :busy, else: :connecting
    %{s | vus: Map.put(s.vus, pid, %{id: id, status: status}), ids: Map.put(s.ids, id, pid)}
  end

  defp connected(s, pid) do
    case s.vus do
      %{^pid => %{status: :connecting} = vu} ->
        s = %{s | fails: Map.delete(s.fails, vu.id)}

        # in the open model a new user was queued for work the moment it started
        if s.spec.load.model == :open,
          do: s,
          else: %{s | vus: Map.put(s.vus, pid, %{vu | status: :ready})}

      _ ->
        s
    end
  end

  defp down(s, pid, reason) do
    case Map.pop(s.vus, pid) do
      {nil, _} ->
        s

      {vu, vus} ->
        if reason != :normal do
          Metrics.count("vu.lost")
          Metrics.error("vu", reason)
        end

        ids = if s.ids[vu.id] == pid, do: Map.delete(s.ids, vu.id), else: s.ids

        # a user that ends early comes back after a pause that doubles each time, not in a tight loop
        if vu.status == :stopping do
          %{s | vus: vus, ids: ids}
        else
          tries = Map.get(s.fails, vu.id, 0) + 1
          wait = min(@backoff_ms * Integer.pow(2, tries - 1), @backoff_max_ms)

          %{
            s
            | vus: vus,
              ids: ids,
              fails: Map.put(s.fails, vu.id, tries),
              backoff: Map.put(s.backoff, vu.id, System.monotonic_time(:millisecond) + wait)
          }
        end
    end
  end

  # -- open: iterations start on the clock

  # users that are still connecting can already be given work; it waits in their mailbox
  defp preallocate(s),
    do: Enum.reduce(1..s.local_vus//1, s, fn _, s -> s |> start_open(nil) |> enqueue() end)

  defp start_open(s, first) do
    id = s.spec.index + 1 + s.next_id * s.spec.count
    start_vu(%{s | next_id: s.next_id + 1}, id, first)
  end

  defp enqueue(s) do
    {pid, _} = Enum.max_by(s.vus, fn {_pid, vu} -> vu.id end)
    idle(s, pid)
  end

  defp idle(s, pid) do
    case s.vus do
      %{^pid => vu} ->
        %{s | idle: :queue.in(pid, s.idle), vus: Map.put(s.vus, pid, %{vu | status: :idle})}

      _ ->
        s
    end
  end

  defp dispatch(%{next_at: nil} = s), do: s

  defp dispatch(s) do
    now = Metrics.now() - s.t0

    cond do
      s.next_at > now -> s
      s.next_at >= s.duration_us -> %{s | next_at: nil}
      true -> s |> assign(s.t0 + s.next_at) |> advance() |> dispatch()
    end
  end

  defp assign(s, intended) do
    case :queue.out(s.idle) do
      {{:value, pid}, q} ->
        case s.vus do
          %{^pid => %{status: :idle} = vu} ->
            send(pid, {:go, intended})
            %{s | idle: q, vus: Map.put(s.vus, pid, %{vu | status: :busy})}

          _ ->
            assign(%{s | idle: q}, intended)
        end

      {:empty, _} ->
        if map_size(s.vus) < s.local_max do
          start_open(s, intended)
        else
          Metrics.count("dropped")
          s
        end
    end
  end

  defp advance(s) do
    case Load.arrival(s.segments, s.k) do
      {:done, _} -> %{s | next_at: nil}
      {at, segs} -> %{s | next_at: at, segments: segs, k: s.k + s.spec.count}
    end
  end

  # -- the machine

  defp refill(%{tokens: :unlimited} = s), do: s

  defp refill(s) do
    now = Metrics.now()
    rate = s.spec.load.spawn_rate / s.spec.count
    tokens = min(s.tokens + rate * (now - s.tokens_at) / 1_000_000, max(rate, 1.0))
    %{s | tokens: tokens, tokens_at: now}
  end

  defp spawn_burst(%{spawn_rate: nil}), do: :unlimited
  defp spawn_burst(%{spawn_rate: _}), do: 1.0

  defp gauge(s) do
    Process.send_after(self(), :gauge, 1_000)
    sample = :scheduler.sample()

    cpu =
      case :scheduler.utilization(s.sample, sample) |> List.keyfind(:total, 0) do
        {:total, u, _} -> u
        _ -> 0.0
      end

    up = Enum.count(s.vus, fn {_pid, vu} -> vu.status not in [:connecting, :stopping] end)
    connecting = Enum.count(s.vus, fn {_pid, vu} -> vu.status == :connecting end)

    Collector.gauge(s.spec.root, node(), %{
      "vus" => up,
      "connecting" => connecting,
      "cpu" => cpu,
      "run_queue" => :erlang.statistics(:total_run_queue_lengths)
    })

    %{s | sample: sample}
  end

  defp shutdown(s) do
    Enum.each(s.vus, fn {pid, _} -> send(pid, :stop) end)
    deadline = System.monotonic_time(:millisecond) + s.spec.load.grace_ms
    s = await_users(s, deadline)

    Enum.each(s.vus, fn {pid, _} ->
      Metrics.count("vu.killed")
      Process.exit(pid, :kill)
    end)

    _ = await_users(s, System.monotonic_time(:millisecond) + 1_000, :killed)

    shards = Tuple.to_list(s.shards)
    Shard.record_sync(hd(shards), Metrics.take())
    Enum.each(shards, &Shard.drain/1)
    Enum.each(shards, &GenServer.stop/1)
    send(s.spec.coordinator, {:generator_done, self()})
  end

  defp await_users(s, deadline, mode \\ :graceful)

  defp await_users(%{vus: vus} = s, _deadline, _mode) when map_size(vus) == 0, do: s

  defp await_users(s, deadline, mode) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, _ref, :process, pid, reason} ->
        s =
          if mode == :killed,
            do: %{s | vus: Map.delete(s.vus, pid)},
            else: down(s, pid, reason)

        await_users(s, deadline, mode)

      {:connected, pid} ->
        send(pid, :stop)
        await_users(s, deadline, mode)
    after
      wait -> s
    end
  end

  # how many of the first `total` users (or units) machine `index` of `count` runs
  def share(total, index, count) when total > index, do: div(total - index - 1, count) + 1
  def share(_total, _index, _count), do: 0
end
