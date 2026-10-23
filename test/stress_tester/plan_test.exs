defmodule StressTester.PlanTest do
  use ExUnit.Case, async: true

  alias StressTester.{CLI, Plan}
  alias StressTester.Test.Counter

  @tmp System.tmp_dir!()

  defp scenario(map) do
    path = Path.join(@tmp, "stress-plan-#{System.unique_integer([:positive])}.json")
    File.write!(path, JSON.encode!(map))
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "a plan turns options into a load, thresholds and a target" do
    assert {:ok, plan} =
             Plan.build(target: Counter, vus: 3, duration: "5s", threshold: ["errors==0"])

    assert plan.target == Counter
    assert plan.load.vus == 3
    assert [%{text: "errors==0"}] = plan.thresholds
    assert plan.live and plan.print
    assert plan.local and plan.agents == []
  end

  test "--threshold none drops the target's defaults" do
    {:ok, with_defaults} = Plan.build(target: "http", url: "http://x/")
    {:ok, none} = Plan.build(target: "http", url: "http://x/", threshold: ["none"])
    assert with_defaults.thresholds != []
    assert none.thresholds == []
  end

  test "a bad threshold or load is refused before anything runs" do
    assert {:error, message} = Plan.build(target: Counter, threshold: ["wibble"])
    assert message =~ "not a threshold"
    assert {:error, _} = Plan.build(target: Counter, duration: "forever")
    assert {:error, _} = Plan.build(target: Counter, stages: "5s:1,5s:2/s")
  end

  test "agents are named in a list or a comma string" do
    {:ok, a} = Plan.build(target: Counter, agents: "a@127.0.0.1,b@127.0.0.1")
    {:ok, b} = Plan.build(target: Counter, agents: ["a@127.0.0.1"])
    assert a.agents == [:"a@127.0.0.1", :"b@127.0.0.1"]
    assert b.agents == [:"a@127.0.0.1"]
  end

  test "checks may be a word or a list of names" do
    assert {:ok, %{checks: :all}} = Plan.build(target: Counter, checks: "all")
    assert {:ok, %{checks: :none}} = Plan.build(target: Counter, checks: "none")
    assert {:ok, %{checks: ["a", "b"]}} = Plan.build(target: Counter, checks: "a,b")
    assert {:ok, %{checks: :default}} = Plan.build(target: Counter)
  end

  test "a scenario file is a plan" do
    path =
      scenario(%{
        "target" => "http",
        "url" => "http://127.0.0.1:1/",
        "vus" => 4,
        "duration" => "3s",
        "thresholds" => ["http.req:p99<1s"]
      })

    assert {:ok, plan} = Plan.from_file(path)
    assert plan.load.vus == 4
    assert [%{text: "http.req:p99<1s"}] = plan.thresholds
  end

  test "command-line options override the file" do
    path =
      scenario(%{
        "target" => "http",
        "url" => "http://127.0.0.1:1/",
        "vus" => 4,
        "duration" => "3s"
      })

    assert {:ok, plan} = Plan.from_file(path, %{vus: 9})
    assert plan.load.vus == 9
  end

  test "an unknown key in a scenario is an error, so a typo cannot pass silently" do
    path = scenario(%{"target" => "http", "url" => "http://x/", "vuss" => 4})
    assert {:error, message} = Plan.from_file(path)
    assert message =~ ~s("vuss")
  end

  test "missing and broken files are reported" do
    assert {:error, message} = Plan.from_file("/nonexistent/plan.json")
    assert message =~ "cannot read"
    path = Path.join(@tmp, "stress-broken-#{System.unique_integer([:positive])}.json")
    File.write!(path, "{not json")
    on_exit(fn -> File.rm(path) end)
    assert {:error, message} = Plan.from_file(path)
    assert message =~ "not JSON"
    assert {:error, message} = Plan.from_file(scenario([1, 2]))
    assert message =~ "JSON object"
  end

  describe "the command line" do
    test "options are typed" do
      {:ok, target} = StressTester.Target.resolve("http")

      assert {:ok, opts} =
               CLI.parse(
                 [
                   "http://x/",
                   "--vus",
                   "5",
                   "--rate",
                   "2.5",
                   "--header",
                   "a: b",
                   "--header",
                   "c: d",
                   "--insecure"
                 ],
                 target
               )

      assert opts.vus == 5 and opts.rate == 2.5 and opts.insecure
      assert opts.header == ["a: b", "c: d"]
      assert opts.address == "http://x/"
    end

    test "shell escapes in payloads become bytes" do
      {:ok, target} = StressTester.Target.resolve("ws")
      assert {:ok, %{message: "a\nb"}} = CLI.parse(["--message", "a\\nb"], target)
    end

    test "unknown options are refused" do
      {:ok, target} = StressTester.Target.resolve("http")
      assert {:error, message} = CLI.parse(["--vuz", "5"], target)
      assert message =~ "--vuz"
    end

    test "exit codes: 0 passed, 1 failed, 2 could not start" do
      import ExUnit.CaptureIO

      {port, _} =
        StressTester.Test.TinyServer.start(fn _req, _n ->
          {:reply, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"}
        end)

      url = "http://127.0.0.1:#{port}/"

      capture_io(fn ->
        assert CLI.run([
                 "http",
                 url,
                 "--vus",
                 "1",
                 "--duration",
                 "1s",
                 "--pace",
                 "100ms",
                 "--quiet"
               ]) == 0

        assert CLI.run([
                 "http",
                 url,
                 "--vus",
                 "1",
                 "--duration",
                 "1s",
                 "--pace",
                 "100ms",
                 "--quiet",
                 "--threshold",
                 "http.req:p99<1us"
               ]) == 1
      end)

      capture_io(:stderr, fn ->
        assert CLI.run(["nope", "--vus", "1"]) == 2
        assert CLI.run(["http"]) == 2
        assert CLI.run(["http", url, "--wat"]) == 2
      end)
    end

    test "help prints and succeeds" do
      import ExUnit.CaptureIO
      out = capture_io(fn -> assert CLI.run(["help"]) == 0 end)
      assert out =~ "--vus" and out =~ "targets:"
      out = capture_io(fn -> assert CLI.run(["help", "reach"]) == 0 end)
      assert out =~ "stress logins"
    end
  end
end
