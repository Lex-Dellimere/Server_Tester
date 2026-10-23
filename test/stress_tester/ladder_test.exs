defmodule StressTester.LadderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias StressTester.{CLI, Ladder}
  alias StressTester.Test.Counter

  # a pretend server that takes 5 users and refuses the rest
  defp opts(extra \\ []) do
    Map.new(
      [
        target: Counter,
        capacity: 5,
        duration: "500ms",
        ramp: "0s",
        pace: "50ms",
        grace: "1s",
        settle_ms: 50,
        silent: true,
        threshold: ["vu.connect_failed:count==0"]
      ] ++ extra
    )
  end

  test "it climbs until a rung fails, then stops" do
    assert {:ok, rungs} = Ladder.run(opts(), [2, 4, 8, 16])

    assert Enum.map(rungs, & &1.step) == [2, 4, 8]
    assert Enum.map(rungs, & &1.ok) == [true, true, false]
    failed = List.last(rungs)
    assert failed.connect_failed >= 3
    assert Enum.any?(failed.failing, &String.contains?(&1, "vu.connect_failed"))
    assert hd(rungs).iterations_per_s > 20

    words = Ladder.verdict(rungs)
    assert words =~ "highest rung that passed: 4"
    assert words =~ "first failure at 8"
  end

  test "it can keep going past a failure" do
    assert {:ok, rungs} = Ladder.run(opts(keep_going: true), [4, 8, 6])
    assert Enum.map(rungs, & &1.ok) == [true, false, false]
  end

  test "when nothing passes it says so" do
    {:ok, rungs} = Ladder.run(opts(capacity: 0), [2, 4])
    assert length(rungs) == 1
    assert Ladder.verdict(rungs) =~ "no rung passed"
  end

  test "a ladder by rate" do
    {:ok, rungs} =
      Ladder.run(
        Map.drop(opts(), [:capacity, :pace]) |> Map.put(:threshold, ["none"]),
        [20, 40],
        :rate
      )

    assert Enum.map(rungs, & &1.step) == [20, 40]
    assert Enum.all?(rungs, & &1.ok)
    assert_in_delta List.last(rungs).iterations_per_s, 40, 12
  end

  test "the table prints a row per rung" do
    out = capture_io(fn -> Ladder.run(Map.delete(opts(), :silent), [2, 8]) end)
    assert out =~ "ladder: Counter"
    assert out =~ "users"
    assert out =~ "PASS"
    assert out =~ "FAIL"
  end

  test "bad setup is an error, not a crash" do
    assert {:error, message} = Ladder.run(opts(threshold: ["wibble"]), [2])
    assert message =~ "not a threshold"
  end

  describe "on the command line" do
    test "exit 0 when some rung passed, 1 when none did" do
      capture_io(fn ->
        args = [
          "--steps",
          "2,8",
          "--duration",
          "500ms",
          "--ramp",
          "0s",
          "--grace",
          "1s",
          "--settle",
          "50ms",
          "--threshold",
          "vu.connect_failed:count==0"
        ]

        assert CLI.run(["ladder", "reach", "127.0.0.1:1" | args]) == 1
      end)
    end

    test "--steps is required and must be numbers" do
      capture_io(:stderr, fn ->
        assert CLI.run(["ladder", "reach"]) == 2
        assert CLI.run(["ladder", "reach", "--steps", "a,b"]) == 2
        assert CLI.run(["ladder", "reach", "--steps", "10", "--by", "sideways"]) == 2
        assert CLI.run(["ladder"]) == 2
        assert CLI.run(["ladder", "nope", "--steps", "1"]) == 2
      end)
    end
  end
end
