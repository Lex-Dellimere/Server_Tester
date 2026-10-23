defmodule StressTester.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([StressTester.History],
      strategy: :one_for_one,
      name: StressTester.Supervisor
    )
  end
end
