defmodule StressTester do
  @moduledoc """
  Load for anything with a socket: websites and APIs (HTTP/1.1 and HTTPS),
  WebSocket services, plain TCP and UDP, and the Reach game server. A run is a
  target (what to talk to, and how), a load (how many users or how many
  iterations a second, for how long), and thresholds (what counts as passing).

      StressTester.run(target: "http", url: "http://127.0.0.1:4001/v1/meta", rate: 200, duration: "10s")
      StressTester.run(target: "reach", vus: 100, duration: "1m")
      StressTester.run_file("scenarios/reach-api.json", vus: 50)

  Both return `{:ok, report}`; `report.ok` says whether every check and
  threshold held. Pass `silent: true` to print nothing, `quiet: true` to skip
  the line a second.
  """

  alias StressTester.{Plan, Runner}

  def run(opts) do
    with {:ok, plan} <- Plan.build(opts), do: Runner.run(plan)
  end

  def run_file(path, overrides \\ []) do
    with {:ok, plan} <- Plan.from_file(path, Map.new(overrides)), do: Runner.run(plan)
  end
end
