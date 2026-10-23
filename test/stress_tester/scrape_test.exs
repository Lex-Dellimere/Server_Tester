defmodule StressTester.ScrapeTest do
  use ExUnit.Case, async: true

  alias StressTester.{Histogram, Scrape}
  alias StressTester.Test.TinyServer

  @page """
  reach_battles 10
  reach_udp_in 1000
  reach_tick_ms_bucket{le="1"} 10
  reach_tick_ms_bucket{le="5"} 90
  reach_tick_ms_bucket{le="33"} 99
  reach_tick_ms_bucket{le="+Inf"} 100
  reach_tick_ms_count 100
  reach_tick_ms_sum 400.5
  """

  test "a metrics page becomes numbers by series" do
    page = """
    # HELP x a comment
    # TYPE x counter
    plain 5
    labelled{a="1",b="two"} 2.5
    spaced   7   1700000000
    junk line here
    nan_value NaN
    """

    got = Scrape.parse(page)
    assert got == %{"plain" => 5.0, "labelled{a=\"1\",b=\"two\"}" => 2.5, "spaced" => 7.0}
  end

  test "what changed between two pages" do
    before = Scrape.parse("reach_battles 4\nreach_udp_in 400\nquiet 3\n")
    after_ = Scrape.parse("reach_battles 10\nreach_udp_in 1000\nquiet 3\nnew_one 8\n")
    diff = Scrape.diff(before, after_, 10.0)

    by_name = Map.new(diff.series, &{&1.name, &1})
    assert %{before: 4.0, after: 10.0, delta: 6.0} = by_name["reach_battles"]
    assert by_name["reach_udp_in"].delta == 600.0
    assert by_name["quiet"].delta == 0
    # absent from the first page means zero then, not unknown
    assert %{before: 0, after: 8.0, delta: 8.0} = by_name["new_one"]
  end

  test "histogram buckets turn into percentiles at the bucket's upper edge, in the right unit" do
    diff = Scrape.diff(%{}, Scrape.parse(@page), 10.0)
    h = diff.histograms["reach_tick_ms"]

    assert h.unit == :us and h.count == 100
    # 10 samples ≤1ms, 80 ≤5ms, 9 ≤33ms, 1 beyond: p50 sits in the ≤5ms bucket
    assert_in_delta Histogram.percentile(h, 50), 5_000, 50
    assert_in_delta Histogram.percentile(h, 95), 33_000, 300
    assert Histogram.percentile(h, 100) > 33_000
    # the parts of a histogram are not also listed as counters
    refute Enum.any?(diff.series, &String.starts_with?(&1.name, "reach_tick_ms"))
  end

  test "only the load's own samples count: the earlier page is subtracted" do
    before = Scrape.parse(@page)

    after_ =
      Scrape.parse("""
      reach_tick_ms_bucket{le="1"} 10
      reach_tick_ms_bucket{le="5"} 90
      reach_tick_ms_bucket{le="33"} 199
      reach_tick_ms_bucket{le="+Inf"} 200
      """)

    h = Scrape.diff(before, after_, 1.0).histograms["reach_tick_ms"]
    assert h.count == 100
    assert_in_delta Histogram.percentile(h, 50), 33_000, 300
  end

  test "units come from the metric's name" do
    page =
      ~s(a_seconds_bucket{le="0.5"} 4\na_seconds_bucket{le="+Inf"} 4\nb_bytes_bucket{le="1024"} 2\nb_bytes_bucket{le="+Inf"} 2\nc_bucket{le="3"} 1\nc_bucket{le="+Inf"} 1\n)

    hs = Scrape.diff(%{}, Scrape.parse(page), 1.0).histograms

    assert hs["a_seconds"].unit == :us and
             Histogram.percentile(hs["a_seconds"], 50) in 499_000..501_000

    assert hs["b_bytes"].unit == :bytes
    assert hs["c"].unit == :count
  end

  test "changes become thresholds' numbers" do
    diff = Scrape.diff(%{}, Scrape.parse(@page), 10.0)
    assert Scrape.counters(diff)["server.reach_udp_in"] == 1000.0
    assert %Histogram{} = Scrape.histograms(diff)["server.reach_tick_ms"]
  end

  test "the text and JSON forms carry the same facts" do
    diff =
      Scrape.diff(
        Scrape.parse("reach_udp_in 400\n"),
        Scrape.parse(@page <> "reach_udp_in 1000\n"),
        10.0
      )

    text = Scrape.text(diff, "http://x/metrics")
    assert text =~ "http://x/metrics"
    assert text =~ "reach_tick_ms"
    assert text =~ "p99 ≤"
    assert text =~ "400 → 1,000"
    assert text =~ "+600"
    assert text =~ "60/s"

    json = Scrape.json(diff)
    assert json["histograms"]["reach_tick_ms"]["count"] == 100
    assert Enum.any?(json["series"], &(&1["name"] == "reach_udp_in" and &1["delta"] == 600.0))
  end

  test "fetching a page, and the ways it goes wrong" do
    {port, _} =
      TinyServer.start(fn req, _n ->
        case req.path do
          "/metrics" ->
            {:reply_close,
             [
               "HTTP/1.1 200 OK\r\ncontent-length: ",
               Integer.to_string(byte_size(@page)),
               "\r\n\r\n",
               @page
             ]}

          _ ->
            {:reply_close, "HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n"}
        end
      end)

    assert {:ok, %{"reach_battles" => 10.0}} =
             Scrape.fetch(%{url: "http://127.0.0.1:#{port}/metrics"})

    assert {:error, "status 403"} = Scrape.fetch(%{url: "http://127.0.0.1:#{port}/private"})

    {:ok, l} = :gen_tcp.listen(0, [])
    {:ok, dead} = :inet.port(l)
    :gen_tcp.close(l)
    assert {:error, _} = Scrape.fetch(%{url: "http://127.0.0.1:#{dead}/metrics", timeout: 500})
  end

  test "a run reports the server's side, and a scrape that fails does not fail the run" do
    {port, _} =
      TinyServer.start(fn _req, _n ->
        {:reply, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"}
      end)

    {mport, counter} =
      TinyServer.start(fn _req, n ->
        # the second page has grown, as a real server's would
        page = if n == 1, do: "hits 10\n", else: "hits 70\n"

        {:reply_close,
         [
           "HTTP/1.1 200 OK\r\ncontent-length: ",
           Integer.to_string(byte_size(page)),
           "\r\n\r\n",
           page
         ]}
      end)

    {:ok, r} =
      StressTester.run(
        target: "http",
        url: "http://127.0.0.1:#{port}/",
        vus: 1,
        duration: "300ms",
        pace: "50ms",
        scrape: "http://127.0.0.1:#{mport}/metrics",
        silent: true,
        threshold: ["server.hits:count==60"]
      )

    assert r.ok
    assert %{diff: %{series: [%{name: "hits", delta: 60.0}]}} = r.server
    assert TinyServer.connections(counter) == 2

    assert r
           |> StressTester.Report.json()
           |> JSON.decode!()
           |> get_in(["server", "series"])
           |> length() == 1

    {:ok, r} =
      StressTester.run(
        target: "http",
        url: "http://127.0.0.1:#{port}/",
        vus: 1,
        duration: "200ms",
        pace: "50ms",
        scrape: "http://127.0.0.1:1/metrics",
        silent: true,
        threshold: ["server.hits:count>0"]
      )

    refute r.ok
    assert %{error: _} = r.server
    assert StressTester.Report.text(r) =~ "unavailable"

    {:ok, r} =
      StressTester.run(
        target: "http",
        url: "http://127.0.0.1:#{port}/",
        vus: 1,
        duration: "200ms",
        pace: "50ms",
        scrape: "off",
        silent: true,
        threshold: ["none"]
      )

    assert r.server == nil
  end

  test "the Reach target reads its server's /metrics by default" do
    {:ok, shared} = StressTester.Reach.init(%{address: "127.0.0.1:4001", metrics_token: "s3cret"})

    assert %{url: "http://127.0.0.1:4001/metrics", headers: [{"x-metrics-token", "s3cret"}]} =
             StressTester.Reach.scrape(shared)

    {:ok, shared} = StressTester.Reach.init(%{address: "https://127.0.0.1", insecure: true})

    assert %{url: "https://127.0.0.1:443/metrics", headers: [], insecure: true} =
             StressTester.Reach.scrape(shared)
  end
end
