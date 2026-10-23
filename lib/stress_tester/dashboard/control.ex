defmodule StressTester.Dashboard.Control do
  @moduledoc """
  What the dashboard's buttons do. One test at a time: it turns the form into
  run options, starts the run in its own process, passes every second of it to
  the pages that are watching, and stops it when asked.

  A page that opens (or reloads) in the middle of a run is sent everything so
  far, so nothing is lost by closing a tab.
  """

  use GenServer

  require Logger

  alias StressTester.{History, Http, Ladder, Net, Plan}

  @tests [
    %{
      "id" => "battle",
      "name" => "Battle",
      "about" =>
        "Bots log in, open the lobby, take a seat and fight over UDP, the way players do.",
      "fields" => ~w(players duration ramp per_place chat checks)
    },
    %{
      "id" => "ladder",
      "name" => "Find the limit",
      "about" =>
        "The same battle at growing player counts, one after another; stops at the first that fails.",
      "fields" => ~w(steps duration ramp per_place)
    },
    %{
      "id" => "queue",
      "name" => "Matchmaker",
      "about" => "Bots join the queue and the matchmaker places them in battles.",
      "fields" => ~w(players duration ramp)
    },
    %{
      "id" => "checks",
      "name" => "Checks only",
      "about" => "One-off correctness tests (login, tokens, lobby, fight, reconnect), no load.",
      "fields" => ~w(checks)
    },
    %{
      "id" => "api",
      "name" => "HTTP API",
      "about" =>
        "Players using the HTTP routes after logging in: me, friends, the war, fronts, catalog.",
      "fields" => ~w(players duration ramp)
    },
    %{
      "id" => "logins",
      "name" => "Login rush",
      "about" =>
        "Logins started at a fixed rate, like a patch day. Password hashing is the cost.",
      "fields" => ~w(rate duration)
    },
    %{
      "id" => "scenario",
      "name" => "Scenario file",
      "about" => "Any file from scenarios/, with the player count and length you set here.",
      "fields" => ~w(scenario players duration)
    }
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def state, do: GenServer.call(__MODULE__, :state)
  def run(params), do: GenServer.call(__MODULE__, {:run, params}, 15_000)
  def stop, do: GenServer.call(__MODULE__, :stop)
  def subscribe(pid), do: GenServer.cast(__MODULE__, {:subscribe, pid})
  def halted?, do: GenServer.call(__MODULE__, :halted?)

  # is the server at this address answering?
  def health(address) do
    with {:ok, origin} <- Net.origin(address),
         {:ok, conn, %{status: 200}} <-
           Http.request(Http.new(origin), "GET", "/health", [], nil, 1_500) do
      Http.close(conn)
      %{"up" => true, "address" => address}
    else
      {:error, conn, reason} when is_struct(conn) ->
        %{"up" => false, "detail" => StressTester.Metrics.reason(reason)}

      {:error, reason} ->
        %{"up" => false, "detail" => StressTester.Metrics.reason(reason)}

      {:ok, _conn, %{status: status}} ->
        %{"up" => false, "detail" => "answered #{status}"}

      _ ->
        %{"up" => false, "detail" => "no answer"}
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       address: Keyword.get(opts, :address, "127.0.0.1:4001"),
       status: "idle",
       current: nil,
       task: nil,
       generators: [],
       stop_asked: false,
       points: [],
       samples: [],
       checks: nil,
       rungs: [],
       subscribers: MapSet.new(),
       last: nil,
       # run number => what the dashboard called it, for the list of past runs
       labels: %{}
     }}
  end

  @impl true
  def handle_call(:state, _from, s), do: {:reply, view(s), s}

  def handle_call(:halted?, _from, s), do: {:reply, s.stop_asked, s}

  def handle_call({:run, _params}, _from, %{status: status} = s) when status != "idle",
    do: {:reply, {:error, :busy}, s}

  def handle_call({:run, params}, _from, s) do
    me = self()

    case build(params, s.address, me) do
      {:ok, kind, opts, extra} ->
        task = Task.async(fn -> execute(kind, opts, extra) end)

        current = %{
          "test" => params["test"],
          "params" => params,
          "started_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }

        s = %{
          s
          | status: "running",
            task: task,
            current: current,
            generators: [],
            stop_asked: false,
            points: [],
            samples: [],
            checks: nil,
            rungs: [],
            last: nil
        }

        broadcast(s, "status", status_view(s))
        {:reply, {:ok, current}, s}

      {:error, message} ->
        {:reply, {:error, message}, s}
    end
  end

  def handle_call(:stop, _from, %{status: "idle"} = s), do: {:reply, {:error, :idle}, s}

  def handle_call(:stop, _from, s) do
    Enum.each(s.generators, &send(&1, :abort))
    s = %{s | status: "stopping", stop_asked: true}
    broadcast(s, "status", status_view(s))
    {:reply, :ok, s}
  end

  @impl true
  def handle_cast({:subscribe, pid}, s) do
    Process.monitor(pid)
    # everything so far, so a page opened mid-run is complete
    send(pid, {:event, "snapshot", snapshot(s)})
    {:noreply, %{s | subscribers: MapSet.put(s.subscribers, pid)}}
  end

  @impl true
  def handle_info({:stress_started, info}, s) do
    s = put_in(s.current["target"], info.target) |> put_in([:current, "load"], info.load)
    broadcast(s, "started", info)
    {:noreply, s}
  end

  def handle_info({:stress_checks, checks}, s) do
    view =
      Enum.map(checks, fn {name, result} ->
        %{"check" => name, "ok" => result == :ok, "detail" => detail(result)}
      end)

    broadcast(s, "checks", view)
    {:noreply, %{s | checks: view}}
  end

  def handle_info({:stress_generators, pids}, s) do
    # stop was pressed before the users started
    if s.stop_asked, do: Enum.each(pids, &send(&1, :abort))

    {:noreply,
     %{s | generators: pids, points: if(s.current["test"] == "ladder", do: s.points, else: [])}}
  end

  def handle_info({:stress_point, point}, s) do
    point = point |> Map.put("rung", length(s.rungs)) |> slim()
    broadcast(s, "point", point)
    {:noreply, %{s | points: [point | s.points]}}
  end

  def handle_info({:stress_server, sample}, s) do
    broadcast(s, "server", sample)
    {:noreply, %{s | samples: [sample | s.samples]}}
  end

  def handle_info({:rung, row, run}, s) do
    labels =
      if run, do: Map.put(s.labels, run, "Find the limit · #{row.step} players"), else: s.labels

    row = rung_view(row)
    broadcast(s, "rung", row)
    {:noreply, %{s | rungs: s.rungs ++ [row], labels: labels}}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])
    s = remember_label(s, result)
    done = done_view(result, s)
    s = %{s | status: "idle", task: nil, generators: [], last: done}
    broadcast(s, "done", done)
    broadcast(s, "status", status_view(s))
    {:noreply, s}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = s) do
    done = %{"ok" => false, "error" => "the run crashed: #{StressTester.Metrics.reason(reason)}"}
    s = %{s | status: "idle", task: nil, generators: [], last: done}
    broadcast(s, "done", done)
    broadcast(s, "status", status_view(s))
    {:noreply, s}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, s),
    do: {:noreply, %{s | subscribers: MapSet.delete(s.subscribers, pid)}}

  def handle_info(_other, s), do: {:noreply, s}

  defp remember_label(s, {:ok, %{run: id}}) when is_integer(id),
    do: %{s | labels: Map.put(s.labels, id, label(s.current))}

  defp remember_label(s, _result), do: s

  defp label(%{"test" => test, "params" => p}) do
    name = Enum.find_value(@tests, test, &(&1["id"] == test && &1["name"]))

    case test do
      t when t in ["battle", "queue", "api", "scenario"] -> "#{name} · #{p["players"]} players"
      "logins" -> "#{name} · #{p["rate"]}/s"
      _ -> name
    end
  end

  defp label(_), do: nil

  # -- running

  defp execute(:run, opts, _extra), do: StressTester.run(opts)

  defp execute(:file, opts, path), do: StressTester.run_file(path, opts)

  defp execute(:ladder, opts, steps) do
    control = self_control()

    opts =
      Map.merge(Map.new(opts), %{
        on_rung: fn row, report -> send(control, {:rung, row, report.run}) end,
        halt?: &halted?/0
      })

    case Ladder.run(opts, steps, :vus) do
      {:ok, rungs} -> {:ladder, rungs}
      {:error, message} -> {:error, message}
    end
  end

  defp self_control, do: Process.whereis(__MODULE__)

  # the form, as run options; checked here so a mistake is answered at once
  def build(params, default_address, listener) do
    address = blank(params["address"]) || default_address
    common = [address: address, listener: listener, silent: true]

    with {:ok, kind, opts, extra} <- shape(params["test"], params, common),
         :ok <- check(kind, opts, extra) do
      {:ok, kind, opts, extra}
    end
  end

  defp shape("battle", p, common) do
    opts =
      common ++
        load(p) ++
        [target: "reach", checks: checks(p["checks"])] ++
        if(int(p["per_place"]), do: [per_place: int(p["per_place"])], else: []) ++
        if(int(p["chat"]) && int(p["chat"]) > 0, do: [chat: "#{int(p["chat"])}s"], else: [])

    {:ok, :run, opts, nil}
  end

  defp shape("queue", p, common),
    do: {:ok, :run, common ++ load(p) ++ [target: "reach", mode: "queue", checks: "none"], nil}

  defp shape("checks", p, common) do
    {:ok, :run,
     common ++
       [
         target: "reach",
         vus: 0,
         duration: "1s",
         checks: checks(p["checks"] || "all"),
         threshold: ["none"]
       ], nil}
  end

  defp shape("ladder", p, common) do
    case steps(p["steps"]) do
      {:ok, steps} ->
        opts =
          common ++
            [
              target: "reach",
              duration: "#{int(p["duration"]) || 20}s",
              ramp: "#{int(p["ramp"]) || 10}s",
              settle_ms: 5_000
            ] ++
            if(int(p["per_place"]), do: [per_place: int(p["per_place"])], else: [])

        {:ok, :ladder, opts, steps}

      error ->
        error
    end
  end

  defp shape("api", p, common) do
    url = "http://" <> String.replace_prefix(common[:address], "http://", "")

    {:ok, :file, Keyword.drop(common, [:address]) ++ load(p) ++ [address: url],
     scenario_path("reach-api")}
  end

  defp shape("logins", p, common) do
    url = "http://" <> String.replace_prefix(common[:address], "http://", "")
    rate = number(p["rate"]) || 50

    {:ok, :file,
     Keyword.drop(common, [:address]) ++
       [address: url, rate: rate * 1.0, duration: "#{int(p["duration"]) || 20}s", ramp: "3s"],
     scenario_path("reach-login-storm")}
  end

  defp shape("scenario", p, common) do
    name = p["scenario"] || ""

    if name in scenario_names() do
      {:ok, :file, common ++ load(p), scenario_path(name)}
    else
      {:error, "choose a scenario: #{Enum.join(scenario_names(), ", ")}"}
    end
  end

  defp shape(other, _p, _common), do: {:error, "unknown test #{inspect(other)}"}

  defp load(p) do
    [vus: int(p["players"]) || 10, duration: "#{int(p["duration"]) || 30}s"] ++
      if(int(p["ramp"]) && int(p["ramp"]) > 0, do: [ramp: "#{int(p["ramp"])}s"], else: [])
  end

  defp check(:file, opts, path) do
    case Plan.from_file(path, Map.new(opts)) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp check(:ladder, opts, [first | _]), do: check(:run, Keyword.put(opts, :vus, first), nil)

  defp check(:run, opts, _) do
    case Plan.build(opts) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp checks(list) when is_list(list) and list != [], do: Enum.join(list, ",")
  defp checks(word) when word in ["default", "all", "none"], do: word
  defp checks(_), do: "default"

  defp steps(text) when is_binary(text) do
    parsed = text |> String.split(~r/[,\s]+/, trim: true) |> Enum.map(&Integer.parse/1)

    if parsed != [] and Enum.all?(parsed, &match?({n, ""} when n > 0, &1)),
      do: {:ok, Enum.map(parsed, &elem(&1, 0))},
      else: {:error, "steps are player counts, like 50, 100, 200"}
  end

  defp steps(_), do: {:error, "steps are player counts, like 50, 100, 200"}

  defp scenario_dir, do: Path.join(File.cwd!(), "scenarios")
  defp scenario_path(name), do: Path.join(scenario_dir(), name <> ".json")

  defp scenario_names do
    scenario_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.sort()
  end

  defp int(nil), do: nil
  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: round(n)

  defp int(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp number(n) when is_number(n), do: n

  defp number(text) when is_binary(text),
    do: with({f, _} <- Float.parse(text), do: f, else: (_ -> nil))

  defp number(_), do: nil

  defp blank(nil), do: nil

  defp blank(text) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  # -- what the page sees

  defp broadcast(s, name, data), do: Enum.each(s.subscribers, &send(&1, {:event, name, data}))

  defp view(s) do
    %{
      "status" => status_view(s),
      "tests" => @tests,
      "checks" => StressTester.Reach.Checks.names(),
      "scenarios" => scenario_names(),
      "history" => history(s.labels),
      "address" => s.address
    }
  end

  defp status_view(s), do: %{"status" => s.status, "current" => s.current}

  defp snapshot(s) do
    %{
      "status" => status_view(s),
      "points" => Enum.reverse(s.points),
      "samples" => Enum.reverse(s.samples),
      "checks" => s.checks,
      "rungs" => s.rungs,
      "last" => s.last,
      "history" => history(s.labels)
    }
  end

  defp history(labels) do
    for %{id: id, report: r} <- Enum.reverse(History.all()) do
      %{
        "id" => id,
        "label" => labels[id],
        "ok" => r.ok,
        "target" => r.target,
        "load" => r.load,
        "finished_at" => r.finished_at,
        "report" => "/reports/#{id}"
      }
    end
  end

  # what the page draws from a second: the counters and a few numbers per timing
  defp slim(point) do
    metrics =
      Map.new(point["metrics"] || %{}, fn {name, m} ->
        {name,
         %{"p50" => m["p50"], "p99" => m["p99"], "count" => m["count"], "unit" => m["unit"]}}
      end)

    point |> Map.put("metrics", metrics) |> Map.drop(["partial"])
  end

  defp done_view({:ok, report}, s) do
    %{
      "ok" => report.ok,
      "stopped" => s.stop_asked,
      "run" => report.run,
      "report" => "/reports/#{report.run}",
      "target" => report.target,
      "load" => report.load,
      "seconds" => report.seconds,
      "thresholds" => report.thresholds,
      "checks" => report.checks,
      "values" => report.values,
      "counters" => report.counters,
      "metrics" => report.metrics,
      "errors" => Enum.take(report.errors, 10),
      "server" => server_summary(report.server),
      "history" => history(s.labels)
    }
  end

  defp done_view({:ladder, rungs}, s) do
    passed = rungs |> Enum.filter(& &1.ok) |> List.last()

    %{
      "ok" => passed != nil,
      "stopped" => s.stop_asked,
      "ladder" => Enum.map(rungs, &rung_view/1),
      "verdict" => Ladder.verdict(rungs) |> String.trim(),
      "best" => passed && passed.step,
      "history" => history(s.labels)
    }
  end

  defp done_view({:error, message}, s),
    do: %{"ok" => false, "error" => to_string(message), "history" => history(s.labels)}

  defp server_summary(%{diff: diff, url: url}) do
    %{
      "url" => url,
      "histograms" =>
        Map.new(diff.histograms, fn {name, h} ->
          ps = StressTester.Histogram.percentiles(h, [50, 90, 99])

          {name,
           %{
             "p50" => ps[50],
             "p90" => ps[90],
             "p99" => ps[99],
             "unit" => h.unit,
             "count" => h.count
           }}
        end),
      "series" =>
        Enum.map(
          diff.series,
          &%{"name" => &1.name, "before" => &1.before, "after" => &1.after, "delta" => &1.delta}
        )
    }
  end

  defp server_summary(%{error: error, url: url}), do: %{"url" => url, "error" => error}
  defp server_summary(_), do: nil

  defp rung_view(row) when is_map_key(row, :step) do
    %{
      "players" => row.step,
      "ok" => row.ok,
      "failing" => Map.get(row, :failing, []),
      "iterations_per_s" => Map.get(row, :iterations_per_s),
      "connect_failed" => Map.get(row, :connect_failed),
      "error" => Map.get(row, :error)
    }
  end

  defp rung_view(row), do: row

  defp detail(:ok), do: ""
  defp detail({:error, reason}), do: StressTester.Metrics.reason(reason)
  defp detail(other), do: StressTester.Metrics.reason(other)
end
