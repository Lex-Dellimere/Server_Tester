defmodule StressTester.Vu do
  @moduledoc """
  One virtual user. It connects, iterates until it is told to stop, then
  disconnects; the target does the talking. Iterations are paced (one every
  `pace`, catching up when late, and the lateness is recorded as `vu.lag`),
  spaced (`think` after each), back to back, or started by the generator at a
  fixed rate.

  Messages that arrive between iterations (an active socket, a server push) go
  to the target's `handle_message/2` before the next iteration runs, so a busy
  socket cannot starve the clock and a busy clock cannot starve the socket.

  A crash in target code ends this user, not the run: it is recorded as an
  error with the line it came from.
  """

  alias StressTester.Metrics
  alias StressTester.Collector.Shard

  @flush_us 1_000_000

  def run(spec, id, shard, gen, first) do
    Process.put(:stress_vu, id)
    Metrics.count("vu.started")
    t0 = Metrics.now()

    case guard(fn -> spec.target.connect(spec.shared, id) end) do
      {:ok, state} ->
        Metrics.since("vu.connect", t0)
        Metrics.count("vu.connected")
        send(gen, {:connected, self()})
        now = Metrics.now()

        l = %{
          target: spec.target,
          state: state,
          gen: gen,
          shard: shard,
          open: spec.load.model == :open,
          pace: us(spec.load.pace_ms),
          think: us(spec.load.think_ms),
          handles: function_exported?(spec.target, :handle_message, 2),
          next_at: now,
          flushed: now,
          stop: nil
        }

        l = if first, do: go(l, first), else: l
        loop(l)

      {:error, reason} ->
        connect_failed(reason, shard)

      {:crash, reason} ->
        connect_failed(reason, shard)

      other ->
        connect_failed({:bad_return, other}, shard)
    end
  end

  defp connect_failed(reason, shard) do
    Metrics.count("vu.connect_failed")
    Metrics.error("connect", reason)
    Shard.record_sync(shard, Metrics.take())
  end

  defp loop(l) do
    l = l |> drain(64) |> flush()

    cond do
      l.stop -> stop(l)
      l.open -> wait_go(l)
      true -> paced(l)
    end
  end

  defp paced(l) do
    now = Metrics.now()

    if l.next_at <= now do
      l |> iteration(l.next_at, l.pace != nil) |> loop()
    else
      wait = min(div(l.next_at - now + 999, 1_000), 1_000)

      receive do
        :stop -> loop(%{l | stop: :normal})
        msg -> l |> message(msg) |> loop()
      after
        wait -> loop(l)
      end
    end
  end

  defp wait_go(l) do
    receive do
      {:go, intended} -> l |> go(intended) |> loop()
      :stop -> loop(%{l | stop: :normal})
      msg -> l |> message(msg) |> loop()
    after
      1_000 -> loop(l)
    end
  end

  defp go(l, intended) do
    l = iteration(l, intended, true)
    send(l.gen, {:idle, self()})
    l
  end

  # what already waits in the mailbox, without blocking
  defp drain(l, 0), do: l

  defp drain(l, n) do
    receive do
      :stop -> %{l | stop: :normal}
      msg -> l |> message(msg) |> drain(n - 1)
    after
      0 -> l
    end
  end

  defp iteration(%{stop: stop} = l, _scheduled, _late?) when stop != nil, do: l

  defp iteration(l, scheduled, late?) do
    started = Metrics.now()
    if late?, do: Metrics.observe("vu.lag", started - scheduled)

    {state, stop} =
      case guard(fn -> l.target.iterate(l.state) end) do
        {:ok, state} ->
          {state, nil}

        {:error, reason, state} ->
          Metrics.count("iterations.failed")
          Metrics.error("iteration", reason)
          {state, nil}

        {:stop, reason, state} ->
          {state, reason}

        {:crash, reason} ->
          Metrics.count("iterations.failed")
          {l.state, {:crash, reason}}

        other ->
          {l.state, {:bad_return, other}}
      end

    done = Metrics.now()
    Metrics.count("iterations")
    Metrics.observe("iteration", done - if(l.open, do: scheduled, else: started))

    next =
      cond do
        l.open -> done
        l.pace && done - (scheduled + l.pace) > l.pace -> done
        l.pace -> scheduled + l.pace
        l.think -> done + l.think
        true -> done
      end

    %{l | state: state, stop: stop, next_at: next}
  end

  defp message(l, msg) do
    cond do
      l.stop != nil or not l.handles ->
        l

      true ->
        case guard(fn -> l.target.handle_message(msg, l.state) end) do
          {:ok, state} -> %{l | state: state}
          {:stop, reason, state} -> %{l | state: state, stop: reason}
          {:crash, reason} -> %{l | stop: {:crash, reason}}
          other -> %{l | stop: {:bad_return, other}}
        end
    end
  end

  defp flush(l) do
    now = Metrics.now()

    if now - l.flushed >= @flush_us do
      Shard.record(l.shard, Metrics.take())
      %{l | flushed: now}
    else
      l
    end
  end

  defp stop(l) do
    _ = guard(fn -> l.target.disconnect(l.state) end)

    if l.stop not in [:normal, :done] do
      Metrics.count("vu.lost")
      Metrics.error("vu", l.stop)
    end

    Shard.record_sync(l.shard, Metrics.take())
  end

  defp guard(fun) do
    fun.()
  rescue
    e -> {:crash, Exception.message(e) <> at(__STACKTRACE__)}
  catch
    :exit, reason -> {:crash, {:exit, reason}}
    :throw, value -> {:crash, {:throw, value}}
  end

  defp at([entry | _]), do: " (" <> Exception.format_stacktrace_entry(entry) <> ")"
  defp at(_), do: ""

  defp us(nil), do: nil
  defp us(ms), do: ms * 1_000
end
