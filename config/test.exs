import Config

config :logger, level: :warning

# The Reach server the tests boot inside this VM. It is a test-only dependency,
# so its own config files are not read; these are the settings it runs with.
config :the_reach_backend,
  secret: "stress-tester-test-secret-0123456789",
  port: 0,
  udp_port: 0,
  bind: "127.0.0.1",
  advertise_host: "127.0.0.1",
  pbkdf2_iters: 1,
  stress_login: true,
  seed_accounts: false,
  data_dir: Path.join(System.tmp_dir!(), "stress-tester-reach-#{System.os_time(:millisecond)}"),
  journal_sync_ms: 20,
  war_tick_ms: 3_600_000,
  swarm_count: 2,
  end_ms: 0,
  kick_wait_ms: 300,
  hello_ms: 2_000,
  idle_ms: 1_000,
  idle_check_ms: 200,
  regions: ["r1", "r2", "r3", "r4"],
  slot_max: 10_000,
  server_cap: 10_000
