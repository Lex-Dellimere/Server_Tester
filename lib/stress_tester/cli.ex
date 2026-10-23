defmodule StressTester.CLI do
  @moduledoc """
  The `stress` command: `mix stress …` in this project, or the standalone
  `./stress` that `mix escript.build` makes (it needs only Erlang installed, so
  it can run on other machines).

      stress http https://example.com/ --rate 100 --duration 30s
      stress ws ws://127.0.0.1:4001/socket --vus 500 --pace 1s --message '{"op":"ping"}'
      stress tcp 127.0.0.1:9000 --vus 20 --payload 'ping\\n'
      stress udp 127.0.0.1:9001 --vus 20 --payload ping
      stress reach 127.0.0.1:4001 --vus 100 --duration 1m
      stress scenarios/reach-api.json --vus 20
      stress agent --self agent1@10.0.0.6 --cookie s3cret
      stress help reach

  Exit status: 0 passed, 1 a check or threshold failed, 2 the run could not start.
  """

  alias StressTester.{Agent, Ladder, Plan, Target, Units}

  # an escript does not start its own application
  def main(argv) do
    {:ok, _} = Application.ensure_all_started(:stress_tester)
    System.halt(run(argv))
  end

  def run(argv) do
    case argv do
      [h] when h in ["help", "-h", "--help"] ->
        usage()

      ["help", name | _] ->
        target_help(name)

      ["agent" | rest] ->
        agent(rest)

      ["ladder" | rest] ->
        ladder(rest)

      ["dashboard" | rest] ->
        dashboard(rest)

      [] ->
        go(nil, [])

      ["-" <> _ | _] ->
        go(nil, argv)

      [first | rest] ->
        if String.ends_with?(first, ".json"), do: file(first, rest), else: go(first, rest)
    end
  end

  defp go(name, args) do
    name = name || target_flag(args)

    with {:ok, target} <- Target.resolve(name),
         {:ok, opts} <- parse(args, target) do
      opts |> Map.put(:target, target) |> StressTester.run() |> finish()
    else
      {:error, message} -> fail(message)
    end
  end

  defp file(path, args) do
    with {:ok, target} <- file_target(path),
         {:ok, opts} <- parse(args, target) do
      path |> StressTester.run_file(opts) |> finish()
    else
      {:error, message} -> fail(message)
    end
  end

  defp file_target(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = json} <- JSON.decode(text) do
      Target.resolve(json["target"])
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}

      _ ->
        {:error, "#{path} is not a JSON object"}
    end
  end

  defp target_flag(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [target: :string])
    opts[:target]
  end

  def parse(args, target, extra \\ []) do
    switches = Plan.switches(target) ++ extra

    case OptionParser.parse(args, strict: switches) do
      {opts, positional, []} ->
        keep = for {k, :keep} <- switches, do: k

        merged =
          Enum.reduce(keep, Map.new(opts), fn k, acc ->
            put_list(acc, k, Keyword.get_values(opts, k))
          end)

        merged =
          case positional do
            [address | _] -> Map.put_new(merged, :address, address)
            [] -> merged
          end

        {:ok, unescape(merged)}

      {_opts, _positional, invalid} ->
        {:error, "unknown or bad option: " <> Enum.map_join(invalid, ", ", fn {k, _} -> k end)}
    end
  end

  defp put_list(acc, _k, []), do: acc
  defp put_list(acc, k, values), do: Map.put(acc, k, values)

  defp unescape(opts) do
    Enum.reduce([:payload, :message, :body], opts, fn k, acc ->
      case acc do
        %{^k => v} when is_binary(v) -> Map.put(acc, k, Units.unescape(v))
        _ -> acc
      end
    end)
  end

  # the page with buttons and live charts; runs until stopped with Ctrl-C
  defp dashboard(args) do
    case OptionParser.parse(args, strict: [port: :integer, address: :string]) do
      {opts, [], []} ->
        case StressTester.Dashboard.start(opts) do
          {:ok, _pid, url} ->
            IO.puts("dashboard at #{url}  (Ctrl-C twice to stop)")
            Process.sleep(:infinity)

          {:error, message} ->
            fail(message)
        end

      _ ->
        fail("usage: stress dashboard [--port 4100] [--address HOST:PORT]")
    end
  end

  # run the same test at growing loads and stop where it first fails
  defp ladder([]), do: fail("usage: stress ladder <target> [address] --steps 25,50,100 [options]")

  defp ladder([name | args]) do
    extra = [
      steps: :string,
      by: :string,
      keep_going: :boolean,
      settle: :string,
      must_pass: :integer
    ]

    with {:ok, target} <- Target.resolve(name),
         {:ok, opts} <- parse(args, target, extra),
         {:ok, steps} <- steps(opts[:steps]),
         {:ok, by} <- by(opts[:by]),
         {:ok, settle} <- Units.ms(opts[:settle] || "5s", :s) do
      need = opts[:must_pass]

      opts =
        opts
        |> Map.drop([:steps, :by, :settle, :must_pass])
        |> Map.merge(%{target: target, settle_ms: settle})

      case Ladder.run(opts, steps, by) do
        {:ok, rungs} ->
          IO.puts(Ladder.verdict(rungs))

          # exit 0 if a rung passed (at or above --must-pass, when given): a ladder is meant to end in a failure
          if Enum.any?(rungs, &(&1.ok and (need == nil or &1.step >= need))), do: 0, else: 1

        {:error, message} ->
          fail(message)
      end
    else
      {:error, message} -> fail(message)
    end
  end

  defp steps(nil), do: {:error, "give the rungs: --steps 25,50,100,200"}

  defp steps(text) do
    parsed = text |> String.split(",", trim: true) |> Enum.map(&Integer.parse(String.trim(&1)))

    if parsed != [] and Enum.all?(parsed, &match?({n, ""} when n > 0, &1)),
      do: {:ok, Enum.map(parsed, &elem(&1, 0))},
      else: {:error, "#{inspect(text)} is not a list of numbers (try 25,50,100)"}
  end

  defp by(nil), do: {:ok, :vus}
  defp by(w) when w in ["vus", "users"], do: {:ok, :vus}
  defp by("rate"), do: {:ok, :rate}
  defp by(other), do: {:error, "--by #{other} is not users or rate"}

  defp finish({:ok, %{ok: true}}), do: 0
  defp finish({:ok, _report}), do: 1
  defp finish({:error, message}), do: fail(message)

  defp fail(message) do
    IO.puts(:stderr, "stress: #{message}")
    2
  end

  defp agent(args) do
    case OptionParser.parse(args, strict: [self: :string, cookie: :string]) do
      {opts, [], []} -> Agent.serve(Map.new(opts))
      _ -> fail("usage: stress agent --self NAME@HOST --cookie COOKIE")
    end
  end

  defp usage do
    IO.puts("""
    stress <target> [address] [options]     run a load test
    stress <scenario.json> [options]        run a scenario file (options override it)
    stress agent --self NAME@HOST --cookie C   lend this machine to runs started elsewhere
    stress ladder <target> [address] --steps 25,50,100,200   find where it stops passing
    stress dashboard [--port 4100]          buttons and live charts in your browser
    stress help <target>                    the options a target adds

    targets: #{Target.builtin() |> Map.keys() |> Enum.sort() |> Enum.join(", ")}

    load
      --vus N             users, each doing iterations one after another (default 10)
      --rate N            start N iterations a second instead, whatever the server does
      --max-vus N         the most users --rate may use at once
      --duration 30s      how long to hold the load (--seconds 30 also works)
      --ramp 10s          climb from 0 to --vus or --rate first
      --stages LIST       30s:100,1m:100,30s:0 (users) or 30s:200/s,1m:200/s (rate)
      --pace 33ms         one iteration every 33ms per user
      --think 1s          pause after each iteration
      --spawn-rate N      start at most N users a second
      --grace 10s         time users get to finish when the run ends

    judging
      --threshold EXPR    e.g. 'http.req:p99<250ms' or 'iterations.failed:ratio<1%' (repeat it)
                          --threshold none drops the target's defaults
      --checks LIST       default, all, none, or names
      --out FILE          also write the report as JSON
      --html FILE         and as an HTML page with charts
      --quiet             no line a second

    more machines
      --agents A,B        run users on these agents too; --no-local keeps them off this one
      --cookie C          the agents' cookie
      --self NAME@HOST    this machine's node name
    """)

    0
  end

  defp target_help(name) do
    case Target.resolve(name) do
      {:ok, target} ->
        IO.puts(
          if function_exported?(target, :usage, 0),
            do: target.usage(),
            else: "#{inspect(target)} has no extra options"
        )

        0

      {:error, message} ->
        fail(message)
    end
  end
end
