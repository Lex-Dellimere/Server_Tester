defmodule StressTester.AgentTest do
  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag timeout: 60_000

  alias StressTester.Test.Counter

  # a second Erlang node with the same code, standing in for a second machine
  defp start_agent do
    name = :"agent#{System.unique_integer([:positive])}"

    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", ~c"#{Node.get_cookie()}"]
      })

    :ok = :erpc.call(node, :code, :add_pathsa, [:code.get_path()])
    # the tester and what it needs, not the Reach server it is tested against
    :ok = :erpc.call(node, :application, :load, [:stress_tester])

    for app <- [:crypto, :ssl, :public_key, :runtime_tools],
        do: {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [app])

    {peer, node}
  end

  test "users are shared out between this machine and an agent" do
    {peer, node} = start_agent()

    {:ok, report} =
      StressTester.run(
        target: Counter,
        vus: 10,
        duration: "1s",
        pace: "50ms",
        agents: [node],
        cookie: Atom.to_string(Node.get_cookie()),
        silent: true,
        threshold: ["none"]
      )

    assert report.counters["vu.started"] == 10
    assert report.tester["machines"] == 2
    assert report.tester["peak_users"] in 8..10
    # everyone did their share: about 20 iterations each
    assert_in_delta report.counters["iterations"], 200, 40
    :peer.stop(peer)
  end

  test "--no-local runs everything on the agents" do
    {peer, node} = start_agent()

    {:ok, report} =
      StressTester.run(
        target: Counter,
        vus: 4,
        duration: "1s",
        pace: "50ms",
        agents: [node],
        local: false,
        silent: true,
        threshold: ["none"]
      )

    assert report.counters["vu.started"] == 4
    assert report.tester["machines"] == 1
    :peer.stop(peer)
  end

  test "an agent that cannot be reached is an error before anything runs" do
    assert {:error, message} =
             StressTester.run(
               target: Counter,
               vus: 1,
               duration: "1s",
               agents: [:"nobody@127.0.0.1"],
               silent: true
             )

    assert message =~ "cannot reach agent"
  end

  test "a rate is shared out too, and each iteration happens once" do
    {peer, node} = start_agent()

    {:ok, report} =
      StressTester.run(
        target: Counter,
        rate: 100.0,
        duration: "1s",
        agents: [node],
        silent: true,
        threshold: ["none"]
      )

    assert_in_delta report.counters["iterations"], 100, 12
    assert report.tester["machines"] == 2
    :peer.stop(peer)
  end

  test "the build fingerprint is the same on both" do
    {peer, node} = start_agent()

    assert :erpc.call(node, StressTester.Agent, :fingerprint, []) ==
             StressTester.Agent.fingerprint()

    :peer.stop(peer)
  end
end
