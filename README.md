# Stress tester

Load for anything that talks over a socket. You say **what to talk to**, **how many users or how many
requests a second**, and **what counts as passing**; it runs that, and says what happened.

| Target | Talks to | Command |
| --- | --- | --- |
| `reach` | The Reach game server, protocol 2: login, lobby socket, encrypted UDP fights | `stress reach 127.0.0.1:4001 --vus 100` |
| `http` / `https` | Websites and APIs, with steps, logins and captured values | `stress http https://example.com/ --rate 100` |
| `ws` / `wss` | WebSocket services | `stress ws ws://host/socket --vus 500 --pace 1s` |

No Hex packages. A new target is one Elixir module (see [Writing a target](#writing-a-target)).

## Run it

**Start with [CHEATSHEET.md](CHEATSHEET.md):** what to run from the IEx shell
(`iex -S mix`, then `help()`), how to read a report, and how to turn one into an
HTML page with charts (`html(r)` in the shell, `--html FILE` on the command line).

**Or click:** `mix stress dashboard` (or `dashboard()` in the shell) serves a page at
<http://127.0.0.1:4100> with:
- a button for each Reach test, and the player count, steps, length and checks to set
- live tiles and charts each second: players, round trip, server tick, snapshots,
  bandwidth in KB/s or Mbps, errors
- the result in plain words, with the full report one click away

It listens on 127.0.0.1 only, since anyone who can reach it can start load.

```sh
mix stress reach 127.0.0.1:4001 --vus 100 --ramp 10s --duration 1m   # from this directory
mix escript.build                                                     # makes ./stress, which runs anywhere Erlang is installed
./stress help                                                         # every option
./stress help reach                                                   # the options one target adds
```

Exit status: **0** passed, **1** a check or threshold failed, **2** it could not start. So it drops into a
build pipeline as it is.

## The load

A run is users doing iterations. One iteration is whatever the target says: one request, one message, one
game tick.

| You want | Say | Meaning |
| --- | --- | --- |
| N users, held | `--vus 100 --duration 1m` | Each user does iterations one after another. A slow server slows them down, as it would real people. |
| A rate, held | `--rate 500 --duration 1m` | Iterations *start* 500 a second whatever the server does, like traffic arriving. If every user is busy it counts `dropped`. |
| A ramp | `--ramp 30s` | Climb in a straight line from nothing first. |
| A shape | `--stages 30s:100,2m:100,30s:0` | Users along a line (`:100`), or a rate (`:200/s`). |
| A tick | `--pace 33ms` | One iteration every 33 ms per user. The Reach target defaults to this. |
| A pause | `--think 1s` | One second of nothing after each iteration. |
| Gentle starts | `--spawn-rate 20` | Start at most 20 users a second. |

Use **users** to ask "how does it feel with 1,000 players?" and a **rate** to ask "how many requests a second
can it take?".

**Where does it stop passing?** The ladder runs the same test at growing loads and stops at the first rung that
fails:

```sh
./stress ladder reach 127.0.0.1:4001 --steps 25,50,100,200,400 --duration 20s
./stress ladder http http://127.0.0.1:4001/v1/meta --by rate --steps 100,500,1000,2000
```

```text
users  iter/s   conn fail lost  snapshot   rtt          reach_tick_ms p99   tester cpu verdict
25     670      0         0     656/s      p99 2.01ms   ≤5.00ms             0.86%      PASS
100    2,676    0         0     2,624/s    p99 7.01ms   ≤20.1ms             4.94%      PASS
400    ...                                                                              FAIL
highest rung that passed: 100
first failure at 400: vu.connect_failed:count==0 (1,650)
```

`--keep-going` runs every rung anyway, `--settle 10s` lets the server rest between rungs, `--must-pass 200` makes the
exit status 1 unless a rung of at least 200 passed (for a build pipeline).

## Judging: thresholds and checks

A threshold is a rule on one number. If any fails, the run fails.

```sh
./stress http http://127.0.0.1:4001/v1/meta --rate 500 --duration 30s \
  --threshold 'http.req:p99<250ms' --threshold 'iterations.failed:ratio<1%'
```

```text
http.req:p99 < 250ms        percentiles: p50 p90 p95 p99 p99.9 (any pNN), min, max, mean
iterations.failed:ratio<1%  failed out of all iterations
vu.connect_failed == 0      a counter (count is the default)
reach.snapshot:rate > 1000  per second over the run
server.reach_tick_ms:p99 < 33ms   a number from the server's own /metrics (below)
```

Each target brings sensible defaults; `--threshold none` drops them.

**Checks** are one-off correctness tests that run first, while the server is quiet. A load test that passes
against a server that can't log anyone in is worth nothing, so these say so first.
`--checks default|all|none|name,name`.

## What the report tells you

```text
users       100 started, 100 connected, 0 failed, 0 lost   connect p50 20.1ms  p99 72.2ms
iterations  83,253 (2,775/s), 0 failed

                          count       rate        p50        p90        p99        max
reach.rtt                81,583    2,719/s     2.01ms     5.02ms     8.03ms     21.0ms
...
server      http://127.0.0.1:4010/metrics
  reach_tick_ms     935 samples   p50 ≤5.02ms  p90 ≤9.98ms  p99 ≤20.1ms  max ≤20.1ms
  reach_udp_drops   3 (unchanged)
tester      peak 100 users, cpu peak 4.83%, run queue peak 33, lag p99 3.79ms
```

- **Times are real, not averaged**: percentiles come from log-scale histograms (within 1 % of exact) that
  merge across users and machines without keeping every sample.
- **`tester` line**: the tester's own CPU and how late it ran its clock. If it says it was busy, the server may
  be better than these numbers. Trust nothing about a server from a tester that was itself overloaded.
- **`server` section**: before and after the load, it reads the server's own Prometheus-style `/metrics` and
  shows what changed. Tick times that ran long and packets the server dropped are invisible from outside, and
  the Reach target reads them by default (`--scrape off` to skip; `--scrape URL` for any other server;
  `--metrics-token` when `/metrics` is not on the same machine). Histogram percentiles are the upper edge of
  their bucket ("at most").
- **`--out run.json`** writes everything, including a point per second (`timeline`), for graphs and for
  comparing runs.

## Scenario files

Anything on the command line can live in a JSON file (command-line options win). An unknown key is an error,
so a typo can't silently run the wrong test.

```json
{
  "target": "http", "url": "http://127.0.0.1:4001", "vus": 20, "duration": "30s", "pace": "100ms",
  "setup": [
    {"name": "login", "method": "POST", "path": "/v1/auth/login",
     "json": {"account": "vigil-{{vu:4}}", "password": "stress"},
     "expect": {"status": 200}, "capture": {"token": "access_token"}}
  ],
  "steps": [
    {"name": "me", "path": "/v1/me", "headers": {"authorization": "Bearer {{token}}"},
     "expect": {"status": 200, "contains": "vigil-"}},
    {"name": "fronts", "path": "/v1/fronts"}
  ],
  "thresholds": ["http.req:p99<100ms"]
}
```

`setup` runs once per user, `steps` every iteration. Holes in strings: `{{vu}}`, `{{vu:4}}` (padded),
`{{iteration}}`, `{{rand:100}}`, `{{uuid}}`, `{{now}}`, `{{env:NAME}}`, and anything a step captured.
A capture is a JSON path (`data.items.0.id`) or `header:etag`.

## More than one machine

One machine is often not enough, and numbers are worse when the tester shares a machine with the server
(the Reach server and 1,000 bots on one box fight over the same cores). On each extra machine:

```sh
./stress agent --self agent1@10.0.0.6 --cookie some-long-secret
```

Then from anywhere: `./stress reach server:4001 --vus 5000 --agents agent1@10.0.0.6,agent2@10.0.0.7
--cookie some-long-secret` (add `--no-local` to keep users off the machine you type on). Users and rates are
split evenly; numbers come back to one report. The run refuses to start if an agent runs a different build.
Erlang distribution is not encrypted: private network, long cookie.

For tens of thousands of users per machine raise the VM limits: `ERL_FLAGS="+P 2000000"` and `ulimit -n`.

## The Reach target

Each user is a bot named `vigil-0001`, `accord-0001`, … (sides alternate) that does what a player does:

1. `POST /v1/auth/login` (retrying `slow_down` and `busy` the way a client would)
2. opens the lobby WebSocket and says `hello`, keeping it open: pings, pushes, the next seat
3. asks for a seat (`battle.join` for `--place`, or `mm.queue` with `--mode queue`)
4. connects over UDP with the ticket, answers the accept, then every tick sends an input, decodes the delta
   snapshot against the baseline it acked, acks reliable messages, follows corrections, walks at the nearest
   enemy and shoots
5. when the battle ends, goes back to the lobby and takes another seat

The server must have stress logins on (dev has them; elsewhere `REACH_STRESS=1`). The bot password is
`stress`. Names ending `-9990` to `-9998` belong to the checks.

```sh
./stress reach 127.0.0.1:4001 --vus 100                    # a 50 v 50 on crystal-gate/r1
./stress reach 127.0.0.1:4001 --vus 1000 --per-place 100   # ten battles, r1 to r10
./stress reach 127.0.0.1:4001 --vus 400 --mode queue       # let the matchmaker place them
./stress reach 127.0.0.1:4001 --vus 20 --chat 2s           # exercise the reliable lane
```

What it measures that matters:

- `reach.rtt`: round trip from your input to the snapshot that echoes it
- `reach.snapshot_loss`: of the snapshots the server numbered, how many never arrived. This is exact (from the
  server's tick numbers, not a clock). It sees the server→player direction only; packets lost the other way
  show in the `server` section (`reach_udp_in` against the tester's `reach.packets_out`).
- `reach.snapshot_bytes`, `reach.udp_connect` (ticket → accept), `reach.lobby_rtt`, `reach.login`
- `reach.correct.N`: how often the server moved a bot (1 too fast, 2 spawn, 3 wall, 4 bounds, 5 rise)
- `reach.hit`, `reach.kill`, `reach.death`, `reach.chat_heard`

Checks: `health meta bad-password unauthenticated login refresh-rotation lobby bad-hello fight replace`, and
`rejoin` under `--checks all` (go quiet, come back, find the same body where it was left; takes ~9 s).

**The protocol is written out twice** (the server's `lib/reach/packet.ex`, and `lib/stress_tester/reach/wire.ex`
here), so `test/stress_tester/reach/wire_test.exs` runs this side against the server's own encoders: sealing,
inputs, delta snapshots (with skipped entities and loss), and the reliable lane through a channel that loses,
repeats and reorders. If the wire format changes on one side, that test fails first.

## Testing the Reach backend: a runbook

Ready-made runs are in `scenarios/`. Each is a JSON file (`./stress scenarios/NAME.json HOST:PORT`); anything on
the command line overrides it, so `--vus 50` or `--duration 10s` makes any of them smaller.

**1. Get the server on the protocol-2 code and start it**

```sh
cd ../the_reach_backend && git pull
REACH_UDP_RECEIVERS=4 iex -S mix          # dev: port 4001/4002, stress logins on, cheap password hashing
```

Set `REACH_UDP_RECEIVERS` (the default of 1 was the first thing to break at 1,000 players). For numbers that
include real password hashing, run it the way production does:

```sh
MIX_ENV=prod REACH_SECRET=$(openssl rand -hex 32) REACH_BEHIND_PROXY=1 REACH_STRESS=1 \
  REACH_UDP_RECEIVERS=4 mix run --no-halt
```

`REACH_STRESS=1` lets the bots in; never on a public box.

**2. Work up, in this order**

| Step | Command | What it tells you |
| --- | --- | --- |
| Does anything work? | `./stress scenarios/reach-smoke.json 127.0.0.1:4001` | Every check passes, four bots fight. About 25 s. Fix this before anything else. |
| The case it is built for | `./stress scenarios/reach-50v50.json 127.0.0.1:4001` | One full battle for a minute. Round trip, snapshot loss, and the server's own tick time against its 33 ms budget. |
| Where does it stop? | `./stress ladder reach 127.0.0.1:4001 --steps 25,50,100,200,400,800` | The highest player count that still passes. |
| The HTTP door | `./stress scenarios/reach-api.json 127.0.0.1:4001` | 50 players asking who they are, the war map, the catalog. |
| A patch day | `./stress scenarios/reach-login-storm.json 127.0.0.1:4001` | 100 logins a second. Run it on the production-style server; dev hashing is ~30 times cheaper. |
| The matchmaker | `./stress scenarios/reach-queue.json 127.0.0.1:4001` | 400 players placed by the queue instead of sent to one place. |
| Ten battles | `./stress scenarios/reach-war.json SERVER:4001 --agents BOTBOX@10.0.0.6 --no-local --cookie X` | 1,000 players. See below: needs a second machine. |
| Overnight | `./stress scenarios/reach-soak.json 127.0.0.1:4001` | Thirty minutes of 100 players with chat; writes `soak-report.json`. |

**3. Reading a Reach run**

Look at these first, in this order:

1. **`checks`**: if any fail, nothing else matters yet.
2. **`vu.connect_failed` and the `errors` list**: `no_accept` means the server never answered the UDP connect in
   5 s (overloaded, or the UDP port is unreachable); `login: 503` means password hashing was full.
3. **`server` → `reach_tick_ms`**: the fight loop's own timing. Its budget is 33 ms; `p99 ≤33ms` is healthy.
   Anything higher means the game ran in slow motion for someone, even if nothing "failed".
4. **`reach.rtt`**: what a player feels. Under about 100 ms p99 is fine on one machine.
5. **`reach.snapshot_loss`**: the server's updates that never arrived. Loss in the other direction (a player's
   inputs lost) is `reach_udp_in` falling short of the tester's `reach.packets_out`.
6. **`tester cpu` and `lag`**: if the tester says it was busy, the server's numbers are better than they look.

**4. One machine is a lie.** The server and 1,000 bots share the same cores, so past a few hundred bots
you are measuring the box, not the server. Put the bots elsewhere: run `./stress agent --self a@10.0.0.6 --cookie X`
there (copy the single `stress` file; it only needs Erlang), then add `--agents a@10.0.0.6 --no-local --cookie X`.
Also check the UDP port is open between them, and set `REACH_ADVERTISE_HOST` on the server to its real address,
or the ticket will tell the bots to send UDP to `127.0.0.1` (the `fight` check says so in words).

**What the first real runs showed** (1,000 bots and the server on one 16-core box, so pessimistic): a single UDP
receiver lost about half the players' packets in the kernel and left 1,650 of 2,584 connections without an accept;
four receivers cut that to 264. With production password hashing the login door held about 43 logins a second
before answering `503 busy`.

## Writing a target

```elixir
defmodule MyTarget do
  @behaviour StressTester.Target
  alias StressTester.Metrics

  def init(opts), do: {:ok, %{host: opts[:address]}}      # once, before any user; plain data only
  def connect(shared, vu), do: {:ok, %{host: shared.host, vu: vu}}
  def iterate(state) do
    Metrics.time("my.call", fn -> do_the_thing(state) end)
    {:ok, state}                                           # or {:error, why, state} | {:stop, why, state}
  end
  def disconnect(_state), do: :ok
end
```

Run it with `StressTester.run(target: MyTarget, vus: 10)` or `--target Elixir.MyTarget`. Optional callbacks:
`options/0` (command-line switches), `defaults/1`, `describe/1`, `checks/2`, `handle_message/2` (socket
messages between iterations), `derive/2` (numbers worked out from the totals, usable in thresholds),
`scrape/1` (where the server publishes its metrics). A crash inside a target ends that user and is reported
with the line it came from; it never takes the run down. `Metrics.count/observe/time/error` are the whole
vocabulary.

## Tests

```sh
mix test            # about 230 tests; real HTTP, WebSocket, TLS and UDP; boots a Reach server in the test VM
mix test --cover    # fails under 85 %
```

The Reach server is a **test-only dependency**, `../the_reach_backend` by default. It must be on the
protocol-2 code (the rebuilt server), so `git pull` there first or point `REACH_BACKEND=/path/to/checkout` at
a checkout that is. The tests include an Erlang node started as a second "machine" (needs `epmd`; they skip
without it).

Since the Reach server keeps its war and match history in Postgres
([reach_backend#2](https://github.com/Lex-Dellimere/reach_backend/pull/2)), **Postgres must be running for
`mix test`**. The backend's `docker-compose.yml` starts one on `localhost:5432` that works as it is:

```sh
cd ../the_reach_backend && docker-compose up -d
```

The tests create and migrate their own database, `reach_stress_test`, apart from the backend's dev and test
databases. For a Postgres elsewhere, set `REACH_TEST_DATABASE_URL=ecto://user:pass@host:5432/reach_stress_test`;
the user needs the right to create databases.

## Limits worth knowing

- **Timing depends on the tester having cores to spare.** Read the `tester` line, and when you can, run the bots on a different machine from the server.
- A bot decodes every snapshot (about 33 µs each, one core per ~1,000 bots). That is deliberate: it is how
  decode errors are found.
- Reach bots walk and shoot inside the movement envelope; they do not use abilities, grenades or the store.
- HTTP is HTTP/1.1 with keep-alive; there is no HTTP/2 or HTTP/3 client.
- In the `server` section, a histogram published with extra labels (beyond `le`) is merged across them.
