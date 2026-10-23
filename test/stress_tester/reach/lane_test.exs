defmodule StressTester.Reach.LaneTest do
  use ExUnit.Case, async: true

  # The reliable lane has two ends written separately: the server's
  # (Reach.Reliable) and the tester's (Lane). Each is run against the other
  # over a channel that loses, repeats and reorders packets.

  alias Reach.Reliable
  alias StressTester.Reach.Lane

  defp channel(rand_fun, loss, items) do
    # lose some, repeat some, then shuffle what is left
    items
    |> Enum.flat_map(fn item ->
      r = rand_fun.()

      cond do
        r < loss -> []
        r > 0.93 -> [item, item]
        true -> [item]
      end
    end)
    |> Enum.shuffle()
  end

  defp seeded(n), do: :rand.seed(:exsss, {n, n, n})

  defp rand_fun, do: fn -> :rand.uniform() end

  test "in-order receive, with gaps, repeats and the wrap at 65,535" do
    lane = %{Lane.new() | next_in: 65_534}
    {lane, a} = Lane.receive(lane, 65_535, "b")
    assert a == []
    assert {65_534, bits} = Lane.ack_state(lane)
    assert bits == 0b1

    {lane, got} = Lane.receive(lane, 65_534, "a")
    assert got == ["a", "b"]
    {lane, got} = Lane.receive(lane, 0, "c")
    assert got == ["c"]
    # a repeat is nothing
    assert {^lane, []} = Lane.receive(lane, 65_535, "b")
    assert {1, 0} = Lane.ack_state(lane)
    # far ahead is not buffered
    assert {^lane, []} = Lane.receive(lane, 5_000, "x")
  end

  test "acks free what was sent, by number and by bitmap" do
    lane = Lane.new()
    {lane, [{1, _}]} = Lane.push(lane, "a", 0)
    {lane, [{2, _}]} = Lane.push(lane, "b", 0)
    {lane, [{3, _}]} = Lane.push(lane, "c", 0)
    assert Lane.pending(lane) == 3
    # next needed is 2, and 3 is held: bit 0 of the map
    lane = Lane.acked(lane, 2, 0b1)
    assert Lane.pending(lane) == 1
    assert {_, [{2, "b"}]} = Lane.due(lane, 10_000)
  end

  test "an unacked message is resent later and later" do
    lane = Lane.new()
    {lane, _} = Lane.push(lane, "x", 0)
    assert {_, []} = Lane.due(lane, 100)
    {lane, [{1, "x"}]} = Lane.due(lane, 300)
    # the second wait is twice the first
    assert {_, []} = Lane.due(lane, 600)
    assert {_, [{1, "x"}]} = Lane.due(lane, 900)
  end

  test "the server's messages reach the tester complete and in order despite loss" do
    for seed <- 1..5, start <- [1, 65_500] do
      seeded(seed)
      payloads = for n <- 1..400, do: <<n::32>>
      server = %{Reliable.new() | next_out: start}
      lane = %{Lane.new() | next_in: start}

      {server, first} = Reliable.push_many(server, payloads, 0)
      {delivered, server, _lane} = run_server_to_client(server, lane, first, [], 0)

      assert delivered == payloads,
             "seed #{seed} start #{start}: delivered #{length(delivered)} of 400"

      assert Reliable.pending(server) == 0
    end
  end

  # one round: the packets go out, some arrive, the acks come back, time passes
  defp run_server_to_client(server, lane, out, delivered, step) when step < 4_000 do
    if Reliable.pending(server) == 0 and out == [] do
      {delivered, server, lane}
    else
      now = step * 20
      arrived = channel(rand_fun(), 0.3, out)

      {lane, got} =
        Enum.reduce(arrived, {lane, []}, fn {seq, payload}, {lane, acc} ->
          {lane, more} = Lane.receive(lane, seq, payload)
          {lane, acc ++ more}
        end)

      # the ack travels back through the same channel
      {next, bits} = Lane.ack_state(lane)

      {server, more} =
        if rand_fun().() < 0.7, do: Reliable.ack(server, next, bits, now), else: {server, []}

      {server, due} = Reliable.due(server, now)
      run_server_to_client(server, lane, more ++ due, delivered ++ got, step + 1)
    end
  end

  defp run_server_to_client(_server, _lane, _out, delivered, step),
    do: flunk("not delivered after #{step} rounds; got #{length(delivered)}")

  test "the tester's messages reach the server complete and in order despite loss" do
    for seed <- 1..5 do
      seeded(seed)
      payloads = for n <- 1..120, do: <<n::32>>

      {lane, first} =
        Enum.reduce(payloads, {Lane.new(), []}, fn p, {lane, acc} ->
          {lane, out} = Lane.push(lane, p, 0)
          {lane, acc ++ out}
        end)

      {delivered, lane} = run_client_to_server(lane, Reliable.new(), first, [], 0)
      assert delivered == payloads, "seed #{seed}: delivered #{length(delivered)} of 120"
      assert Lane.pending(lane) == 0
    end
  end

  defp run_client_to_server(lane, server, out, delivered, step) when step < 4_000 do
    if Lane.pending(lane) == 0 and out == [] do
      {delivered, lane}
    else
      now = step * 20
      arrived = channel(rand_fun(), 0.3, out)

      {server, got} =
        Enum.reduce(arrived, {server, []}, fn {seq, payload}, {server, acc} ->
          {server, more} = Reliable.receive(server, seq, payload)
          {server, acc ++ more}
        end)

      {next, bits} = Reliable.ack_state(server)
      lane = if rand_fun().() < 0.7, do: Lane.acked(lane, next, bits), else: lane
      {lane, due} = Lane.due(lane, now)
      run_client_to_server(lane, server, due, delivered ++ got, step + 1)
    end
  end

  defp run_client_to_server(_lane, _server, _out, delivered, step),
    do: flunk("not delivered after #{step} rounds; got #{length(delivered)}")
end
