defmodule StressTester.MixProject do
  use Mix.Project

  def project do
    [
      app: :stress_tester,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # what is left uncovered is mostly the long-running agent loop, the escript entry point,
      # and the error branches of sockets that are hard to break on purpose
      test_coverage: [summary: [threshold: 85], ignore_modules: [~r/^StressTester\.Test\./]],
      escript: [main_module: StressTester.CLI, name: "stress", emu_args: "+Q 1048576"],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :public_key, :runtime_tools],
      mod: {StressTester.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The tester itself has no dependencies. The Reach server is here only so the
  # tests can boot it; REACH_BACKEND points at another checkout of it.
  defp deps do
    [
      {:the_reach_backend,
       path: System.get_env("REACH_BACKEND", "../the_reach_backend"), only: :test}
    ]
  end
end
