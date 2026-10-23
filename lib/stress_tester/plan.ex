defmodule StressTester.Plan do
  @moduledoc """
  Options from the command line, a scenario file, or Elixir, checked and turned
  into one run. Unknown keys in a scenario file are an error, so a typo does
  not silently run the wrong test.
  """

  alias StressTester.{Load, Target, Threshold}

  defstruct [
    :target,
    :options,
    :load,
    :out,
    :cookie,
    :self,
    :shards,
    thresholds: [],
    checks: :default,
    live: true,
    print: true,
    agents: [],
    local: true,
    watch: []
  ]

  @common [
    target: :string,
    vus: :integer,
    max_vus: :integer,
    rate: :float,
    duration: :string,
    seconds: :integer,
    ramp: :string,
    stages: :string,
    pace: :string,
    think: :string,
    spawn_rate: :float,
    grace: :string,
    threshold: :keep,
    checks: :string,
    scrape: :string,
    scrape_header: :keep,
    out: :string,
    quiet: :boolean,
    agents: :string,
    cookie: :string,
    self: :string,
    local: :boolean,
    shards: :integer
  ]

  # keys a scenario file may hold that are not command-line switches
  @structured [:thresholds, :steps, :setup, :headers, :json, :expect, :capture, :body, :silent]

  def switches(target), do: @common ++ Target.options(target)

  def build(opts) do
    opts = Map.new(opts)

    with {:ok, target} <- Target.resolve(opts[:target]),
         defaults = Target.defaults(target, opts),
         {:ok, load} <- Load.build(opts, defaults),
         {:ok, thresholds} <- thresholds(opts, defaults),
         {:ok, checks} <- checks(opts[:checks]),
         {:ok, agents} <- agents(opts[:agents]) do
      {:ok,
       %__MODULE__{
         target: target,
         options: opts,
         load: load,
         thresholds: thresholds,
         checks: checks,
         live: opts[:quiet] != true and opts[:silent] != true,
         print: opts[:silent] != true,
         out: opts[:out],
         agents: agents,
         local: Map.get(opts, :local, true),
         cookie: opts[:cookie],
         self: opts[:self],
         shards: opts[:shards],
         watch: defaults[:live] || []
       }}
    end
  end

  def from_file(path, overrides \\ %{}) do
    with {:ok, text} <- read(path),
         {:ok, json} <- decode(path, text),
         {:ok, target} <- Target.resolve(Map.get(Map.new(overrides), :target) || json["target"]),
         {:ok, opts} <- keys(json, target) do
      opts
      |> Map.merge(Map.new(overrides))
      |> Map.put(:target, target)
      |> build()
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(path, text) do
    case JSON.decode(text) do
      {:ok, %{} = json} -> {:ok, json}
      {:ok, _} -> {:error, "#{path} must hold a JSON object"}
      {:error, reason} -> {:error, "#{path} is not JSON: #{inspect(reason)}"}
    end
  end

  defp keys(json, target) do
    allowed = Keyword.keys(switches(target)) ++ @structured

    Enum.reduce_while(json, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      name = String.replace(k, "-", "_")

      case Enum.find(allowed, &(Atom.to_string(&1) == name)) do
        nil -> {:halt, {:error, "unknown key #{inspect(k)} in the scenario"}}
        key -> {:cont, {:ok, Map.put(acc, key, v)}}
      end
    end)
  end

  defp thresholds(opts, defaults) do
    given = List.wrap(opts[:threshold]) ++ List.wrap(opts[:thresholds])

    cond do
      given == ["none"] -> {:ok, []}
      given == [] -> Threshold.parse_all(defaults[:thresholds] || [])
      true -> Threshold.parse_all(given)
    end
  end

  defp checks(nil), do: {:ok, :default}
  defp checks(w) when w in [:default, :all, :none], do: {:ok, w}
  defp checks("default"), do: {:ok, :default}
  defp checks("all"), do: {:ok, :all}
  defp checks("none"), do: {:ok, :none}
  defp checks(text) when is_binary(text), do: {:ok, String.split(text, ",", trim: true)}
  defp checks(list) when is_list(list), do: {:ok, Enum.map(list, &to_string/1)}

  defp agents(nil), do: {:ok, []}
  defp agents(""), do: {:ok, []}
  defp agents(text) when is_binary(text), do: text |> String.split(",", trim: true) |> agents()

  defp agents(list) when is_list(list),
    do: {:ok, Enum.map(list, &String.to_atom(String.trim(to_string(&1))))}
end
