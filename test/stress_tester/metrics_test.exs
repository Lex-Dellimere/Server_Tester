defmodule StressTester.MetricsTest do
  use ExUnit.Case, async: true

  alias StressTester.{Histogram, Metrics}

  # each test runs in its own process, so its numbers are its own
  test "counts, observations and errors collect and are taken once" do
    Metrics.count("a")
    Metrics.count("a", 4)
    Metrics.observe("t", 1_000)
    Metrics.observe("t", 3_000)
    Metrics.observe("size", 500, :bytes)
    Metrics.error("login", :timeout)
    Metrics.error("login", :timeout)
    Metrics.error("login", {:status, 500})

    d = Metrics.take()
    assert d.c["a"] == 5
    assert d.c["errors"] == 3
    assert d.h["t"].count == 2 and d.h["t"].unit == :us
    assert d.h["size"].unit == :bytes
    assert d.e[{"login", "timeout"}] == 2
    assert d.e[{"login", "status 500"}] == 1
    assert Metrics.empty?(Metrics.take())
  end

  test "time measures and returns the result" do
    assert Metrics.time("work", fn -> :done end) == :done
    assert Metrics.take().h["work"].count == 1
  end

  test "merging adds counters, histograms and errors" do
    Metrics.count("x", 2)
    Metrics.observe("h", 10)
    a = Metrics.take()
    Metrics.count("x", 3)
    Metrics.observe("h", 20)
    Metrics.error("w", "why")
    b = Metrics.take()

    m = Metrics.merge(a, b)
    assert m.c["x"] == 5
    assert m.h["h"].count == 2
    assert m.e[{"w", "why"}] == 1
    assert Metrics.merge(Metrics.empty(), a).c == a.c
  end

  test "many kinds of error are folded into one" do
    errors = for n <- 1..30, into: %{}, do: {{"w", "reason #{n}"}, n}
    capped = Metrics.cap_errors(%{c: %{}, h: %{}, e: errors}, 10)
    assert map_size(capped.e) == 10
    assert Enum.sum(Map.values(capped.e)) == Enum.sum(Map.values(errors))
    assert Map.has_key?(capped.e, {"other", "more kinds of error"})
    assert Metrics.cap_errors(%{c: %{}, h: %{}, e: %{a: 1}}, 10).e == %{a: 1}
  end

  test "reasons become short text" do
    assert Metrics.reason("plain") == "plain"
    assert Metrics.reason(:closed) == "closed"
    assert Metrics.reason({:status, 503}) == "status 503"
    assert Metrics.reason(%RuntimeError{message: "bad"}) == "bad"
    assert String.length(Metrics.reason(String.duplicate("x", 1_000))) == 160
    assert Metrics.reason({:a, :b}) == "{:a, :b}"
  end

  test "histograms from different processes merge" do
    h = Histogram.new() |> Histogram.add(5)
    assert Histogram.merge(h, h).count == 2
  end
end
