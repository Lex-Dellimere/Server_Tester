defmodule StressTesterTest do
  use ExUnit.Case, async: false

  test "the reach profile splits workers into two groups" do
    names = StressTester.Reach.names(100)
    assert length(names) == 100
    assert Enum.count(names, &String.starts_with?(&1, "accord-")) == 50
    assert Enum.count(names, &String.starts_with?(&1, "vigil-")) == 50
  end

  test "percentiles pick a rank from sorted samples" do
    assert StressTester.Report.percentile([30, 10, 20], 50) == 20
    assert StressTester.Report.percentile([], 99) == nil
  end

  test "tcp workers load any listening socket" do
    port = echo()

    report =
      StressTester.run(
        profile: StressTester.Tcp,
        host: "127.0.0.1",
        port: port,
        workers: 2,
        seconds: 1,
        hz: 5,
        stagger_ms: 0
      )

    assert report.joined == 2
    assert report.kinds["messages"].received > 0
    assert report.reconnect
    assert report.ok
  end

  test "the reach profile carries snapshots and same-side chat" do
    report =
      StressTester.run(
        host: "127.0.0.1",
        port: Reach.Login.port(),
        players: 4,
        seconds: 1,
        hz: 5,
        chat_ms: 200
      )

    assert report.joined == 4
    assert report.kinds["state"].received > 0
    assert report.kinds["chat"].received > 0
    assert report.auth_rejected
    assert report.reconnect
    assert report.ok
  end

  defp echo do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen) end)
    port
  end

  defp accept(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        spawn(fn -> reply(sock) end)
        accept(listen)

      _ ->
        :ok
    end
  end

  defp reply(sock) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        :gen_tcp.send(sock, data)
        reply(sock)

      _ ->
        :gen_tcp.close(sock)
    end
  end
end
