defmodule StressTester.Test.EchoWs do
  @moduledoc false
  # a WebSocket server that answers each text message with "echo:" and the text

  alias StressTester.WebSocket

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def start do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen) end)
    port
  end

  defp accept(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        pid = spawn(fn -> handshake(sock, <<>>) end)
        :gen_tcp.controlling_process(sock, pid)
        accept(listen)

      _ ->
        :ok
    end
  end

  defp handshake(sock, buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, rest] ->
        [_, key] = Regex.run(~r/sec-websocket-key: (\S+)/i, head)
        accept = :crypto.hash(:sha, key <> @guid) |> Base.encode64()

        :gen_tcp.send(sock, [
          "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: ",
          accept,
          "\r\n\r\n"
        ])

        loop(sock, %WebSocket{sock: {:gen_tcp, sock}, buf: rest}, <<>>)

      [_] ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, data} -> handshake(sock, buf <> data)
          _ -> :gen_tcp.close(sock)
        end
    end
  end

  defp loop(sock, ws, data) do
    case WebSocket.feed(ws, data) do
      {:ok, ws, msgs} ->
        Enum.each(msgs, fn
          {:text, "bye"} ->
            :gen_tcp.send(sock, unmasked(8, <<1001::16, "going away">>))
            :gen_tcp.close(sock)

          {:text, text} ->
            :gen_tcp.send(sock, unmasked(1, "echo:" <> text))

          {:close, _, _} ->
            :gen_tcp.close(sock)

          _ ->
            :ok
        end)

        case :gen_tcp.recv(sock, 0, 10_000) do
          {:ok, more} -> loop(sock, ws, more)
          _ -> :gen_tcp.close(sock)
        end

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  defp unmasked(opcode, payload) do
    len = byte_size(payload)

    size =
      cond do
        len < 126 -> <<len::8>>
        len < 65_536 -> <<126::8, len::16>>
        true -> <<127::8, len::64>>
      end

    [<<1::1, 0::3, opcode::4>>, size, payload]
  end
end
