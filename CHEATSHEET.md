# Stress tester cheat sheet

How to load-test The Reach from the IEx shell, read what came back, and turn it
into a report you can open in a browser. The README has the long version.

## 1. Start the server

In `../the_reach_backend`:

```sh
iex -S mix
```

Dev listens on HTTP `4001` and UDP `4002`, with stress logins on, so bots named
`vigil-0001`, `accord-0001`, … can log in with the password `stress`.

Before runs of more than a few hundred bots, raise the kernel's UDP buffer cap.
At boot the server logs a warning when the cap is too low.

```sh
sudo sysctl -w net.core.rmem_max=4194304 net.core.wmem_max=4194304
```

The server's own shell, while a test runs:

| | |
| --- | --- |
| `Reach.stats()` | online, in battle, battles, accounts, UDP counters |
| `Reach.fronts()` | every fight, with its average tick cost |
| `Reach.match("crystal-gate/r1")` | one fight in detail |
| `curl -s localhost:4001/metrics` | tick times, packets in, drops (what the tester scrapes) |

## 2. The quick way: the dashboard

Buttons and live charts in your browser. In this folder, either:

```sh
iex -S mix            # then dashboard()
mix stress dashboard  # or ./stress dashboard
```

Then open <http://127.0.0.1:4100>. It listens on this machine only.

| On the left | What it does |
| --- | --- |
| Server | the Reach server's address; the dot turns green when it answers |
| Test | **Battle** (bots log in and fight), **Find the limit** (a battle at growing player counts, stopping at the first that fails), **Matchmaker** (bots go through the queue), **Checks only** (correctness tests, no load), **HTTP API**, **Login rush** (logins per second), **Scenario file** (anything in `scenarios/`) |
| Players | the slider, or type any number |
| Steps | for Find the limit: `100, 200, 400, 700, 1000` |
| Checks | the usual ones, all, none, or tick the ones you want |
| Run / Stop | Stop ends the run early; it is judged on the time it ran |

While it runs, the tiles and charts move every second:
- Players connected
- Round trip time
- Server tick time (the 33 ms budget is drawn on the chart)
- Snapshots received per second
- Bandwidth, both ways (**KB/s** or **Mbps**: the switch at the top right)
- Bot inputs, HTTP requests and response times, time to join
- Errors per second
- The tester's own CPU

When it ends you get:
- the verdict
- each rule it was judged on, in plain words
- every value and timing
- **Full report**, the same page as `html(r)`

Past runs are listed on the left. Started from `iex -S mix`, the dashboard's runs
are also in the shell, so `last()` and `compare(run(1), run(2))` work on them.

`dashboard(port: 4101, address: "10.0.0.5:4001")` picks another port or
server.

## 3. Open the tester shell

In this folder:

```sh
iex -S mix
```

`help()` prints the commands. They come from `StressTester.Shell`, which `.iex.exs`
imports for you.

## 4. Run something

| You want to know | Type |
| --- | --- |
| Does it work at all? (every check, ~25 s) | `scenario("reach-smoke")` |
| One full battle, 50 v 50 | `scenario("reach-50v50")` |
| A quick run of my own | `reach(vus: 20, duration: "10s")` |
| A ramp, then hold | `reach(vus: 200, ramp: "20s", duration: "1m")` |
| Less noise while it runs | add `quiet: true` (no line a second) |
| Several battles at once | `reach(vus: 300, per_place: 100)` (r1, r2, r3) |
| Players placed by the matchmaker | `reach(vus: 100, mode: "queue")` |
| Chat through the fight's reliable lane | `reach(vus: 20, chat: "2s")` |
| Reconnecting (rejoin check, ~9 s) | `reach(vus: 2, checks: "all")` |
| Skip the checks | `reach(vus: 100, checks: "none")` |
| Where does it stop passing? | `ladder(:reach, [50, 100, 200, 400, 700])` |
| Another machine's server | `reach("10.0.0.5:4001", vus: 50, metrics_token: "…")` |
| The HTTP API | `scenario("reach-api")` |
| A login rush | `scenario("reach-login-storm")` |
| One URL, at a fixed rate | `http("http://127.0.0.1:4001/v1/meta", rate: 500, duration: "30s")` |
| Open WebSockets | `ws("ws://127.0.0.1:4001/v1/lobby", vus: 100, pace: "1s")` |
| What scenarios exist | `scenarios()` |
| A scenario, but shorter | `scenario("reach-50v50", duration: "20s")` |

