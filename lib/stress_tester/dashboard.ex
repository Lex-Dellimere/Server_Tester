defmodule StressTester.Dashboard do
  @moduledoc """
  A page in your browser for running load tests and watching them live: pick a
  test, set the players, press Run, and the numbers and charts move every second.
  Past runs open as full reports.

      iex -S mix, then dashboard()          http://127.0.0.1:4100
      stress dashboard --port 4100 --address 10.0.0.5:4001

  It listens on 127.0.0.1 only.
  """

  alias StressTester.Dashboard.{Control, Server}

  def start(opts \\ []) do
    opts = Keyword.merge([port: 4100, address: "127.0.0.1:4001"], opts)

    children = [{Control, address: opts[:address]}, {Server, port: opts[:port]}]

    case Supervisor.start_link(children, strategy: :one_for_all, name: __MODULE__) do
      {:ok, pid} ->
        # an error typed in the shell must not take the dashboard down with it
        Process.unlink(pid)
        {:ok, pid, url()}

      {:error, {:already_started, pid}} ->
        {:ok, pid, url()}

      {:error, {:shutdown, {:failed_to_start_child, Server, :eaddrinuse}}} ->
        {:error, "port #{opts[:port]} is in use (try port: 4101)"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  def url, do: "http://127.0.0.1:#{Server.port()}"
end
