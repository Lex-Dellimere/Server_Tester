defmodule StressTester.WebSocketTest do
  use ExUnit.Case, async: true

  alias StressTester.{Net, WebSocket}
  alias StressTester.Test.EchoWs

  defp connect do
    port = EchoWs.start()
    {:ok, origin} = Net.origin("ws://127.0.0.1:#{port}/")
    WebSocket.connect(origin, %{}, 2_000)
  end

  # what a server would send: no mask
  defp server_frame(opcode, payload, fin \\ 1) do
    len = byte_size(payload)
    size = if len < 126, do: <<len::8>>, else: <<126::8, len::16>>
    IO.iodata_to_binary([<<fin::1, 0::3, opcode::4>>, size, payload])
  end

  defp fresh, do: %WebSocket{sock: {:gen_tcp, nil}}

  test "connects, sends text, and reads the echo" do
    assert {:ok, ws, timing} = connect()
    assert timing.upgrade_us > 0
    assert :ok = WebSocket.text(ws, "hi")
    assert {:ok, _ws, [{:text, "echo:hi"}]} = WebSocket.recv(ws, 2_000)
    WebSocket.close(ws)
  end

  test "a long message crosses the 16-bit length boundary" do
    {:ok, ws, _} = connect()
    big = String.duplicate("x", 70_000)
    :ok = WebSocket.text(ws, big)

    # the echo comes back in pieces off the socket
    {ws, got} =
      Enum.reduce_while(1..200, {ws, []}, fn _, {ws, acc} ->
        case WebSocket.recv(ws, 2_000) do
          {:ok, ws, msgs} ->
            if msgs == [], do: {:cont, {ws, acc}}, else: {:halt, {ws, acc ++ msgs}}

          {:error, _} ->
            {:halt, {ws, acc}}
        end
      end)

    _ = ws
    assert [{:text, text}] = got
    assert byte_size(text) == 70_005
    assert String.starts_with?(text, "echo:x")
  end

  test "masking is its own inverse" do
    mask = <<1, 2, 3, 4>>
    data = :crypto.strong_rand_bytes(1_001)
    assert WebSocket.unmask(WebSocket.unmask(data, mask), mask) == data
    assert WebSocket.unmask(<<>>, mask) == <<>>
    assert WebSocket.unmask(<<0, 0, 0, 0, 0>>, mask) == <<1, 2, 3, 4, 1>>
  end

  test "frames out are masked and read back" do
    frame = IO.iodata_to_binary(WebSocket.frame(1, "payload"))
    assert {:ok, _, [{:text, "payload"}]} = WebSocket.feed(fresh(), frame)
  end

  test "a message split across reads is joined" do
    frame = server_frame(1, "whole message")
    <<a::binary-size(5), b::binary>> = frame
    assert {:ok, ws, []} = WebSocket.feed(fresh(), a)
    assert {:ok, _, [{:text, "whole message"}]} = WebSocket.feed(ws, b)
  end

  test "two messages in one read" do
    data = server_frame(1, "one") <> server_frame(2, <<9, 9>>)
    assert {:ok, _, [{:text, "one"}, {:binary, <<9, 9>>}]} = WebSocket.feed(fresh(), data)
  end

  test "fragments are joined" do
    data = server_frame(1, "ab", 0) <> server_frame(0, "cd", 0) <> server_frame(0, "ef", 1)
    assert {:ok, _, [{:text, "abcdef"}]} = WebSocket.feed(fresh(), data)
  end

  test "a pong and a close are reported; a close is answered once" do
    data = server_frame(10, "p") <> server_frame(8, <<1001::16, "bye">>)

    assert {:ok, ws, [{:pong, "p"}, {:close, 1001, "bye"}]} =
             WebSocket.feed(%{fresh() | sock: {:gen_tcp, closed_socket()}}, data)

    assert ws.closed
  end

  test "a data frame in the middle of fragments is refused" do
    data = server_frame(1, "ab", 0) <> server_frame(1, "cd", 1)
    assert {:error, {:unexpected_opcode, 1}} = WebSocket.feed(fresh(), data)
  end

  test "a server that refuses the upgrade is an error" do
    {port, _} =
      StressTester.Test.TinyServer.start(fn _req, _n ->
        {:reply_close, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"}
      end)

    {:ok, origin} = Net.origin("ws://127.0.0.1:#{port}/")
    assert {:error, {:upgrade, "HTTP/1.1 200 OK" <> _}} = WebSocket.connect(origin, %{}, 1_000)
  end

  test "a wrong accept key is refused" do
    {port, _} =
      StressTester.Test.TinyServer.start(fn _req, _n ->
        {:reply_close,
         "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nsec-websocket-accept: AAAA\r\n\r\n"}
      end)

    {:ok, origin} = Net.origin("ws://127.0.0.1:#{port}/")
    assert {:error, :bad_accept_key} = WebSocket.connect(origin, %{}, 1_000)
  end

  # a socket that is already closed, so the answer to a close frame goes nowhere
  defp closed_socket do
    {:ok, s} = :gen_tcp.listen(0, [])
    :gen_tcp.close(s)
    s
  end
end
