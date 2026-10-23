defmodule Mix.Tasks.Stress do
  use Mix.Task

  @shortdoc "Load-test a website, API, socket service, or the Reach server"

  @moduledoc """
  Runs `StressTester.CLI`. With no arguments it plays the Reach server on
  127.0.0.1:4001 (start it with `iex -S mix` in the_reach_backend; dev has
  stress logins on).

      mix stress
      mix stress reach --vus 100 --duration 1m
      mix stress http http://127.0.0.1:4001/v1/meta --rate 500 --duration 30s
      mix stress help

  The exit status is 1 when a check or threshold fails, 2 when the run cannot start.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case StressTester.CLI.run(args) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
