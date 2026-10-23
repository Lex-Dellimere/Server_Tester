defmodule StressTester.Shell do
  @moduledoc """
  Short names for running and reading load tests from IEx. `iex -S mix` in this
  project imports them (see `.iex.exs`); `h()`-style help is `help()`.

      reach(vus: 100, duration: "30s")           # the Reach server on 127.0.0.1:4001
      scenario("reach-50v50")                    # a file from scenarios/
      ladder(:reach, [25, 50, 100, 200])         # where does it stop passing?
      last() |> html()                           # the last run as an HTML page
      compare(run(1), run(2))                    # two runs side by side

  Every run is kept for the session (`runs/0`) and returns its report, a map:
  `r.ok`, `r.counters`, `r.metrics["reach.rtt"]["p99"]` (µs), `r.errors`,
  `r.timeline` (a point a second), `r.server` (the server's own metrics).
  """

  alias StressTester.{History, Html, Ladder, Report, Units}

  @reach "127.0.0.1:4001"

  # -- running

  @doc "Bots against the Reach server. `reach(vus: 50)` or `reach(\"10.0.0.5:4001\", vus: 50)`."
  def reach(opts \\ []), do: reach(@reach, opts)

  def reach(address, opts) when is_binary(address),
    do: go([target: "reach", address: address] ++ opts)

  @doc "Requests to one URL. `http(\"http://127.0.0.1:4001/v1/meta\", rate: 200)`."
  def http(url, opts \\ []), do: go([target: "http", address: url] ++ opts)

  @doc "Open WebSockets. `ws(\"ws://127.0.0.1:4001/v1/lobby\", vus: 100)`."
  def ws(url, opts \\ []), do: go([target: "ws", address: url] ++ opts)

  @doc """
  A scenario file: a name from `scenarios/` (`"reach-50v50"`) or any path. Options
  override the file: `scenario("reach-50v50", address: "10.0.0.5:4001", duration: "20s")`.
  """
  def scenario(name, opts \\ []) do
    name |> path_of() |> StressTester.run_file(opts) |> record()
  end

  @doc "The scenario files you can run."
  def scenarios do
    for f <- Path.wildcard(Path.join(scenario_dir(), "*.json")) |> Enum.sort() do
      name = Path.basename(f, ".json")

      desc =
        with {:ok, t} <- File.read(f),
             {:ok, j} <- JSON.decode(t),
             do: j["description"] || "",
             else: (_ -> "")

      IO.puts(String.pad_trailing(name, 20) <> " " <> String.slice(desc, 0, 100))
    end

    :ok
  end

  @doc """
  The same test at growing loads, stopping at the first rung that fails.
  `ladder(:reach, [25, 50, 100])` or `ladder(:http, [100, 500], address: url, by: :rate)`.
  """
  def ladder(target, steps, opts \\ []) do
    {by, opts} = Keyword.pop(opts, :by, :vus)
    opts = Keyword.put_new(opts, :address, if(target in [:reach, "reach"], do: @reach))

    opts = opts |> Keyword.put(:target, to_string(target)) |> settle()

    case Ladder.run(opts, steps, by) do
      {:ok, rungs} ->
        IO.puts(Ladder.verdict(rungs))
        rungs

      {:error, message} ->
        IO.puts("could not run: #{message}")
        {:error, message}
    end
  end

  defp settle(opts) do
    case Keyword.pop(opts, :settle) do
      {nil, opts} -> opts
      {text, opts} -> Keyword.put(opts, :settle_ms, elem(Units.ms(text, :s), 1))
    end
  end

  defp go(opts), do: opts |> StressTester.run() |> record()

  # the report itself, so `r = reach(...)` keeps it
  defp record({:ok, report}) do
    if id = report.run,
      do: IO.puts("(run #{id}: run(#{id}) gets it back, html(run(#{id})) makes a page)")

    report
  end

  defp record({:error, message} = error) do
    IO.puts("could not run: #{message}")
    error
  end

  # -- reading

  @doc "Every run this session: number, verdict, what and how hard."
  def runs do
    for %{id: id, report: r} <- History.all() do
      IO.puts(
        "#{String.pad_leading(Integer.to_string(id), 3)}  #{if r.ok, do: "PASS", else: "FAIL"}  " <>
          "#{String.pad_trailing(String.slice(r.target, 0, 60), 60)}  #{r.load}"
      )
    end

    :ok
  end

  def run(id),
    do: History.get(id) || raise(ArgumentError, "no run #{id} this session; runs() lists them")

  def last, do: History.last() || raise(ArgumentError, "nothing has run yet this session")

  @doc "Print a report again."
  def show(r \\ last()) do
    IO.puts(Report.text(r))
    :ok
  end

  @doc "One metric's numbers: `metric(\"reach.rtt\")`."
  def metric(r \\ last(), name) do
    case r.metrics[name] do
      nil -> {:missing, Map.keys(r.metrics) |> Enum.sort()}
      m -> m
    end
  end

  @doc "A metric or counter second by second: `timeline(\"reach.rtt\")` gives `[{second, p99}]`."
  def timeline(r \\ last(), name) do
    full = Enum.reject(r.timeline, & &1["partial"])

    for p <- if(full == [], do: r.timeline, else: full) do
      v =
        case p["metrics"][name] do
          %{"p99" => p99} -> p99
          nil -> p["counters"][name] || 0
        end

      {p["t"], v}
    end
  end

  @doc """
  Two runs side by side, with the change: users, iterations, failures, and the p99
  of every timing both have. `compare(run(1), run(2))`.
  """
  def compare(a, b) do
    rows =
      [
        {"verdict", verdict(a), verdict(b), ""},
        {"users connected", a.counters["vu.connected"] || 0, b.counters["vu.connected"] || 0},
        {"iterations/s", rate(a, "iterations"), rate(b, "iterations")},
        {"iterations failed", a.counters["iterations.failed"] || 0,
         b.counters["iterations.failed"] || 0},
        {"errors", a.counters["errors"] || 0, b.counters["errors"] || 0}
      ] ++
        for name <- Enum.sort(Map.keys(a.metrics)), Map.has_key?(b.metrics, name) do
          {name <> " p99", {a.metrics[name]["p99"], a.metrics[name]["unit"]},
           {b.metrics[name]["p99"], b.metrics[name]["unit"]}}
        end

    width = rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max()

    IO.puts(
      String.pad_trailing("", width) <>
        String.pad_leading("A", 14) <> String.pad_leading("B", 14) <> "   change"
    )

    for row <- rows do
      {label, x, y, change} =
        case row do
          {label, x, y, change} -> {label, x, y, change}
          {label, x, y} -> {label, x, y, change(x, y)}
        end

      IO.puts(
        String.pad_trailing(label, width) <>
          String.pad_leading(cell(x), 14) <> String.pad_leading(cell(y), 14) <> "   " <> change
      )
    end

    :ok
  end

  defp verdict(r), do: if(r.ok, do: "PASS", else: "FAIL")
  defp rate(r, name), do: (r.counters[name] || 0) / max(r.seconds, 0.001)

  defp cell({nil, _unit}), do: "-"
  defp cell({v, unit}), do: Units.value(v, String.to_existing_atom(unit))
  defp cell(v) when is_integer(v), do: Units.count(v)
  defp cell(v) when is_number(v), do: Units.figure(v * 1.0)
  defp cell(v), do: to_string(v)

  defp change({x, _}, {y, _}), do: change(x, y)

  defp change(x, y) when is_number(x) and is_number(y) and x != 0,
    do: "#{if y >= x, do: "+", else: ""}#{Units.fixed((y - x) / x * 100, 1)}%"

  defp change(_x, _y), do: ""

  # -- keeping

  @doc """
  The report as an HTML page with charts. Without a path it goes to
  `reports/<time>-<target>.html`; `open: true` opens it in your browser.
  """
  def html(r \\ last(), path \\ nil, opts \\ [])

  def html(r, opts, []) when is_list(opts), do: html(r, nil, opts)

  def html(r, path, opts) do
    path = path || default_path(r, "html")
    Html.write(r, path)
    IO.puts("wrote #{Path.expand(path)}")
    if opts[:open], do: System.cmd("xdg-open", [path], stderr_to_stdout: true)
    Path.expand(path)
  end

  @doc "The report as JSON, for other tools."
  def json(r \\ last(), path \\ nil) do
    path = path || default_path(r, "json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Report.json(r))
    Path.expand(path)
  end

  @doc "Keep a report exactly (to `load/1` it in a later session)."
  def save(r \\ last(), path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(r))
    Path.expand(path)
  end

  def load(path), do: path |> File.read!() |> :erlang.binary_to_term() |> History.add()

  defp default_path(r, ext) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    target = r.target |> String.split(" ") |> hd()
    Path.join("reports", "#{stamp}-#{target}.#{ext}")
  end

  # -- finding things

  defp path_of(name) do
    cond do
      File.exists?(name) ->
        name

      File.exists?(Path.join(scenario_dir(), name <> ".json")) ->
        Path.join(scenario_dir(), name <> ".json")

      File.exists?(Path.join(scenario_dir(), name)) ->
        Path.join(scenario_dir(), name)

      true ->
        raise ArgumentError, "no scenario #{inspect(name)}; scenarios() lists them"
    end
  end

  defp scenario_dir, do: Path.join(File.cwd!(), "scenarios")

  def help do
    IO.puts("""
    run                                            read
      reach(vus: 100, duration: "30s")               last()            the newest report
      reach("10.0.0.5:4001", vus: 50)                runs()            every run this session
      scenario("reach-50v50")                        run(3)            report number 3
      scenarios()                                    show(r)           print it again
      ladder(:reach, [25, 50, 100, 200])             metric(r, "reach.rtt")
      http("http://127.0.0.1:4001/v1/meta", rate: 200)  timeline(r, "reach.rtt")
      ws("ws://127.0.0.1:4001/v1/lobby", vus: 10)    compare(run(1), run(2))

    keep                                           in a report r
      html(r)       an HTML page with charts         r.ok   r.counters   r.errors
      html(r, open: true)                            r.metrics["reach.rtt"]["p99"]   (µs)
      json(r)       the report as JSON               r.timeline (a point a second)
      save(r, "a.bin") / load("a.bin")               r.server   (the server's /metrics)

    any option from `stress help` works: vus:, rate:, duration:, ramp:, stages:, pace:,
    threshold: ["reach.rtt:p99<50ms"], checks: "all", quiet: true …
    the full cheat sheet is CHEATSHEET.md
    """)
  end
end
