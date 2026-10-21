import Config

config :logger, level: :warning

config :the_reach_backend,
  secret: "dev-only-change-me",
  port: 0,
  udp_port: 0,
  pbkdf2_iters: 1,
  stress_login: true,
  wal_path: Path.join(System.tmp_dir!(), "reach-stress-test.wal"),
  tick_ms: 33,
  war_tick_ms: 3_600_000,
  certfile: nil,
  keyfile: nil
