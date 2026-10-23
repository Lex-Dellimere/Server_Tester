defmodule StressTester.Reach.FightTest do
  use ExUnit.Case, async: true

  alias Reach.Packet
  alias StressTester.Metrics
  alias StressTester.Reach.Fight

  @key :crypto.strong_rand_bytes(32)

  # a fight with a socket of its own, pointed at nowhere, for feeding packets by hand
  defp fight(extra \\ []) do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])

    struct!(
      Fight,
      [
        sock: sock,
        ip: {127, 0, 0, 1},
        port: 9,
        key: @key,
        slot: 3,
        every: 1,
        lane: StressTester.Reach.Lane.new(),
        tick_ms: 33
      ] ++ extra
    )
  end

  defp snapshot(tick, seq, base \\ 0) do
    head = %{tick: tick, base: base, input_tick: tick, echo_ms: 0, hold_ms: 0, ack: {1, 0}}
    {delta, _held, _n} = Reach.Snapshot.encode(nil, [], 1_000)
    plain = Packet.pack_snapshot(head, nil, delta)
    Packet.seal(@key, 4, 3, seq, 1, plain)
  end

  test "snapshots are counted by what the server numbered, so a gap is a loss" do
    f = fight()
    # ticks 10, 11, 13, 14 arrive; 12 does not
    f =
      Enum.reduce([{10, 1}, {11, 2}, {13, 3}, {14, 4}], f, fn {tick, seq}, f ->
        assert {:ok, f} = Fight.packet(f, snapshot(tick, seq))
        f
      end)

    assert f.snap_got == 4 and f.snap_first == 10 and f.snap_max == 14
    Fight.account(f)
    c = Metrics.take().c
    assert c["reach.snapshot_expected"] == 5
    assert c["reach.snapshot_lost"] == 1
  end

  test "with a snapshot every second tick the gaps are two apart" do
    f = fight(every: 2)

    f =
      Enum.reduce([{10, 1}, {12, 2}, {14, 3}], f, fn {tick, seq}, f ->
        elem(Fight.packet(f, snapshot(tick, seq)), 1)
      end)

    Fight.account(f)
    c = Metrics.take().c
    assert c["reach.snapshot_expected"] == 3
    assert c["reach.snapshot_lost"] in [nil, 0]
  end

  test "a repeated packet is dropped by the replay window, not counted twice" do
    f = fight()
    {:ok, f} = Fight.packet(f, snapshot(10, 1))
    {:ok, f} = Fight.packet(f, snapshot(10, 1))
    assert f.snap_got == 1
    assert Metrics.take().c["reach.duplicate"] == 1
  end

  test "packets from a stranger, or damaged, are counted and ignored" do
    f = fight()

    assert {:ok, ^f} =
             Fight.packet(f, Packet.seal(:crypto.strong_rand_bytes(32), 4, 3, 1, 1, "x"))

    assert {:ok, ^f} = Fight.packet(f, <<1, 2, 3>>)
    assert Metrics.take().c["reach.bad_packet"] == 2
  end

  test "a snapshot against a baseline we never had is an error, not a guess" do
    f = fight()
    assert {:ok, f} = Fight.packet(f, snapshot(20, 1, 15))
    assert f.counts.decode_errors == 1 and f.snap_got == 0
    assert Metrics.take().c["reach.decode_error"] == 1
  end

  test "bye ends the fight with its reason" do
    f = fight()

    assert {:bye, :replaced, _} =
             Fight.packet(f, Packet.seal(@key, 7, 3, 1, 1, Packet.pack_bye(2)))

    assert {:bye, :closed, _} = Fight.packet(f, Packet.seal(@key, 7, 3, 2, 1, Packet.pack_bye(5)))
  end

  test "a correction moves the bot to where the server says" do
    f = fight()
    payload = Packet.correct(5, {100, 20, -300}, {0, 0, 0}, 3)
    reliable = Packet.pack_reliable({1, 0}, [{1, payload}]) |> IO.iodata_to_binary()
    assert {:ok, f} = Fight.packet(f, Packet.seal(@key, 5, 3, 1, 1, reliable))
    assert f.pos == {100, 20, -300}
    assert f.counts.corrections == 1
    c = Metrics.take().c
    assert c["reach.correct.3"] == 1
  end

  test "an input is sealed so the server can read it, and ticks only go up" do
    f = fight(latest: 100)
    {:ok, server} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(server)
    f = %{f | port: port}
    fields = %{x: 1, y: 2, z: 3, vx: 0, vy: 0, vz: 0, yaw: 5, pitch: 6, buttons: 1}

    f = Fight.input(f, fields)
    f = Fight.input(f, %{fields | x: 2})
    {:ok, {_, _, first}} = :gen_udp.recv(server, 0, 1_000)
    {:ok, {_, _, second}} = :gen_udp.recv(server, 0, 1_000)

    assert {:ok, 4, 3, 1, plain1} = Packet.open(@key, 0, first)
    assert {:ok, 4, 3, 2, plain2} = Packet.open(@key, 0, second)
    {:ok, in1} = Packet.unpack_input(plain1)
    {:ok, in2} = Packet.unpack_input(plain2)
    assert [%{tick: 102, x: 1}] = in1.frames
    # the second packet repeats the first frame for loss cover, newest first
    assert [%{tick: 103, x: 2}, %{tick: 102, x: 1}] = in2.frames
    assert f.pos == {2, 2, 3}
  end

  test "a reliable message is resent until it is acked" do
    f = fight()
    {:ok, server} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(server)
    f = %{f | port: port}

    f = Fight.say(f, <<1, 2, "hi">>, 0)
    assert {:ok, {_, _, _first}} = :gen_udp.recv(server, 0, 1_000)
    assert StressTester.Reach.Lane.pending(f.lane) == 1
    f = Fight.resend(f, 10_000)
    assert {:ok, {_, _, _again}} = :gen_udp.recv(server, 0, 1_000)
    assert Metrics.take().c["reach.resend"] == 1
    _ = f
  end
end
