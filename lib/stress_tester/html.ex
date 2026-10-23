defmodule StressTester.Html do
  @moduledoc """
  A run as one HTML file you open in a browser: the verdict, what failed and why,
  charts of the run second by second (users, iterations, latency, errors), every
  metric, the server's own numbers, and the tester's health.

  It is a single file with inline SVG: no scripts, no network, so it can be
  mailed, archived next to the JSON, or opened years later.

      StressTester.Html.write(report, "reports/50v50.html")
      stress reach … --html run.html
  """

  alias StressTester.Units

  def write(report, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, render(report))
    path
  end

  def render(r) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{esc(title(r))}</title>
    <style>#{css()}</style>
    </head>
    <body>
    <header>
      <div class="verdict #{if r.ok, do: "pass", else: "fail"}">#{if r.ok, do: "PASS", else: "FAIL"}</div>
      <div>
        <h1>#{esc(r.target)}</h1>
        <p class="sub">#{esc(r.load)}#{if r.description, do: " · " <> esc(r.description), else: ""}</p>
        <p class="sub">#{esc(r.finished_at || "")}</p>
      </div>
    </header>
    <main>
    #{headline(r)}
    #{judging(r)}
    #{charts(r)}
    #{metrics(r)}
    #{counters(r)}
    #{server(r)}
    #{errors(r)}
    #{tester(r)}
    </main>
    </body>
    </html>
    """
  end

  defp title(r), do: "#{if r.ok, do: "PASS", else: "FAIL"} · #{r.target}"

  # -- the numbers at a glance

  defp headline(r) do
    c = r.counters
    secs = max(r.seconds, 0.001)
    it = r.metrics["iteration"]

    tiles =
      [
        {"users connected", n(c["vu.connected"]),
         "#{n(c["vu.connect_failed"])} failed, #{n(c["vu.lost"])} lost"},
        {"iterations", n(c["iterations"]),
         "#{Units.figure((c["iterations"] || 0) / secs)}/s, #{n(c["iterations.failed"])} failed"},
        {"iteration p99", (it && Units.time(it["p99"])) || "-",
         "p50 #{(it && Units.time(it["p50"])) || "-"}"},
        {"errors", n(c["errors"]), "#{length(r.errors)} kinds"}
      ] ++ watched_tiles(r)

    ~s(<section class="tiles">) <>
      Enum.map_join(tiles, "", fn {label, value, note} ->
        ~s(<div class="tile"><div class="label">#{esc(label)}</div><div class="value">#{esc(value)}</div><div class="note">#{esc(note)}</div></div>)
      end) <> "</section>"
  end

  defp watched_tiles(r) do
    Enum.flat_map(r.watch, fn name ->
      case r.metrics[name] do
        %{"p99" => p99, "p50" => p50, "unit" => unit} when p99 != nil ->
          u = String.to_existing_atom(unit)
          [{"#{name} p99", Units.value(p99, u), "p50 #{Units.value(p50, u)}"}]

        _ ->
          case r.counters[name] do
            nil -> []
            v -> [{name, n(v), "#{Units.figure(v / max(r.seconds, 0.001))}/s"}]
          end
      end
    end)
  end

  defp judging(r) do
    rows =
      Enum.map(r.thresholds, fn t -> {t["ok"], t["threshold"], t["shown"]} end) ++
        Enum.map(r.checks, fn c -> {c["ok"], "check: " <> c["check"], c["detail"]} end)

    if rows == [] do
      ""
    else
      section(
        "Thresholds and checks",
        table(
          ["", "rule", "actual"],
          Enum.map(rows, fn {ok, rule, actual} -> [mark(ok), esc(rule), esc(actual)] end)
        )
      )
    end
  end

  # -- second by second

  defp charts(%{timeline: timeline} = r) do
    case Enum.reject(timeline, & &1["partial"]) do
      full when length(full) >= 2 -> draw(full, r)
      _ -> ""
    end
  end

  defp draw(tl, r) do
    point = fn p, f -> {p["t"], f.(p) || 0} end

    base = [
      {"Users", Enum.map(tl, &point.(&1, fn p -> p["vus"] end)), :count},
      {"Iterations a second", Enum.map(tl, &point.(&1, fn p -> p["counters"]["iterations"] end)),
       :count},
      {"Iteration p99",
       Enum.map(tl, &point.(&1, fn p -> get_in(p, ["metrics", "iteration", "p99"]) end)), :us},
      {"Errors a second", Enum.map(tl, &point.(&1, fn p -> p["counters"]["errors"] end)), :count}
    ]

    watched =
      Enum.flat_map(r.watch, fn name ->
        cond do
          Enum.any?(tl, &get_in(&1, ["metrics", name])) ->
            unit = r.metrics[name] && String.to_existing_atom(r.metrics[name]["unit"])

            [
              {"#{name} p99",
               Enum.map(tl, &point.(&1, fn p -> get_in(p, ["metrics", name, "p99"]) end)),
               unit || :us}
            ]

          Enum.any?(tl, &get_in(&1, ["counters", name])) ->
            [
              {"#{name} a second", Enum.map(tl, &point.(&1, fn p -> p["counters"][name] end)),
               :count}
            ]

          true ->
            []
        end
      end)

    section(
      "Second by second",
      ~s(<div class="charts">) <> Enum.map_join(base ++ watched, "", &chart/1) <> "</div>"
    )
  end

  @w 520
  @h 150
  @pad_l 58
  @pad_b 22

  def chart({title, points, unit}) do
    max_y = points |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end) |> max(1)
    max_t = points |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 1 end) |> max(1)
    x = fn t -> @pad_l + t / max_t * (@w - @pad_l - 8) end
    y = fn v -> @h - @pad_b - v / max_y * (@h - @pad_b - 10) end

    line = Enum.map_join(points, " ", fn {t, v} -> "#{f(x.(t))},#{f(y.(v))}" end)
    area = "#{f(x.(0))},#{f(y.(0))} " <> line <> " #{f(x.(max_t))},#{f(y.(0))}"

    grid =
      for frac <- [0, 0.5, 1] do
        yy = f(y.(max_y * frac))
        label = esc(value(max_y * frac, unit))

        ~s(<line class="grid" x1="#{@pad_l}" x2="#{@w - 8}" y1="#{yy}" y2="#{yy}"/>) <>
          ~s(<text class="axis" x="#{@pad_l - 6}" y="#{yy}" text-anchor="end" dominant-baseline="middle">#{label}</text>)
      end

    """
    <figure class="chart">
      <figcaption>#{esc(title)}</figcaption>
      <svg viewBox="0 0 #{@w} #{@h}" role="img" aria-label="#{esc(title)}">
        #{Enum.join(grid)}
        <polygon class="area" points="#{area}"/>
        <polyline class="line" points="#{line}"/>
        <text class="axis" x="#{@pad_l}" y="#{@h - 4}">0s</text>
        <text class="axis" x="#{@w - 8}" y="#{@h - 4}" text-anchor="end">#{max_t}s</text>
      </svg>
    </figure>
    """
  end

  defp value(v, :us), do: Units.time(round(v))
  defp value(v, :bytes), do: Units.bytes(round(v))
  defp value(v, _) when v == trunc(v), do: Units.count(trunc(v))
  defp value(v, _) when v >= 10, do: Units.count(round(v))
  defp value(v, _), do: Units.fixed(v * 1.0, 1)

  defp f(v), do: :erlang.float_to_binary(v * 1.0, decimals: 1)

  # -- tables

  defp metrics(r) do
    rows =
      r.metrics
      |> Enum.sort_by(fn {name, _} -> {name != "iteration", name} end)
      |> Enum.map(fn {name, m} ->
        u = String.to_existing_atom(m["unit"])

        [
          esc(name),
          n(m["count"]),
          Units.value(m["p50"], u),
          Units.value(m["p90"], u),
          Units.value(m["p99"], u),
          Units.value(m["max"], u)
        ]
      end)

    if rows == [],
      do: "",
      else:
        section("Timings and sizes", table(["", "count", "p50", "p90", "p99", "max"], rows, :num))
  end

  defp counters(r) do
    secs = max(r.seconds, 0.001)

    rows =
      r.counters
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [esc(k), n(v), Units.figure(v / secs) <> "/s"] end)

    values =
      r.values
      |> Enum.sort()
      |> Enum.map(fn {k, v} ->
        [
          esc(k),
          if(String.ends_with?(k, ["_ratio", "_loss"]),
            do: Units.percent(v),
            else: Units.figure(v * 1.0)
          ),
          ""
        ]
      end)

    if rows == [],
      do: "",
      else: section("Counters", table(["", "total", "rate"], rows ++ values, :num))
  end

  defp server(%{server: %{diff: diff, url: url}}) do
    hists =
      diff.histograms
      |> Enum.sort()
      |> Enum.map(fn {name, h} ->
        ps = StressTester.Histogram.percentiles(h, [50, 90, 99])

        [
          esc(name),
          n(h.count),
          "≤" <> value(ps[50], h.unit),
          "≤" <> value(ps[90], h.unit),
          "≤" <> value(ps[99], h.unit)
        ]
      end)

    series =
      diff.series
      |> Enum.filter(&(&1.delta != 0 or (&1.after || 0) != 0))
      |> Enum.map(fn s ->
        [
          esc(s.name),
          Units.figure(s.before * 1.0),
          Units.figure(s.after * 1.0),
          Units.figure(s.delta * 1.0)
        ]
      end)

    section(
      "The server's own numbers",
      ~s(<p class="sub">#{esc(url)}, before and after the load</p>) <>
        if(hists != [], do: table(["", "samples", "p50", "p90", "p99"], hists, :num), else: "") <>
        if(series != [], do: table(["", "before", "after", "change"], series, :num), else: "")
    )
  end

  defp server(%{server: %{error: error, url: url}}),
    do:
      section(
        "The server's own numbers",
        ~s(<p class="sub">#{esc(url)} could not be read: #{esc(error)}</p>)
      )

  defp server(_r), do: ""

  defp errors(%{errors: []}), do: ""

  defp errors(r) do
    rows =
      Enum.map(Enum.take(r.errors, 50), fn e ->
        [n(e["count"]), esc(e["where"]), esc(e["reason"])]
      end)

    section("Errors", table(["count", "where", "why"], rows))
  end

  defp tester(r) do
    t = r.tester
    lag = if t["lag_p99"], do: Units.time(t["lag_p99"]), else: "-"

    busy =
      t["cpu_peak"] > 0.9 or
        (t["pace_us"] != nil and t["lag_p99"] != nil and t["lag_p99"] > t["pace_us"] / 2)

    section(
      "The tester itself",
      table(["machines", "peak users", "cpu peak", "run queue peak", "clock lag p99"], [
        [
          n(t["machines"]),
          n(t["peak_users"]),
          Units.percent(t["cpu_peak"] || 0.0),
          n(t["run_queue_peak"]),
          lag
        ]
      ]) <>
        if(busy,
          do:
            ~s(<p class="warn">The tester was busy; the server may be better than these numbers.</p>),
          else: ""
        )
    )
  end

  defp section(title, body), do: ~s(<section><h2>#{esc(title)}</h2>#{body}</section>)

  defp table(head, rows, kind \\ :text) do
    cls = if kind == :num, do: ~s( class="num"), else: ""

    ~s(<div class="scroll"><table#{cls}><thead><tr>) <>
      Enum.map_join(head, "", &"<th>#{esc(&1)}</th>") <>
      "</tr></thead><tbody>" <>
      Enum.map_join(rows, "", fn row ->
        "<tr>" <> Enum.map_join(row, "", &"<td>#{&1}</td>") <> "</tr>"
      end) <>
      "</tbody></table>"
  end

  defp mark(true), do: ~s(<span class="ok">ok</span>)
  defp mark(false), do: ~s(<span class="bad">FAIL</span>)

  defp n(nil), do: "0"
  defp n(v), do: Units.figure(v)

  def esc(nil), do: ""

  def esc(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp css do
    """
    :root{--bg:#fafaf8;--fg:#1d1f21;--muted:#6b6f76;--card:#fff;--line:#e3e3df;--accent:#2f6fde;--area:rgba(47,111,222,.12);--ok:#1f8a4c;--bad:#c4372f}
    @media (prefers-color-scheme: dark){:root{--bg:#141517;--fg:#e8e8e6;--muted:#9a9ea5;--card:#1c1e21;--line:#2c2f33;--accent:#6ea0ff;--area:rgba(110,160,255,.15);--ok:#4cc27e;--bad:#ff6b61}}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,-apple-system,Segoe UI,sans-serif}
    header{display:flex;gap:18px;align-items:center;padding:24px 16px;max-width:1100px;margin:0 auto}
    h1{font-size:20px;margin:0}h2{font-size:15px;margin:28px 0 10px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
    .sub{color:var(--muted);margin:2px 0}main{max-width:1100px;margin:0 auto;padding:0 16px 48px}
    .verdict{font-weight:700;font-size:18px;padding:10px 16px;border-radius:8px;color:#fff}.pass{background:var(--ok)}.fail{background:var(--bad)}
    .tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px}
    .tile{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px}
    .label{color:var(--muted);font-size:12px}.value{font-size:22px;font-weight:600;font-variant-numeric:tabular-nums}.note{color:var(--muted);font-size:12px}
    .charts{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:10px}
    .chart{margin:0;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px}
    figcaption{font-size:13px;color:var(--muted);margin-bottom:4px}svg{width:100%;height:auto}
    .line{fill:none;stroke:var(--accent);stroke-width:2}.area{fill:var(--area);stroke:none}.grid{stroke:var(--line)}
    .axis{fill:var(--muted);font-size:11px}
    .scroll{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:8px;margin-bottom:10px}
    table{width:100%;border-collapse:collapse}tr:last-child td{border-bottom:none}
    th,td{padding:7px 10px;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}th{color:var(--muted);font-weight:500;font-size:12px}
    table.num td+td,table.num th+th{text-align:right;font-variant-numeric:tabular-nums}
    .ok{color:var(--ok);font-weight:600}.bad{color:var(--bad);font-weight:700}.warn{color:var(--bad)}
    """
  end
end
