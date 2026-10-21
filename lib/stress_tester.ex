defmodule StressTester do
  @moduledoc "Runs many workers against one profile and prints a report."

  def run(opts \\ []) do
    opts = normalize(opts)
    report = StressTester.Suite.run(opts.profile, opts)
    IO.puts(StressTester.Report.format(report))
    report
  end

  defp normalize(opts) do
    given = Map.new(opts)
    workers = given[:workers] || given[:players] || 100

    %{
      host: "127.0.0.1",
      port: 4001,
      seconds: 5,
      hz: 10,
      chat_ms: 2_000,
      stagger_ms: 60,
      profile: StressTester.Reach
    }
    |> Map.merge(given)
    |> Map.put(:workers, workers)
    |> Map.put(:players, workers)
  end
end
