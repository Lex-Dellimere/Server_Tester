defmodule StressTester.Target do
  @moduledoc """
  What a target is. The runner knows nothing about protocols: a target turns
  "this user, one iteration" into bytes on a wire, and records what happened
  with `StressTester.Metrics`.

  The life of one user, all in one process:

      connect(shared, vu)        log in, open sockets; {:ok, state} or {:error, why}
      iterate(state)             one unit of work; {:ok, state}, {:error, why, state},
                                 or {:stop, why, state} to end this user
      handle_message(msg, state) anything that arrives between iterations
                                 (active sockets, timers)
      disconnect(state)          leave cleanly

  `init/1` runs once, before any user, on the machine that starts the run; what
  it returns is copied to every user, so it must be plain data (no pids or open
  sockets). `checks/2` are one-off correctness tests run before the load.

  A new target is a module with these callbacks; pass it as `target: MyTarget`
  or `--target Elixir.MyTarget`.
  """

  @type shared :: term
  @type state :: term

  @doc "Command-line switches this target adds, as OptionParser types."
  @callback options() :: keyword

  @doc "Load and threshold defaults: `%{vus:, pace:, duration:, thresholds:, live:}`."
  @callback defaults(opts :: map) :: map

  @callback init(opts :: map) :: {:ok, shared} | {:error, term}
  @callback describe(shared) :: String.t()
  @callback checks(shared, which :: :default | :all | [String.t()]) :: [
              {String.t(), (-> :ok | {:error, term})}
            ]
  @callback connect(shared, vu :: pos_integer) :: {:ok, state} | {:error, term}
  @callback iterate(state) :: {:ok, state} | {:error, term, state} | {:stop, term, state}
  @callback handle_message(message :: term, state) :: {:ok, state} | {:stop, term, state}
  @callback disconnect(state) :: term

  @doc "Numbers worked out from the run's totals, shown in the report and usable in thresholds."
  @callback derive(counters :: map, shared) :: %{String.t() => number}

  @doc "Where the server publishes its own metrics: `%{url:, headers:, insecure:}`, or nil."
  @callback scrape(shared) :: map | nil

  @optional_callbacks options: 0,
                      scrape: 1,
                      defaults: 1,
                      describe: 1,
                      checks: 2,
                      handle_message: 2,
                      derive: 2

  @builtin %{
    "http" => StressTester.Targets.Http,
    "https" => StressTester.Targets.Http,
    "ws" => StressTester.Targets.WebSocket,
    "wss" => StressTester.Targets.WebSocket,
    "websocket" => StressTester.Targets.WebSocket,
    "reach" => StressTester.Reach
  }

  def builtin, do: @builtin

  def resolve(nil), do: resolve("reach")
  def resolve(module) when is_atom(module), do: loaded(module)

  def resolve(name) when is_binary(name) do
    case Map.fetch(@builtin, String.downcase(name)) do
      {:ok, module} ->
        loaded(module)

      :error ->
        module =
          if String.starts_with?(name, "Elixir."),
            do: String.to_atom(name),
            else: Module.concat([name])

        case loaded(module) do
          {:ok, _} = ok ->
            ok

          _ ->
            {:error,
             "unknown target #{inspect(name)}; try #{@builtin |> Map.keys() |> Enum.join(", ")}"}
        end
    end
  end

  defp loaded(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :iterate, 1),
      do: {:ok, module},
      else: {:error, "#{inspect(module)} is not a target"}
  end

  def options(t), do: if(function_exported?(t, :options, 0), do: t.options(), else: [])

  def defaults(t, opts),
    do: if(function_exported?(t, :defaults, 1), do: t.defaults(opts), else: %{})

  def describe(t, shared),
    do: if(function_exported?(t, :describe, 1), do: t.describe(shared), else: inspect(t))

  def checks(t, shared, which),
    do: if(function_exported?(t, :checks, 2), do: t.checks(shared, which), else: [])

  def scrape(t, shared),
    do: if(function_exported?(t, :scrape, 1), do: t.scrape(shared), else: nil)

  def derive(t, counters, shared),
    do: if(function_exported?(t, :derive, 2), do: t.derive(counters, shared), else: %{})
end
