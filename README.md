# Stress tester

A worker runner for network services. It does not know a game. A profile does.

There are two profiles:

- `StressTester.Reach` logs into the sibling Reach server over TCP, then sends UDP. `mix stress` uses this.
- `StressTester.Tcp` writes one line at a time to any open TCP port and counts the replies.

No Hex packages. The Reach server is a path dependency for `mix test` only, so the Reach profile can boot that server in the test VM.

## Reach

Start the server first, from `the_reach_backend`:

```sh
iex -S mix
```

Dev listens on TCP 4001 and UDP 4002, and stress logins are on. Then, from this directory:

```sh
mix stress
```

That is 50 workers named `accord-01` through `accord-50` and 50 named `vigil-01` through `vigil-50`, on `crystal-gate`, for 5 seconds, at 10 messages a second. Those names are the Reach profile's accounts, not part of the runner. The password is `stress`. A public box stays closed unless `REACH_STRESS=1`.

```sh
mix stress --players 20 --seconds 5 --hz 10 --chat_ms 2000 --port 4001 --planet crystal-gate
```

`Holdfast` is not in that account list. That side cannot enter `crystal-gate`.

## Any TCP port

```sh
mix stress --profile tcp --host 127.0.0.1 --port 9000 --workers 20 --seconds 5 --hz 10
```

The payload defaults to `ping\n`. There is no login on this profile, so the auth check is treated as passed. Reconnect means a second connection still opens.

## What passes

`mix test` runs the TCP profile against a local echo, then boots the Reach server and runs 4 workers for 1 second.

A Reach run passes when every worker joins, snapshots arrive, same-side chat arrives, a bad password is rejected, and a second login replaces the first. A dropped snapshot does not fail the run. The `state` row is inputs sent and snapshots received. `chat` counts only the sender's group, including the sender.

From a shell while a server is already up:

```elixir
StressTester.run(players: 4, seconds: 1, hz: 5, chat_ms: 200)
StressTester.run(profile: StressTester.Tcp, port: 9000, workers: 4, seconds: 1)
```
