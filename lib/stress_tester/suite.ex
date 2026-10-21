defmodule StressTester.Suite do
  @moduledoc "Starts workers, waits until they are up, then runs them for the same span."

  def run(profile, opts) do
    opts = profile.prepare(opts)
    auth_rejected = check(fn -> profile.auth_rejected?(opts) end)
    reconnect = check(fn -> profile.reconnect?(opts) end)
    rows = launch(profile, opts)

    report =
      StressTester.Report.build(
        opts,
        rows,
        %{
          auth_rejected: auth_rejected,
          reconnect: reconnect
        },
        &profile.expect/1
      )

    %{report | ok: profile.ok?(report)}
  end

  defp launch(profile, opts) do
    ids = profile.plan(opts)
    parent = self()

    tasks =
      Enum.with_index(ids, fn id, index ->
        Task.async(fn ->
          Process.sleep(index * opts.stagger_ms)
          session = profile.open(opts, id)
          send(parent, {:up, self()})

          receive do
            :play -> :ok
          after
            60_000 -> raise "timed out waiting to start"
          end

          totals = profile.drive(session, opts)
          profile.close(session)
          totals
        end)
      end)

    wait_notes(length(ids), :up)
    Enum.each(tasks, &send(&1.pid, :play))
    Task.await_many(tasks, opts.seconds * 1_000 + 30_000)
  end

  defp wait_notes(0, _tag), do: :ok

  defp wait_notes(left, tag) do
    receive do
      {^tag, _pid} -> wait_notes(left - 1, tag)
    after
      60_000 -> raise "timed out waiting for workers"
    end
  end

  defp check(fun) do
    fun.()
  rescue
    _ -> false
  end
end
