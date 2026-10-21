defmodule StressTester.MixProject do
  use Mix.Project

  def project do
    [
      app: :stress_tester,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {StressTester.Application, []}
    ]
  end

  defp deps do
    [
      {:the_reach_backend, path: "../the_reach_backend", only: :test}
    ]
  end
end
