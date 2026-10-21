defmodule Mix.Tasks.Stress do
  use Mix.Task

  @shortdoc "Run workers against a Reach server or any TCP port"

  @moduledoc """
  The default profile talks to the Reach server. Start that server first
  with `iex -S mix` in `the_reach_backend`. Dev has stress logins on.

      mix stress
      mix stress --players 20 --seconds 5 --hz 10 --port 4001

  `mix stress --profile tcp --port 9000` writes a line to any TCP service.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          host: :string,
          port: :integer,
          players: :integer,
          workers: :integer,
          seconds: :integer,
          hz: :integer,
          chat_ms: :integer,
          planet: :string,
          profile: :string,
          stagger_ms: :integer,
          payload: :string
        ]
      )

    report = StressTester.run(Map.put(Map.new(opts), :profile, profile(opts[:profile])))
    if report.ok, do: :ok, else: Mix.raise("stress run failed")
  end

  defp profile(nil), do: StressTester.Reach
  defp profile("reach"), do: StressTester.Reach
  defp profile("tcp"), do: StressTester.Tcp
  defp profile(other), do: Mix.raise("unknown profile #{other}")
end