A run blocks the shell until it is done, then prints its report and keeps it
as `run(N)`.

Every scenario uses the target's address unless you give one, e.g.
`scenario("reach-50v50", address: "10.0.0.5:4001")`.

### Judge it your way

```elixir
reach(vus: 100, duration: "1m",
  threshold: ["reach.rtt:p99<50ms", "server.reach_tick_ms:p99<=33ms", "reach.snapshot_ratio>95%"])
```

| Threshold | Means |
| --- | --- |
| `reach.rtt:p99<50ms` | 99 % of round trips under 50 ms (also p50, p90, p95, p99.9, min, max, mean) |
| `iterations.failed:ratio<1%` | failed iterations out of all |
| `vu.connect_failed==0` | a counter (`count` is the default) |
| `reach.snapshot:rate>2000` | per second over the run |
| `server.reach_tick_ms:p99<=33ms` | from the server's own `/metrics` |
| `reach.snapshot_ratio>90%` | a number the tester works out at the end |

`threshold: ["none"]` drops the defaults. A bare number after a time is milliseconds.

## 5. Read the result

| | |
| --- | --- |
| `r = last()` | the newest report (`r = reach(...)` works too) |
| `runs()` | every run this session, with its number and verdict |
| `run(3)` | report number 3 |
| `show(r)` | print the whole report again |
| `r.ok` | `true` if every check and threshold held |
| `metric(r, "reach.rtt")` | count, min, mean, p50…p99.9, max (times in µs) |
| `r.counters["reach.snapshot"]` | any counter |
| `r.values` | numbers worked out at the end: snapshot loss, snapshot ratio, … |
| `r.errors` | what went wrong, grouped, most common first |
| `r.thresholds`, `r.checks` | each rule with its actual value |
| `r.server` | the server's `/metrics`, before and after |
| `timeline(r, "reach.rtt")` | `[{second, p99}, …]`; a counter gives its count per second |
| `compare(run(1), run(2))` | two runs side by side, with the change |

## 6. See it as a page, keep it

| | |
| --- | --- |
| `html(r)` | writes `reports/<time>-reach.html`: verdict, charts per second, every metric, the server's numbers |
| `html(r, open: true)` | and opens it in your browser |
| `html(r, "reports/50v50-before.html")` | a name of your choosing |
| `json(r)` | the report as JSON, for spreadsheets and scripts |
| `save(r, "runs/before.bin")` | the exact report, to load in a later session |
| `load("runs/before.bin")` | back into the history, so `compare(load("runs/before.bin"), last())` works |

The page draws charts for runs of 2 seconds or more.

## 7. What healthy looks like (Reach)

Check these first, in this order:

| Number | Healthy | If not |
| --- | --- | --- |
| checks | all `ok` | fix this before anything else |
| `vu.connect_failed` | 0 | see the errors list (below) |
| `reach.snapshot_ratio` | above 90 % | the server's tick is falling behind: fewer snapshots than inputs |
| `server` → `reach_tick_ms` p99 | ≤ 33 ms | the fight loop overran its 33 ms budget |
| `server` → `reach_udp_drops` | 0, or unchanged | packets dropped by a per-player budget |
| `reach.snapshot_loss` | under 1 % | snapshots the server numbered that never arrived |
| `reach.rtt` p99 | under 100 ms on one machine | measured in whole ms; `0µs` means under 1 ms |
| `tester` line | cpu under 90 %, small lag | the tester was the bottleneck, not the server |

