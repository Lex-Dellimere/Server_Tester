defmodule StressTester.Reach.WireTest do
  use ExUnit.Case, async: true

  # The tester speaks the Reach protocol from its own code. These tests run it
  # against the server's encoders and decoders, so a change to the wire format
  # on either side shows up here first.

  alias Reach.{Packet, Snapshot}
  alias StressTester.Reach.Snapshot, as: Mine
  alias StressTester.Reach.Wire

  @key :crypto.strong_rand_bytes(32)

  test "a packet we seal, the server opens (and the other way round)" do
    sealed = Wire.seal(@key, 4, 77, 5, 0, "hello")
    assert {:ok, 4, 77, 5, "hello"} = Packet.open(@key, 0, sealed)

    from_server = Packet.seal(@key, 5, 77, 9, 1, "world")
    assert {:ok, 5, 77, 9, "world"} = Wire.open(@key, 1, from_server)
  end

  test "the direction is part of the key stream" do
    sealed = Wire.seal(@key, 4, 1, 1, 0, "x")
    assert :error = Wire.open(@key, 1, sealed)
    assert :error = Wire.open(@key, 0, binary_part(sealed, 0, byte_size(sealed) - 1))
    assert :error = Wire.open(:crypto.strong_rand_bytes(32), 0, sealed)
    assert :error = Wire.open(@key, 0, <<1, 2>>)
  end

  test "the connect packet is plain: header and ticket" do
    assert Wire.pack(1, 0, 0, "ticket") == Packet.pack(1, 0, 0, "ticket")
    assert {:ok, 1, 0, 0, "ticket"} = Wire.unpack(Packet.pack(1, 0, 0, "ticket"))
  end

  test "accept and deny" do
    accept = Packet.pack_accept(12, 3_456, 33, 1, "crystal-gate/r1", true)

    assert {:ok,
            %{
              slot: 12,
              tick: 3_456,
              tick_ms: 33,
              every: 1,
              place: "crystal-gate/r1",
              rejoin: true
            }} = Wire.unpack_accept(accept)

    assert :error = Wire.unpack_accept(<<1, 2, 3>>)
    assert {:ok, 3} = Wire.unpack_deny(Packet.pack_deny(3))
    assert Wire.deny_reason(2) == :used
  end

  test "an input the server can read" do
    frame = fn tick, x ->
      %{
        tick: tick,
        view_tick: tick - 2,
        x: x,
        y: -50,
        z: 70_000,
        vx: 100,
        vy: -5,
        vz: 40_000,
        yaw: 65_535,
        pitch: -16_384,
        posture: 1,
        weapon: 1,
        buttons: 0b101
      }
    end

    frames = [frame.(12, 100), frame.(11, 90), frame.(10, 80)]
    plain = Wire.pack_input(9, 123_456, {5, 0b1010}, frames) |> IO.iodata_to_binary()

    assert {:ok, input} = Packet.unpack_input(plain)
    assert input.ack_snap == 9
    assert input.client_ms == 123_456
    assert input.ack == {5, 0b1010}

    assert [
             %{
               tick: 12,
               x: 100,
               y: -50,
               z: 70_000,
               yaw: 65_535,
               pitch: -16_384,
               posture: 1,
               weapon: 1,
               buttons: 5
             },
             _,
             _
           ] = input.frames

    # velocity is clamped to 16 bits the same way on both sides
    assert hd(input.frames).vz == 32_767
  end

  test "reliable framing in both directions" do
    messages = [{1, "one"}, {2, <<2, 0, 9>>}, {65_535, ""}]
    ours = Wire.pack_reliable({3, 4}, messages) |> IO.iodata_to_binary()
    assert {:ok, {3, 4}, ^messages} = Packet.unpack_reliable_packet(ours)

    theirs = Packet.pack_reliable({7, 8}, messages) |> IO.iodata_to_binary()
    assert {:ok, {7, 8}, ^messages} = Wire.unpack_reliable(theirs)

    assert {:ok, {6, 0b11}} = Wire.unpack_ack(Packet.pack_ack({6, 0b11}))
    assert Wire.pack_ack({6, 0b11}) == Packet.pack_ack({6, 0b11})
    assert :error = Wire.unpack_reliable(<<1, 2, 3>>)
    assert Wire.pack_bye(4) == Packet.pack_bye(4)
    assert Wire.bye_reason(2) == :replaced
  end

  test "what the server says over the reliable lane is understood" do
    assert {:event, %{kind: 1, a: 4, b: 9, value: 35, extra: 1}} =
             Wire.read_server(Packet.event(:hit, 100, 4, 9, 35, 1))

    assert {:event, %{kind: 8, a: 9, b: 4}} =
             Wire.read_server(Packet.event(:kill, 100, 9, 4, 0, 1))

    assert {:correct, %{tick: 50, pos: {-10, 20, 30}, vel: {1, 2, 3}, reason: 2}} =
             Wire.read_server(Packet.correct(50, {-10, 20, 30}, {1, 2, 3}, 2))

    assert {:chat, %{channel: 0, from: 3, name: "accord-0001", text: "hi"}} =
             Wire.read_server(Packet.chat(0, 3, "accord-0001", "hi"))

    assert {:result, _} = Wire.read_server(Packet.result(%{"winner" => "vigil"}))
    assert {:other, 8} = Wire.read_server(Packet.kit(%{}))
    assert :error = Wire.read_server(<<>>)
  end

  test "what we say over the reliable lane is understood by the server" do
    assert Wire.say_team("hello team") == Packet.say_team("hello team")
    assert {:chat, "hello team"} = Packet.read_client(Wire.say_team("hello team"))
    assert Wire.spawn_request(2) == Packet.spawn_request(2)
    assert {:spawn, 2} = Packet.read_client(Wire.spawn_request(2))
  end

  test "the snapshot head" do
    me = %{
      weapon: 1,
      ammo: 90,
      magazine: 30,
      reload_cs: 12,
      ability_cs: 0,
      grenade_cs: 500,
      respawn_cs: 0,
      dead: false,
      can_spawn: true
    }

    head = %{
      tick: 1_000,
      base: 990,
      input_tick: 998,
      echo_ms: 4_000_000_000,
      hold_ms: 3,
      ack: {9, 0b11}
    }

    data = Packet.pack_snapshot(head, me, <<0, 0, 0, 0>>) |> IO.iodata_to_binary()

    assert {:ok, got} = Wire.unpack_snapshot(data)

    assert %{
             tick: 1_000,
             base: 990,
             input_tick: 998,
             echo_ms: 4_000_000_000,
             hold_ms: 3,
             ack: {9, 3}
           } = got

    assert %{
             weapon: 1,
             ammo: 90,
             magazine: 30,
             reload_cs: 12,
             grenade_cs: 500,
             dead: false,
             can_spawn: true,
             no_body: false
           } = got.me

    assert got.delta == <<0, 0, 0, 0>>

    bodiless = Packet.pack_snapshot(head, nil, <<>>) |> IO.iodata_to_binary()
    assert {:ok, %{me: %{no_body: true}}} = Wire.unpack_snapshot(bodiless)
    assert :error = Wire.unpack_snapshot(<<1, 2, 3>>)
  end

  # -- entity deltas

  defp entity(id, rand) do
    %{
      id: id,
      kind: Enum.random([1, 2, 3, 4]),
      team: Enum.random([0, 1, 2, 3]),
      x: :rand.uniform(200_000) - 100_000,
      y: :rand.uniform(5_000),
      z: :rand.uniform(200_000) - 100_000,
      vx: :rand.uniform(1_000) - 500,
      vy: 0,
      vz: :rand.uniform(1_000) - 500,
      yaw: :rand.uniform(65_536) - 1,
      pitch: :rand.uniform(32_768) - 16_385,
      hp: rand.(100),
      shield: rand.(50),
      max_hp: 100,
      max_shield: 50,
      posture: rand.(5),
      flags: rand.(255),
      weapon: rand.(1),
      progress: rand.(10_000)
    }
  end

  # move some, hurt some, drop some, add some
  defp step(entities, tick) do
    entities
    |> Enum.reject(fn _ -> :rand.uniform(30) == 1 end)
    |> Enum.map(fn e ->
      case :rand.uniform(4) do
        1 -> %{e | x: e.x + :rand.uniform(50), z: e.z - 10, yaw: rem(e.yaw + 100, 65_536)}
        2 -> %{e | hp: max(e.hp - 7, 0), flags: Bitwise.bxor(e.flags, 4)}
        3 -> %{e | posture: rem(e.posture + 1, 6), weapon: 1 - e.weapon, progress: e.progress + 1}
        _ -> e
      end
    end)
    |> Kernel.++(if rem(tick, 7) == 0, do: [entity(1_000 + tick, &:rand.uniform(&1))], else: [])
  end

  test "deltas written by the server read back to what the server says we hold" do
    :rand.seed(:exsss, {7, 7, 7})
    rand = &(:rand.uniform(&1 + 1) - 1)
    start = for id <- 1..40, do: entity(id, rand)

    # the server's record of what it sent, and the client's of what it decoded, by tick
    {_, _, _} =
      Enum.reduce(1..60, {start, %{}, %{}}, fn tick, {entities, server, client} ->
        entities = if tick == 1, do: entities, else: step(entities, tick)
        # the client acks the newest tick it has, but only every third snapshot arrives
        acked = client |> Map.keys() |> Enum.max(fn -> 0 end)
        base_server = Map.get(server, acked)
        base_client = Map.get(client, acked)
        budget = if rem(tick, 9) == 0, do: 300, else: 1_100

        {delta, held, _written} = Snapshot.encode(base_server, entities, budget)
        data = IO.iodata_to_binary(delta)

        assert {:ok, decoded} = Mine.decode(data, base_client)

        assert decoded == held,
               "tick #{tick}: the client's picture differs from the server's record"

        # and ours agrees with the server's own decoder
        assert {:ok, ^decoded} = Snapshot.decode(data, base_client)

        client = if rem(tick, 3) == 0, do: client, else: Map.put(client, tick, decoded)
        {entities, Map.put(server, tick, held), client}
      end)
  end

  test "a truncated or padded delta is refused, not guessed at" do
    {delta, _, _} = Snapshot.encode(nil, [entity(1, &:rand.uniform(&1))], 1_000)
    data = IO.iodata_to_binary(delta)
    assert {:ok, _} = Mine.decode(data, nil)
    assert :error = Mine.decode(binary_part(data, 0, byte_size(data) - 3), nil)
    assert :error = Mine.decode(data <> <<0>>, nil)
    assert :error = Mine.decode(<<>>, nil)
  end

  test "an entity that left is removed from the picture" do
    {first, held1, _} =
      Snapshot.encode(nil, [entity(1, &:rand.uniform(&1)), entity(2, &:rand.uniform(&1))], 1_000)

    assert {:ok, base} = Mine.decode(IO.iodata_to_binary(first), nil)
    assert Map.keys(base) |> Enum.sort() == [1, 2]

    {second, _, _} = Snapshot.encode(held1, [entity(1, &:rand.uniform(&1))], 1_000)
    assert {:ok, after_} = Mine.decode(IO.iodata_to_binary(second), base)
    assert Map.keys(after_) == [1]
  end
end
