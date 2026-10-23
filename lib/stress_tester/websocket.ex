defmodule StressTester.WebSocket do
  @moduledoc """
  A WebSocket client (RFC 6455) that lives inside the user's own process, so a
  thousand sockets are a thousand processes, not two thousand.

  `connect/3` does the upgrade and checks the server's accept key. `feed/2`
  turns bytes off the wire into whole messages: it joins fragments, answers
  pings with pongs, and answers a close. Frames out are masked, as a client's
  must be.
  """

  alias StressTester.Net

  defstruct [:sock, buf: <<>>, frag: nil, closed: false]

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # {:ok, ws, %{connect_us, tls_us?, upgrade_us}} | {:error, reason}
  def connect(origin, opts \\ %{}, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    key = Base.encode64(:crypto.strong_rand_bytes(16))
    path = opts[:path] || origin.path || "/"
    host = if origin.port in [80, 443], do: origin.host, else: "#{origin.host}:#{origin.port}"

    protocols =
      case opts[:protocols] do
        nil -> []
        list -> ["sec-websocket-protocol: ", Enum.join(List.wrap(list), ", "), "\r\n"]
      end

    head = [
      "GET ",
      path,
      " HTTP/1.1\r\nhost: ",
      host,
      "\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-key: ",
      key,
      "\r\nsec-websocket-version: 13\r\n",
      protocols,
      Enum.map(opts[:headers] || [], fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n"
    ]

    with {:ok, sock, timing} <- Net.connect(origin, opts, timeout),
         t0 = Net.now(),
         :ok <- Net.send(sock, head),
         {:ok, rest} <- upgrade(sock, <<>>, key, deadline) do
      {:ok, %__MODULE__{sock: sock, buf: rest}, Map.put(timing, :upgrade_us, Net.now() - t0)}
    end
  end

  defp upgrade(sock, buf, key, deadline) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, rest] ->
        [status | lines] = String.split(head, "\r\n")
        accept = :crypto.hash(:sha, key <> @guid) |> Base.encode64()

        headers =
          Map.new(lines, fn line ->
            case String.split(line, ":", parts: 2) do
              [k, v] -> {String.downcase(String.trim(k)), String.trim(v)}
              [k] -> {String.downcase(k), ""}
            end
          end)

        cond do
          not String.starts_with?(status, "HTTP/1.1 101") -> close_with(sock, {:upgrade, status})
          headers["sec-websocket-accept"] != accept -> close_with(sock, :bad_accept_key)
          true -> {:ok, rest}
        end

      [_] ->
        case Net.recv(sock, 0, max(deadline - System.monotonic_time(:millisecond), 0)) do
          {:ok, data} -> upgrade(sock, buf <> data, key, deadline)
          {:error, reason} -> close_with(sock, reason)
        end
    end
  end

  defp close_with(sock, reason) do
    Net.close(sock)
    {:error, reason}
  end

  def text(ws, data), do: send_frame(ws, 1, data)
  def binary(ws, data), do: send_frame(ws, 2, data)
  def ping(ws, data \\ ""), do: send_frame(ws, 9, data)

  def close(ws, code \\ 1000)
  def close(%{closed: true} = ws, _code), do: Net.close(ws.sock)

  def close(ws, code) do
    _ = send_frame(ws, 8, <<code::16>>)
    Net.close(ws.sock)
  end

  def send_frame(ws, opcode, payload), do: Net.send(ws.sock, frame(opcode, payload))

  def frame(opcode, payload) do
    payload = IO.iodata_to_binary(payload)
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)

    size =
      cond do
        len < 126 -> <<1::1, len::7>>
        len < 65_536 -> <<1::1, 126::7, len::16>>
        true -> <<1::1, 127::7, len::64>>
      end

    [<<1::1, 0::3, opcode::4>>, size, mask, unmask(payload, mask)]
  end

  # a passive read: {:ok, ws, messages} | {:error, reason}
  def recv(ws, timeout) do
    case Net.recv(ws.sock, 0, timeout) do
      {:ok, data} -> feed(ws, data)
      {:error, reason} -> {:error, reason}
    end
  end

  def active(ws, n), do: Net.setopts(ws.sock, active: n)

  # bytes in, whole messages out: {:text, b} | {:binary, b} | {:pong, b} | {:close, code, reason}
  def feed(ws, data) do
    take(%{ws | buf: ws.buf <> data}, [])
  end

  defp take(ws, out) do
    case parse(ws.buf) do
      :more ->
        {:ok, ws, Enum.reverse(out)}

      {:error, reason} ->
        {:error, reason}

      {fin, op, payload, rest} ->
        ws = %{ws | buf: rest}

        case message(ws, fin, op, payload) do
          {:ok, ws, nil} -> take(ws, out)
          {:ok, ws, msg} -> take(ws, [msg | out])
          {:error, _} = error -> error
        end
    end
  end

  defp message(ws, _fin, 9, payload) do
    _ = send_frame(ws, 10, payload)
    {:ok, ws, nil}
  end

  defp message(ws, _fin, 10, payload), do: {:ok, ws, {:pong, payload}}

  defp message(ws, _fin, 8, payload) do
    {code, reason} =
      case payload do
        <<code::16, reason::binary>> -> {code, reason}
        _ -> {1005, ""}
      end

    unless ws.closed, do: send_frame(ws, 8, <<code::16>>)
    {:ok, %{ws | closed: true}, {:close, code, reason}}
  end

  defp message(%{frag: nil} = ws, 1, op, payload) when op in [1, 2],
    do: {:ok, ws, data(op, payload)}

  defp message(%{frag: nil} = ws, 0, op, payload) when op in [1, 2],
    do: {:ok, %{ws | frag: {op, [payload]}}, nil}

  defp message(%{frag: {op, parts}} = ws, 0, 0, payload),
    do: {:ok, %{ws | frag: {op, [parts | payload]}}, nil}

  defp message(%{frag: {op, parts}} = ws, 1, 0, payload),
    do: {:ok, %{ws | frag: nil}, data(op, IO.iodata_to_binary([parts | payload]))}

  defp message(_ws, _fin, op, _payload), do: {:error, {:unexpected_opcode, op}}

  defp data(1, payload), do: {:text, payload}
  defp data(2, payload), do: {:binary, payload}

  defp parse(<<fin::1, _rsv::3, op::4, masked::1, len::7, rest::binary>>) do
    with {:ok, len, rest} <- size_of(len, rest),
         {:ok, mask, rest} <- mask(masked, rest),
         true <- byte_size(rest) >= len || :more do
      <<payload::binary-size(len), rest::binary>> = rest
      payload = if mask, do: unmask(payload, mask), else: payload
      {fin, op, payload, rest}
    end
  end

  defp parse(_), do: :more

  defp size_of(126, <<len::16, rest::binary>>), do: {:ok, len, rest}
  defp size_of(127, <<len::64, rest::binary>>), do: {:ok, len, rest}
  defp size_of(n, rest) when n < 126, do: {:ok, n, rest}
  defp size_of(_, _), do: :more

  defp mask(0, rest), do: {:ok, nil, rest}
  defp mask(1, <<m::binary-4, rest::binary>>), do: {:ok, m, rest}
  defp mask(1, _), do: :more

  # xor with the 4-byte key repeated, in one call
  def unmask(<<>>, _mask), do: <<>>

  def unmask(payload, mask) do
    n = byte_size(payload)
    keys = mask |> :binary.copy(div(n, 4) + 1) |> binary_part(0, n)
    :crypto.exor(payload, keys)
  end

  def owns?(%__MODULE__{sock: sock}, s), do: Net.raw(sock) == s
end
