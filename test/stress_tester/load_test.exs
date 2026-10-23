defmodule StressTester.LoadTest do
  use ExUnit.Case, async: true

  alias StressTester.Load

  defp build!(opts, defaults \\ %{}) do
    {:ok, load} = Load.build(Map.new(opts), defaults)
    load
  end

  test "users for a while is a closed load" do
    load = build!(vus: 20, duration: "30s")
    assert load.model == :closed
    assert load.vus == 20
    assert load.stages == [{30_000, 20}]
    assert Load.duration(load) == 30_000
    assert Load.value_at(load, 10_000) == 20
  end

  test "defaults fill what the caller left out" do
    load = build!([], %{vus: 7, duration: "5s", pace: "33ms"})
    assert load.vus == 7 and load.pace_ms == 33 and Load.duration(load) == 5_000
  end

  test "think time replaces pacing" do
    load = build!([vus: 1, think: "200ms"], %{pace: "33ms"})
    assert load.think_ms == 200 and load.pace_ms == nil
  end

  test "a ramp climbs in a straight line, then holds" do
    load = build!(vus: 100, ramp: "10s", duration: "20s")
    assert load.stages == [{10_000, 100}, {20_000, 100}]
    assert Load.value_at(load, 0) == 0.0
    assert Load.value_at(load, 5_000) == 50.0
    assert Load.value_at(load, 10_000) == 100
    assert Load.value_at(load, 25_000) == 100
    assert Load.duration(load) == 30_000
  end

  test "stages as text" do
    load = build!(stages: "30s:100,1m:100,30s:0")
    assert load.stages == [{30_000, 100}, {60_000, 100}, {30_000, 0}]
    assert load.max_vus == 100
    assert Load.value_at(load, 15_000) == 50.0
    assert Load.value_at(load, 105_000) == 50.0
    assert Load.value_at(load, 500_000) == 0
  end

  test "stages as data from a scenario file" do
    stages = [%{"duration" => "10s", "vus" => 5}, %{"duration" => "10s", "vus" => 20}]
    load = build!(stages: stages)
    assert load.stages == [{10_000, 5}, {10_000, 20}]
  end

  test "a rate is an open load" do
    load = build!(rate: 50.0, duration: "10s")
    assert load.model == :open
    assert load.stages == [{10_000, 50.0}]
    assert load.vus >= 1 and load.max_vus >= load.vus
  end

  test "rate stages need the /s" do
    load = build!(stages: "10s:20/s,10s:80/s")
    assert load.model == :open
    assert load.stages == [{10_000, 20.0}, {10_000, 80.0}]
  end

  test "mixing users and rates is refused" do
    assert {:error, message} = Load.build(%{stages: "10s:5,10s:20/s"}, %{})
    assert message =~ "mix"
  end

  test "bad stages are refused with the text that was bad" do
    assert {:error, message} = Load.build(%{stages: "soon:5"}, %{})
    assert message =~ "duration" or message =~ "stage"
    assert {:error, _} = Load.build(%{stages: "10s"}, %{})
    assert {:error, _} = Load.build(%{vus: 5, duration: "0s"}, %{})
    assert {:error, _} = Load.build(%{vus: 5, duration: "forever"}, %{})
  end

  test "a constant rate arrives on a regular beat" do
    segs = build!(rate: 10.0, duration: "10s") |> Load.segments()
    times = arrivals(segs, 5)
    assert times == [0, 100_000, 200_000, 300_000, 400_000]
  end

  test "a rising rate bunches up later" do
    # 0 → 20 per second over 10 s is 100 arrivals in total
    load = build!(stages: "10s:20/s", rate: nil)
    load = %{load | start: 0}
    segs = Load.segments(load)
    all = arrivals(segs, 1_000)
    assert_in_delta length(all), 100, 1
    assert all == Enum.sort(all)
    gaps = all |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
    assert Enum.max(Enum.take(gaps, 5)) > Enum.max(Enum.take(gaps, -5))
    assert List.last(all) <= 10_000_000
  end

  test "arrivals stop when the stages end" do
    segs = build!(rate: 4.0, duration: "2s") |> Load.segments()
    assert length(arrivals(segs, 100)) == 8
  end

  test "work is shared out by machine" do
    # 10 users over 3 machines
    assert for(i <- 0..2, do: StressTester.Generator.share(10, i, 3)) == [4, 3, 3]
    assert StressTester.Generator.share(2, 3, 4) == 0
    assert StressTester.Generator.share(0, 0, 1) == 0
  end

  test "it describes itself" do
    assert Load.describe(build!(vus: 5, duration: "10s")) =~ "5 users for 10.00s"
    assert Load.describe(build!(rate: 50.0, duration: "10s")) =~ "50 iterations/s"
    assert Load.describe(build!(vus: 5, duration: "10s", pace: "33ms")) =~ "every 33.0ms"
    assert Load.describe(build!(stages: "10s:5,10s:10")) =~ "→ 10"
  end

  defp arrivals(segs, max) do
    {list, _} =
      Enum.reduce_while(1..max, {[], segs}, fn k, {acc, segs} ->
        case Load.arrival(segs, k) do
          {:done, _} -> {:halt, {acc, segs}}
          {at, segs} -> {:cont, {[at | acc], segs}}
        end
      end)

    Enum.reverse(list)
  end
end
