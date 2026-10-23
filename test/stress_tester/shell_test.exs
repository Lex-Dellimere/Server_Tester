defmodule StressTester.ShellTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import StressTester.Shell

  alias StressTester.{History, Html}
  alias StressTester.Test.TinyServer

  @tmp Path.join(System.tmp_dir!(), "stress-shell-#{System.unique_integer([:positive])}")

  setup do
    History.clear()

    {port, _} =
      TinyServer.start(fn _req, _n ->
        {:reply, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"}
      end)

    on_exit(fn -> File.rm_rf(@tmp) end)
    %{url: "http://127.0.0.1:#{port}/"}
  end

  defp quick(url, extra \\ []) do
    capture_io(fn ->
      send(
        self(),
        {:r, http(url, [vus: 1, duration: "500ms", pace: "50ms", quiet: true] ++ extra)}
      )
    end)

    assert_received {:r, r}
    r
  end

  test "every run is numbered and kept for the session", %{url: url} do
    a = quick(url)
    b = quick(url, threshold: ["http.req:p99<1us"])

    assert a.run == 1 and b.run == 2
    assert run(1).run == 1
    assert last().run == 2
    assert a.ok and not b.ok

    out = capture_io(fn -> runs() end)
    assert out =~ "  1  PASS"
    assert out =~ "  2  FAIL"
    assert_raise ArgumentError, fn -> run(99) end
  end

  test "reading a report: one metric, a timeline, the text again", %{url: url} do
    r = quick(url)
    assert %{"count" => n, "p99" => _} = metric(r, "http.req")
    assert n > 3
    assert {:missing, names} = metric(r, "nope")
    assert "http.req" in names
    assert [{_, _} | _] = timeline(r, "http.req")
    assert capture_io(fn -> show(r) end) =~ "PASS"
  end

  test "two runs side by side", %{url: url} do
    a = quick(url)
    b = quick(url, pace: "100ms")
    out = capture_io(fn -> compare(a, b) end)
    assert out =~ "verdict"
    assert out =~ "iterations/s"
    assert out =~ "http.req p99"
    assert out =~ "%"
  end

  test "html, json, save and load", %{url: url} do
    # charts need two seconds or more to draw a line
    r = quick(url, duration: "2500ms")
    page = capture_io(fn -> send(self(), {:p, html(r, Path.join(@tmp, "r.html"))}) end)
    assert page =~ "wrote"
    assert_received {:p, path}
    text = File.read!(path)
    assert text =~ "<!doctype html>"
    assert text =~ "PASS"
    assert text =~ "<svg"
    assert text =~ "http.req"

    j = json(r, Path.join(@tmp, "r.json"))
    assert %{"ok" => true} = j |> File.read!() |> JSON.decode!()

    saved = save(r, Path.join(@tmp, "r.bin"))
    History.clear()
    back = load(saved)
    assert back.counters == r.counters
    assert last().counters == r.counters
  end

  test "scenarios by name, and help", %{url: url} do
    out = capture_io(fn -> scenarios() end)
    assert out =~ "reach-50v50"
    assert_raise ArgumentError, fn -> scenario("no-such-scenario") end
    assert capture_io(fn -> help() end) =~ "reach(vus: 100"

    path = Path.join(@tmp, "s.json")
    File.mkdir_p!(@tmp)

    File.write!(
      path,
      JSON.encode!(%{
        "target" => "http",
        "url" => url,
        "vus" => 1,
        "duration" => "300ms",
        "pace" => "50ms",
        "quiet" => true
      })
    )

    capture_io(fn -> send(self(), {:r, scenario(path)}) end)
    assert_received {:r, %{ok: true}}
  end

  test "a run that cannot start says why and hands back the error" do
    capture_io(fn -> send(self(), {:r, http("http://no-such-host.invalid/")}) end)
    assert_received {:r, {:error, message}}
    assert message =~ "resolve"
  end

  test "--html writes a page from the command line", %{url: url} do
    path = Path.join(@tmp, "cli.html")

    capture_io(fn ->
      assert StressTester.CLI.run([
               "http",
               url,
               "--vus",
               "1",
               "--duration",
               "2500ms",
               "--pace",
               "50ms",
               "--quiet",
               "--html",
               path
             ]) == 0
    end)

    assert File.read!(path) =~ "<svg"
  end

  test "a chart is drawn from points, with its axis labels" do
    svg = Html.chart({"Users", [{0, 0}, {1, 5}, {2, 10}], :count})
    assert svg =~ "<polyline"
    assert svg =~ "Users"
    assert svg =~ "10"
    assert Html.esc("<b> & \"x\"") == "&lt;b&gt; &amp; &quot;x&quot;"
  end
end