Test results from this machine, with the server and the bots sharing 16 cores.
Players spread over battles of up to 100 each:
- 400 players: tick p99 ≤ 10 ms.
- 700 players: still passing.
- 1,000 players: the server fell behind (snapshot ratio 73 %).

Everyone in one battle (server started with `REACH_MATCH_CAP=2000`):
- 400 players: passing.
- 700 players: failing (snapshot ratio 47 %).

A single battle costs more per player as it grows, because each player's view
is worked out against every other player.

For the server's real limit, run the bots from another machine (section 10).

## 8. When something fails

| You see | It means |
| --- | --- |
| `login: bad_login (is the server running with stress logins on?…)` | the server has `stress_login` off: use dev, or `REACH_STRESS=1` |
| `login: locked` | ten wrong passwords on those names; wait 15 min or use `offset: 2000` |
| `login: 503 "busy"` | password hashing is full (the login-storm scenario measures this) |
| `connect: no_accept` | the UDP connect got no answer in 5 s: port blocked, server overloaded, or the kernel buffer (section 1) |
| check `fight`: "the ticket says to send UDP to 127.0.0.1" | set `REACH_ADVERTISE_HOST` on the server, or pass `udp_host:` |
| `server … unavailable` | `/metrics` only answers localhost; pass `metrics_token:` (the server's `REACH_METRICS_TOKEN`) |
| "the tester itself was busy" | spread the bots out (section 10); the server may be better than the numbers |
| a crash in the errors list | a bug in the tester: the line it came from is in the reason |

## 9. The same without IEx

```sh
mix escript.build                     # once: makes ./stress (needs only Erlang to run)
```

| | |
| --- | --- |
| `./stress scenarios/reach-50v50.json 127.0.0.1:4001` | a scenario |
| `./stress reach 127.0.0.1:4001 --vus 100 --duration 1m --html run.html` | a run, with an HTML page |
| `./stress ladder reach 127.0.0.1:4001 --steps 100,200,400` | a ladder |
| `./stress help` / `./stress help reach` | every option |

Exit status 0 means passed, 1 failed, and 2 could not start, so it works in a build
pipeline. `--out run.json` also writes JSON.

## 10. More than one machine

On each extra machine (copy `./stress` there; it needs Erlang):

```sh
./stress agent --self bots1@10.0.0.6 --cookie a-long-secret
```

Then from the shell:

```elixir
reach("10.0.0.5:4001", vus: 3000, agents: "bots1@10.0.0.6", cookie: "a-long-secret", local: false)
```

Set these on the server too, or bots on other machines cannot reach it:
- `REACH_ADVERTISE_HOST` to its real address
- an open UDP port

## 11. Options

| Load | |
| --- | --- |
| `vus:` | users at once |
| `rate:` | iterations started a second, whatever the server does (`max_vus:` caps the users) |
| `duration:` / `ramp:` | `"30s"`, `"5m"`; the ramp comes first |
| `stages:` | `"30s:100,2m:100,30s:0"` (users) or `"30s:200/s"` (rate) |
| `pace:` / `think:` | one iteration every …, or a pause after each (Reach paces at 33 ms) |
| `spawn_rate:` | at most N users started a second |

| Reach | |
| --- | --- |
| `place:` | `"crystal-gate/r1"` (default) |
| `per_place:` | fill r1, then r2, … this many each (100) |
| `mode:` | `"direct"` (default) or `"queue"`, with `planet:` |
| `sides:` | `"vigil,accord"` (default); also `host`, `holdfast` |
| `chat:` | how often each bot talks to its team |
| `offset:` | start bot numbers after N, so two runs don't share bots |
| `udp_host:` | send fight packets here instead of the ticket's address |
| `metrics_token:` | for the server's `/metrics` from another machine |
| `scrape:` | `"off"`, or another metrics URL |

## 12. Testing the tester

```sh
mix test                              # ~220 tests; boots a Reach server inside the test VM
```

The Reach server comes from `../the_reach_backend`, which must be on protocol 2.
To use another checkout:

```sh
REACH_BACKEND=/path/to/checkout mix test
```
