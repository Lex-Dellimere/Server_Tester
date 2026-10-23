defmodule StressTester.HttpTest do
  use ExUnit.Case, async: true

  alias StressTester.{Http, Net}
  alias StressTester.Test.TinyServer

  defp client(port) do
    {:ok, origin} = Net.origin("http://127.0.0.1:#{port}")
    Http.new(origin)
  end

  defp get(conn, path \\ "/", method \\ "GET"),
    do: Http.request(conn, method, path, [], nil, 2_000)

  defp ok(body, extra \\ ""),
    do:
      {:reply, ["HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n", extra, "\r\n", body]}

  test "a body with a content-length" do
    {port, _} = TinyServer.start(fn _req, _n -> ok("hello") end)
    assert {:ok, _conn, resp} = get(client(port))
    assert resp.status == 200 and resp.body == "hello" and resp.bytes == 5
    assert resp.ttfb_us > 0
    assert resp.connect_us > 0
    assert Http.header(resp.headers, "content-length") == "5"
  end

  test "a chunked body, split across reads" do
    {port, _} =
      TinyServer.start(fn _req, _n ->
        {:reply,
         "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n"}
      end)

    assert {:ok, _, resp} = get(client(port))
    assert resp.body == "hello world"
  end

  test "a body that ends when the server hangs up" do
    {port, _} =
      TinyServer.start(fn _req, _n -> {:reply_close, "HTTP/1.0 200 OK\r\n\r\nuntil the end"} end)

    assert {:ok, conn, resp} = get(client(port))
    assert resp.body == "until the end"
    assert conn.sock == nil
  end

  test "no body for HEAD, 204 or 304" do
    {port, _} =
      TinyServer.start(fn req, _n ->
        case req.path do
          "/204" -> {:reply, "HTTP/1.1 204 No Content\r\n\r\n"}
          "/304" -> {:reply, "HTTP/1.1 304 Not Modified\r\ncontent-length: 99\r\n\r\n"}
          _ -> {:reply, "HTTP/1.1 200 OK\r\ncontent-length: 99\r\n\r\n"}
        end
      end)

    c = client(port)
    assert {:ok, c, %{status: 204, body: ""}} = get(c, "/204")
    assert {:ok, c, %{status: 304, body: ""}} = get(c, "/304")
    assert {:ok, _, %{status: 200, body: ""}} = get(c, "/", "HEAD")
  end

  test "an interim 100 answer is skipped" do
    {port, _} =
      TinyServer.start(fn _req, _n ->
        {:reply, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"}
      end)

    assert {:ok, _, %{status: 200, body: "ok"}} = get(client(port))
  end

  test "one connection serves many requests" do
    {port, conns} = TinyServer.start(fn _req, _n -> ok("x") end)
    conn = client(port)

    conn =
      Enum.reduce(1..5, conn, fn _, c ->
        assert {:ok, c, %{status: 200}} = get(c)
        c
      end)

    assert conn.requests == 5
    assert TinyServer.connections(conns) == 1
  end

  test "connection: close is honoured" do
    {port, conns} = TinyServer.start(fn _req, _n -> ok("x", "connection: close\r\n") end)
    assert {:ok, c, _} = get(client(port))
    assert c.sock == nil
    assert {:ok, _, _} = get(c)
    assert TinyServer.connections(conns) == 2
  end

  test "a kept-open connection the server already closed is retried once on a new one" do
    # the first connection answers once, then hangs up without saying so
    {port, conns} =
      TinyServer.start(fn _req, n ->
        if n == 1,
          do: {:reply_close, ["HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\n", "a"]},
          else: ok("b")
      end)

    assert {:ok, c, %{body: "a"}} = get(client(port))
    # the server's close was not announced, so the client still holds the dead socket
    assert c.sock != nil
    Process.sleep(50)
    assert {:ok, _c, %{body: "b"}} = get(c)
    assert TinyServer.connections(conns) >= 2
  end

  test "a request body gets a content-length" do
    {port, _} =
      TinyServer.start(fn req, _n ->
        ok(
          JSON.encode!(%{
            "len" => req.headers["content-length"],
            "body" => req.body,
            "type" => req.headers["content-type"]
          })
        )
      end)

    {:ok, _, resp} =
      Http.request(client(port), "POST", "/", [{"content-type", "text/plain"}], "abc", 2_000)

    assert JSON.decode!(resp.body) == %{"len" => "3", "body" => "abc", "type" => "text/plain"}
  end

  test "a server that never answers times out" do
    {port, _} = TinyServer.start(fn _req, _n -> :close end)
    assert {:error, _conn, reason} = Http.request(client(port), "GET", "/", [], nil, 300)
    assert reason in [:closed, :timeout, :econnreset]
  end

  test "nothing listening is an error, not a crash" do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    assert {:error, _conn, reason} = get(client(port))
    assert reason in [:econnrefused, :closed]
  end

  test "garbage instead of HTTP is reported" do
    {port, _} =
      TinyServer.start(fn _req, _n -> {:reply_close, "this is not http at all\r\n\r\n"} end)

    assert {:error, _, reason} = get(client(port))
    assert match?({:bad_status_line, _}, reason) or reason == :bad_status_line
  end
end
