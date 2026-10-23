defmodule StressTester.Agent do
  @moduledoc """
  One machine cannot always make enough load, and the numbers are worse when
  the tester shares a machine with the server. Start an agent on each extra
  machine:

      stress agent --self agent1@10.0.0.6 --cookie s3cret

  then run from any machine with `--agents agent1@10.0.0.6 --cookie s3cret`.
  Users are split evenly (add `--no-local` to keep them all on the agents); the
  numbers come back to the machine that started the run.

  Every machine must run the same build of the tester; the run checks this
  before it starts. Erlang distribution is not encrypted: keep agents on a
  private network, and use a long random cookie.
  """

  def serve(opts) do
    name =
      opts[:self] ||
        raise "an agent needs --self NAME@HOST (an address the other machines can reach)"

    with :ok <- start_node(name, opts[:cookie]) do
      IO.puts("agent #{node()} is ready; run with --agents #{node()}")
      Process.sleep(:infinity)
    end
  end

  def nodes(%{agents: []}), do: {:ok, [node()]}

  def nodes(plan) do
    with :ok <- alive(plan),
         {:ok, agents} <- reach_all(plan.agents) do
      nodes = if plan.local, do: [node() | agents], else: agents
      if nodes == [], do: {:error, "no machine left to run users on"}, else: {:ok, nodes}
    end
  end

  defp alive(plan) do
    if Node.alive?() do
      if plan.cookie, do: Node.set_cookie(String.to_atom(plan.cookie))
      :ok
    else
      start_node(
        plan.self || "stress-#{System.unique_integer([:positive])}@#{local_ip()}",
        plan.cookie
      )
    end
  end

  defp reach_all(agents) do
    mine = fingerprint()

    Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, acc} ->
      cond do
        not Node.connect(agent) ->
          {:halt,
           {:error, "cannot reach agent #{agent} (is it running, with the same --cookie?)"}}

        :erpc.call(agent, __MODULE__, :fingerprint, []) != mine ->
          {:halt, {:error, "agent #{agent} runs a different build of the tester"}}

        true ->
          {:cont, {:ok, acc ++ [agent]}}
      end
    end)
  end

  # the beam files as shipped, not the loaded code: a coverage run or a hot patch
  # changes what is in memory, and neither is a different build
  def fingerprint do
    :ok = :application.load(:stress_tester) |> ignore_loaded()
    {:ok, modules} = :application.get_key(:stress_tester, :modules)

    modules
    |> Enum.sort()
    |> Enum.map(fn module ->
      case :code.get_object_code(module) do
        {^module, binary, _file} -> :erlang.md5(binary)
        :error -> :missing
      end
    end)
    |> :erlang.md5()
  end

  defp ignore_loaded(:ok), do: :ok
  defp ignore_loaded({:error, {:already_loaded, _}}), do: :ok

  def start_node(name, cookie) do
    # the name server must run before a node can have a name
    _ =
      try do
        System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
      rescue
        _ -> :no_epmd
      end

    result =
      case Node.start(String.to_atom(name), :longnames) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> {:error, "cannot start node #{name}: #{inspect(reason)}"}
      end

    if result == :ok and cookie, do: Node.set_cookie(String.to_atom(cookie))
    result
  end

  defp local_ip do
    {:ok, ifs} = :inet.getifaddrs()

    ifs
    |> Enum.flat_map(fn {_name, opts} -> Keyword.get_values(opts, :addr) end)
    |> Enum.find({127, 0, 0, 1}, &match?({a, _, _, _} when a != 127, &1))
    |> :inet.ntoa()
    |> to_string()
  end
end
