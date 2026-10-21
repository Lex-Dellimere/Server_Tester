defmodule StressTester.Report do
  @moduledoc "Turns worker totals into one readable run."

  def build(opts, rows, checks, expect) do
    wanted = expect.(rows)

    %{
      workers: opts.workers,
      joined: length(rows),
      seconds: opts.seconds,
      hz: opts.hz,
      connect: timing(Enum.map(rows, & &1.connect_us)),
      join: timing(Enum.map(rows, & &1.join_us)),
      kinds: kinds(rows, wanted),
      auth_rejected: checks.auth_rejected,
      reconnect: checks.reconnect,
      ok: false
    }
  end

  def format(report) do
    kinds =
      report.kinds
      |> Enum.sort_by(fn {kind, _row} -> kind end)
      |> Enum.map_join("\n", fn {kind, row} ->
        "#{kind} sent #{row.sent} expected #{row.expected} received #{row.received} loss #{percent(row.loss)} p50 #{ms(row.p50)} p99 #{ms(row.p99)}"
      end)

    """
    workers #{report.joined}/#{report.workers}
    seconds #{report.seconds} hz #{report.hz}
    connect #{timing_text(report.connect)}
    join #{timing_text(report.join)}
    #{kinds}
    auth_rejected #{report.auth_rejected}
    reconnect #{report.reconnect}
    ok #{report.ok}
    """
  end

  def percentile([], _rank), do: nil

  def percentile(values, rank) do
    sorted = Enum.sort(values)
    index = min(length(sorted) - 1, max(0, ceil(rank / 100 * length(sorted)) - 1))
    Enum.at(sorted, index)
  end

  defp kinds(rows, wanted) do
    keys =
      (Map.keys(wanted) ++
         Enum.flat_map(rows, fn row -> Map.keys(row.sent) ++ Map.keys(row.got) end))
      |> Enum.uniq()
      |> Enum.sort()

    Map.new(keys, fn kind ->
      sent = sum(rows, fn row -> row.sent[kind] || 0 end)
      got = sum(rows, fn row -> row.got[kind] || 0 end)
      lats = Enum.flat_map(rows, fn row -> Map.get(row, :lats, %{})[kind] || [] end)
      expected = Map.get(wanted, kind, 0)
      loss = if expected == 0, do: 0.0, else: max(expected - got, 0) / expected

      {kind,
       %{
         sent: sent,
         received: got,
         expected: expected,
         loss: loss,
         p50: percentile(lats, 50),
         p99: percentile(lats, 99)
       }}
    end)
  end

  defp timing(values), do: %{p50: percentile(values, 50), p99: percentile(values, 99)}

  defp timing_text(timing), do: "p50 #{ms(timing.p50)} p99 #{ms(timing.p99)}"

  defp sum(rows, fun), do: Enum.reduce(rows, 0, fn row, acc -> acc + fun.(row) end)

  defp ms(nil), do: "n/a"
  defp ms(us), do: :erlang.float_to_binary(us / 1_000, decimals: 2) <> "ms"

  defp percent(loss), do: :erlang.float_to_binary(loss * 100, decimals: 2) <> "%"
end
