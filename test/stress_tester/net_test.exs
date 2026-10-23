defmodule StressTester.NetTest do
  use ExUnit.Case, async: true

  alias StressTester.Net

  test "a URL becomes an origin with the port its scheme implies" do
    assert {:ok,
            %{
              scheme: "http",
              host: "127.0.0.1",
              port: 80,
              ip: {127, 0, 0, 1},
              tls: false,
              path: "/"
            }} = Net.origin("http://127.0.0.1")

    assert {:ok, %{port: 443, tls: true}} = Net.origin("https://127.0.0.1")
    assert {:ok, %{port: 8080, path: "/a/b?q=1"}} = Net.origin("http://127.0.0.1:8080/a/b?q=1")
    assert {:ok, %{port: 443, tls: true}} = Net.origin("wss://127.0.0.1/socket")
    assert {:ok, %{port: 80, tls: false}} = Net.origin("ws://127.0.0.1/socket")
  end

  test "no scheme means the default one" do
    assert {:ok, %{port: 4001, host: "127.0.0.1", tls: false}} = Net.origin("127.0.0.1:4001")
    assert {:ok, %{tls: false}} = Net.origin("127.0.0.1:4001", "ws")
  end

  test "IPv6 literals" do
    assert {:ok, %{ip: {0, 0, 0, 0, 0, 0, 0, 1}, port: 4001}} = Net.origin("http://[::1]:4001/")
    assert Net.family({0, 0, 0, 0, 0, 0, 0, 1}) == [:inet6]
    assert Net.family({127, 0, 0, 1}) == []
  end

  test "what cannot be used is refused with words" do
    assert {:error, message} = Net.origin("http://")
    assert message =~ "no host"
    assert {:error, message} = Net.origin("http://no-such-host.invalid/")
    assert message =~ "cannot resolve"
  end

  test "host and port" do
    assert {:ok, "127.0.0.1", {127, 0, 0, 1}, 99} = Net.host_port("127.0.0.1:99", nil)
    assert {:ok, "127.0.0.1", {127, 0, 0, 1}, 7} = Net.host_port("127.0.0.1", 7)
    assert {:ok, "::1", {0, 0, 0, 0, 0, 0, 0, 1}, 5} = Net.host_port("[::1]:5", nil)
    assert {:error, message} = Net.host_port("127.0.0.1", nil)
    assert message =~ "host:port"
  end

  test "names are resolved, literals are not looked up" do
    assert {:ok, {127, 0, 0, 1}} =
             Net.resolve("localhost")
             |> then(fn
               {:ok, ip} -> {:ok, ip}
               e -> e
             end)
             |> localhost()

    assert {:ok, {10, 1, 2, 3}} = Net.resolve("10.1.2.3")
  end

  defp localhost({:ok, {127, 0, 0, 1}} = ok), do: ok
  defp localhost({:ok, {0, 0, 0, 0, 0, 0, 0, 1}}), do: {:ok, {127, 0, 0, 1}}
  defp localhost(other), do: other
end
