defmodule StressTester.TlsTest do
  use ExUnit.Case, async: true

  alias StressTester.{Http, Net}
  alias StressTester.Test.TinyServer

  @answer "HTTP/1.1 200 OK\r\ncontent-length: 6\r\n\r\nsecure"

  test "an unknown certificate authority is refused by default" do
    {port, _conns, _ca} = TinyServer.start_tls(fn _req, _n -> {:reply, @answer} end)
    {:ok, origin} = Net.origin("https://127.0.0.1:#{port}/")

    assert {:error, _conn, {:tls, reason}} =
             Http.request(Http.new(origin, %{}), "GET", "/", [], nil, 3_000)

    assert inspect(reason) =~ "unknown_ca" or inspect(reason) =~ "certificate"
  end

  test "--insecure talks to it anyway, and times the handshake" do
    {port, conns, _ca} = TinyServer.start_tls(fn _req, _n -> {:reply, @answer} end)
    {:ok, origin} = Net.origin("https://127.0.0.1:#{port}/")
    conn = Http.new(origin, %{insecure: true})

    assert {:ok, conn, resp} = Http.request(conn, "GET", "/", [], nil, 3_000)
    assert resp.body == "secure"
    assert resp.tls_us > 0 and resp.connect_us > 0

    # the second request reuses the secure connection
    assert {:ok, _conn, resp2} = Http.request(conn, "GET", "/", [], nil, 3_000)
    assert resp2.body == "secure"
    refute Map.has_key?(resp2, :tls_us)
    assert TinyServer.connections(conns) == 1
  end

  test "the HTTP target runs over TLS" do
    {port, _conns, _ca} = TinyServer.start_tls(fn _req, _n -> {:reply, @answer} end)

    {:ok, r} =
      StressTester.run(
        target: "http",
        url: "https://127.0.0.1:#{port}/x",
        insecure: true,
        vus: 2,
        duration: "1s",
        pace: "100ms",
        silent: true,
        threshold: ["http.status.200:count>10"]
      )

    assert r.ok
    assert r.metrics["http.tls"]["count"] == 2

    {:ok, r} =
      StressTester.run(
        target: "http",
        url: "https://127.0.0.1:#{port}/x",
        vus: 1,
        duration: "500ms",
        pace: "100ms",
        silent: true,
        threshold: ["none"]
      )

    assert r.counters["iterations.failed"] >= 1
    assert Enum.any?(r.errors, &(&1["reason"] =~ "tls"))
  end
end
