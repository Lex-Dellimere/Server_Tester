defmodule StressTester.Load do
  @moduledoc """
  The shape of a run over time.

  **Closed** (`--vus`): a number of users, each doing iterations one after
  another. Slow answers slow the users down, the way real players wait for the
  server.

  **Open** (`--rate`): iterations start at a fixed rate whatever the server
  does, like traffic arriving at a website. Latency is measured from when each
  iteration *should* have started, so a stalled server cannot hide by making
  the tester wait (no coordinated omission). When every user is busy and the
  pool is full, the iteration is counted as `dropped`.

  Stages ramp in straight lines: `30s:100,2m:100,30s:0` climbs to 100 users in
  30 seconds, holds for two minutes, and winds down. `30s:200/s` is a rate.
  """

  alias StressTester.Units

  defstruct model: :closed,
            start: 0,
            stages: [],
            vus: nil,
            max_vus: nil,
            pace_ms: nil,
            think_ms: nil,
            spawn_rate: nil,
            grace_ms: 10_000

  def build(opts, defaults \\ %{}) do
    with {:ok, pace} <- Units.ms(get(opts, :pace) || defaults[:pace], :ms),
         {:ok, think} <- Units.ms(get(opts, :think), :ms),
         {:ok, grace} <- Units.ms(get(opts, :grace) || "10s", :s),
         {:ok, model, start, stages} <- shape(opts, defaults),
         :ok <- positive(stages) do
      peak = Enum.reduce(stages, start, fn {_d, v}, acc -> max(v, acc) end)

      load = %__MODULE__{
        model: model,
        start: start,
        stages: stages,
        pace_ms: if(think, do: nil, else: pace),
        think_ms: think,
        spawn_rate: get(opts, :spawn_rate),
        grace_ms: grace
      }

      {:ok, sizes(load, opts, peak)}
    end
  end

  defp shape(opts, defaults) do
    cond do
      get(opts, :stages) ->
        stages(get(opts, :stages))

      rate = get(opts, :rate) ->
        constant(:open, rate * 1.0, opts, defaults)

      true ->
        constant(:closed, get(opts, :vus) || defaults[:vus] || 10, opts, defaults)
    end
  end

  defp constant(model, value, opts, defaults) do
    with {:ok, hold} <- hold(opts, defaults),
         {:ok, ramp} <- Units.ms(get(opts, :ramp), :s) do
      if ramp && ramp > 0,
        do: {:ok, model, 0, [{ramp, value}, {hold, value}]},
        else: {:ok, model, value, [{hold, value}]}
    end
  end

  defp hold(opts, defaults) do
    cond do
      d = get(opts, :duration) -> Units.ms(d, :s)
      s = get(opts, :seconds) -> Units.ms(s, :s)
      true -> Units.ms(defaults[:duration] || "10s", :s)
    end
  end

  # "30s:100,1m:100/s" or [%{"duration" => "30s", "vus" => 100}, ...]
  def stages(text) when is_binary(text), do: text |> String.split(",", trim: true) |> stages()

  def stages(list) when is_list(list) do
    parsed = Enum.map(list, &stage/1)

    case Enum.find(parsed, &match?({:error, _}, &1)) do
      {:error, _} = error ->
        error

      nil ->
        kinds = parsed |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        case kinds do
          [kind] -> {:ok, kind, 0, Enum.map(parsed, fn {:ok, _kind, stage} -> stage end)}
          _ -> {:error, "stages mix users and rates; use one or the other"}
        end
    end
  end

  def stages(other), do: {:error, "#{inspect(other)} is not a list of stages"}

  defp stage(%{} = map) do
    map = Map.new(map, fn {k, v} -> {to_string(k), v} end)

    cond do
      map["rate"] -> stage("#{map["duration"]}:#{map["rate"]}/s")
      map["vus"] -> stage("#{map["duration"]}:#{map["vus"]}")
      true -> {:error, "stage #{inspect(map)} needs vus or rate"}
    end
  end

  defp stage(text) when is_binary(text) do
    with [d, v] <- String.split(String.trim(text), ":", parts: 2),
         {:ok, ms} <- Units.ms(d, :s),
         {kind, v} =
           if(String.ends_with?(v, "/s"),
             do: {:open, String.trim_trailing(v, "/s")},
             else: {:closed, v}
           ),
         {n, ""} <- Float.parse(String.trim(v)) do
      {:ok, kind, {ms, if(kind == :closed, do: round(n), else: n)}}
    else
      {:error, _} = error -> error
      _ -> {:error, "#{inspect(text)} is not a stage (try 30s:100 or 30s:200/s)"}
    end
  end

  defp positive(stages) do
    cond do
      stages == [] ->
        {:error, "the run has no stages"}

      Enum.any?(stages, fn {d, v} -> d < 0 or v < 0 end) ->
        {:error, "stages must not be negative"}

      duration_of(stages) <= 0 ->
        {:error, "the run must last longer than 0s"}

      true ->
        :ok
    end
  end

  # how many users exist at once
  defp sizes(%{model: :closed} = load, _opts, peak) do
    %{load | vus: round(peak), max_vus: round(peak)}
  end

  defp sizes(%{model: :open} = load, opts, peak) do
    vus = get(opts, :vus) || min(max(ceil(peak), 1), 100)

    %{
      load
      | vus: vus,
        max_vus: max(get(opts, :max_vus) || min(max(ceil(peak * 2), vus), 20_000), vus)
    }
  end

  def duration(%__MODULE__{stages: stages}), do: duration_of(stages)

  defp duration_of(stages), do: Enum.reduce(stages, 0, fn {d, _v}, acc -> acc + d end)

  # users (closed) or iterations per second (open) at t milliseconds
  def value_at(%__MODULE__{start: start, stages: stages}, t), do: walk(stages, start, 0, t)

  defp walk([], prev, _at, _t), do: prev

  defp walk([{d, v} | rest], prev, at, t) do
    if t < at + d and d > 0, do: prev + (v - prev) * (t - at) / d, else: walk(rest, v, at + d, t)
  end

  @doc """
  Arrival times for the open model. `segments/1` turns the stages into pieces
  with a known area (iterations so far); `arrival/2` gives the time, in
  microseconds from the start, of the k-th iteration (from 1), or `:done`.
  The first iteration starts at 0.
  """
  def segments(%__MODULE__{start: start, stages: stages}) do
    {segs, _t, _r, _area} =
      Enum.reduce(stages, {[], 0.0, start * 1.0, 0.0}, fn {d, v}, {acc, t, r0, area} ->
        secs = d / 1_000
        r1 = v * 1.0
        piece = (r0 + r1) / 2 * secs
        {[{t, secs, r0, r1, area, area + piece} | acc], t + secs, r1, area + piece}
      end)

    Enum.reverse(segs)
  end

  def arrival([], _k), do: {:done, []}

  def arrival([{t0, d, r0, r1, a0, a1} | rest] = segs, k) do
    target = k - 1

    if target >= a1 do
      arrival(rest, k)
    else
      a = target - a0
      tau = solve(a, d, r0, r1)
      {round((t0 + tau) * 1_000_000), segs}
    end
  end

  # r0·τ + (r1 − r0)·τ²/(2d) = a
  defp solve(a, d, r0, r1) do
    cond do
      a <= 0 ->
        0.0

      abs(r1 - r0) < 1.0e-9 ->
        a / r0

      true ->
        c = (r1 - r0) / (2 * d)
        disc = max(r0 * r0 + 4 * c * a, 0.0)
        min((-r0 + :math.sqrt(disc)) / (2 * c), d)
    end
  end

  def describe(%__MODULE__{} = load) do
    total = Units.time(duration(load) * 1_000)

    shape =
      case {load.model, load.stages} do
        {:closed, [{_, v}]} ->
          "#{v} users for #{total}"

        {:open, [{_, v}]} ->
          "#{fmt_rate(v)} iterations/s for #{total} (#{load.vus}-#{load.max_vus} users)"

        {model, stages} ->
          "#{if model == :open, do: "rate", else: "users"} #{stages_text(load.start, stages, model)} (#{total})"
      end

    pacing =
      cond do
        load.pace_ms -> ", one iteration every #{Units.time(load.pace_ms * 1_000)} each"
        load.think_ms -> ", #{Units.time(load.think_ms * 1_000)} pause after each iteration"
        true -> ""
      end

    shape <> pacing
  end

  defp stages_text(start, stages, model) do
    unit = if model == :open, do: "/s", else: ""

    "#{fmt_rate(start)}#{unit}" <>
      Enum.map_join(stages, "", fn {d, v} ->
        " → #{fmt_rate(v)}#{unit} in #{Units.time(d * 1_000)}"
      end)
  end

  defp fmt_rate(v) when is_float(v) and v == trunc(v), do: Integer.to_string(trunc(v))
  defp fmt_rate(v) when is_float(v), do: Units.fixed(v, 1)
  defp fmt_rate(v), do: to_string(v)

  defp get(opts, key), do: Map.get(opts, key)
end
