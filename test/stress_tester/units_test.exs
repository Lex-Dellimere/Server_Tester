defmodule StressTester.UnitsTest do
  use ExUnit.Case, async: true

  alias StressTester.Units

  test "durations in many spellings become milliseconds" do
    assert Units.ms("500ms", :s) == {:ok, 500}
    assert Units.ms("30s", :ms) == {:ok, 30_000}
    assert Units.ms("1.5s", :ms) == {:ok, 1_500}
    assert Units.ms("5m", :ms) == {:ok, 300_000}
    assert Units.ms("1h", :ms) == {:ok, 3_600_000}
    assert Units.ms("250us", :ms) == {:ok, 0}
    assert Units.ms(" 10 s ", :ms) == {:ok, 10_000}
  end

  test "a bare number takes the unit it is given" do
    assert Units.ms("10", :s) == {:ok, 10_000}
    assert Units.ms("10", :ms) == {:ok, 10}
    assert Units.ms(10, :s) == {:ok, 10_000}
    assert Units.ms(nil, :s) == {:ok, nil}
  end

  test "nonsense is refused with a reason" do
    assert {:error, message} = Units.ms("soon", :s)
    assert message =~ "not a duration"
    assert {:error, _} = Units.ms("-5s", :s)
    assert {:error, _} = Units.ms(%{}, :s)
  end

  test "shell escapes become bytes" do
    assert Units.unescape("ping\\n") == "ping\n"
    assert Units.unescape("a\\r\\nb\\tc") == "a\r\nb\tc"
    assert Units.unescape("\\x00\\xff") == <<0, 255>>
    assert Units.unescape("back\\\\slash") == "back\\slash"
    assert Units.unescape("plain") == "plain"
  end

  test "times read at every scale" do
    assert Units.time(nil) == "-"
    assert Units.time(850) == "850µs"
    assert Units.time(1_500) == "1.50ms"
    assert Units.time(25_000) == "25.0ms"
    assert Units.time(2_500_000) == "2.50s"
    assert Units.time(125_000_000) == "2m05s"
  end

  test "numbers of any size keep a few digits" do
    assert Units.figure(nil) == "-"
    assert Units.figure(0.0) == "0"
    assert Units.figure(7) == "7"
    assert Units.figure(0.00921) == "0.0092"
    assert Units.figure(1.2345) == "1.23"
    assert Units.figure(12.345) == "12.3"
    assert Units.figure(12_345.6) == "12,346"
  end

  test "sizes and counts" do
    assert Units.bytes(512) == "512B"
    assert Units.bytes(2_048) == "2.0KB"
    assert Units.bytes(3 * 1_048_576) == "3.0MB"
    assert Units.count(1_234_567) == "1,234,567"
    assert Units.count(-1_234) == "-1,234"
    assert Units.count(12.34) == "12.3"
    assert Units.count(1234.5) == "1,235"
    assert Units.count(nil) == "-"
    assert Units.percent(0.0125) == "1.25%"
    assert Units.value(2_000, :us) == "2.00ms"
    assert Units.value(2_048, :bytes) == "2.0KB"
    assert Units.value(7, :count) == "7"
  end
end
