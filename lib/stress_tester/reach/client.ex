defmodule StressTester.Reach.Client do
  @moduledoc "One bot. It logs in on TCP, then speaks UDP."

  alias StressTester.Reach.Wire

  def login_status(host, port, name, password, planet) do
    case post(host, port, name, password, planet) do
      {:ok, status, _body} -> status
      {:error, _reason} -> 0
    end
  end

  def open(opts, name, planet) do
    started = System.monotonic_time(:microsecond)

    case post(opts.host, opts.port, name, "stress", planet) do
      {:ok, 200, body} ->
        connect(opts, JSON.decode!(body), started)

      other ->
        raise "login failed for #{name}: #{inspect(other)}"
    end
  end

  def close(%{sock: sock}), do: :gen_udp.close(sock)

  def play(client, opts) do
    deadline = now_ms() + opts.seconds * 1_000
    step = max(div(1_000, max(opts.hz, 1)), 1)
    acc = run(client, deadline, now_ms(), now_ms(), step, opts.chat_ms, blank())

    %{
      group: client.faction,
      sent: %{"state" => acc.inputs, "chat" => acc.chats, "event" => 0},
      got: %{"state" => acc.snaps, "chat" => acc.heard, "event" => 0},
      connect_us: client.connect_us,
      join_us: client.join_us
    }
  end

  defp connect(opts, body, started) do
    key = Base.decode16!(body["session_key"], case: :lower)
    token = Base.decode16!(body["token"], case: :lower)
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    ip = addr(opts.host)
    :ok = :gen_udp.send(sock, ip, body["udp_port"], Wire.pack(1, 0, 0, token))

    case wait_kind(sock, key, 2, 1_500) do
      {:ok, _slot, _seq, plain} ->
        {:ok, accept} = Wire.unpack_accept(plain)
        joined = System.monotonic_time(:microsecond)

        %{
          sock: sock,
          key: key,
          ip: ip,
          port: body["udp_port"],
          slot: accept.slot,
          seq: 1,
          tick: accept.tick,
          faction: body["faction"],
          connect_us: joined - started,
          join_us: joined - started
        }

      :error ->
        :gen_udp.close(sock)
        raise "udp connect failed"
    end
  end

  defp run(client, deadline, next_input, next_chat, step, chat_ms, acc) do
    now = now_ms()

    if now >= deadline do
      acc
    else
      {client, acc, next_input} = maybe_input(client, acc, now, next_input, step)
      {client, acc, next_chat} = maybe_chat(client, acc, now, next_chat, chat_ms)
      timeout = max(min(next_input, next_chat) - now_ms(), 1) |> min(max(deadline - now_ms(), 1))

      {client, acc} =
        case :gen_udp.recv(client.sock, 0, timeout) do
          {:ok, {_ip, _port, data}} -> note(client, data, acc)
          _ -> {client, acc}
        end

      {client, acc} = drain(client, acc)
      run(client, deadline, next_input, next_chat, step, chat_ms, acc)
    end
  end

  defp maybe_input(client, acc, now, next_input, step) do
    if now >= next_input do
      {send_kind(client, 4, Wire.pack_input(client.tick)), %{acc | inputs: acc.inputs + 1},
       now + step}
    else
      {client, acc, next_input}
    end
  end

  defp maybe_chat(client, acc, now, next_chat, chat_ms) do
    if now >= next_chat do
      {send_kind(client, 5, Wire.pack_chat("hi")), %{acc | chats: acc.chats + 1}, now + chat_ms}
    else
      {client, acc, next_chat}
    end
  end

  defp drain(client, acc) do
    case :gen_udp.recv(client.sock, 0, 0) do
      {:ok, {_ip, _port, data}} ->
        {client, acc} = note(client, data, acc)
        drain(client, acc)

      _ ->
        {client, acc}
    end
  end

  defp note(client, data, acc) do
    case Wire.open(client.key, 1, data) do
      {:ok, 4, _slot, _seq, plain} ->
        {%{client | tick: Wire.snapshot_tick(plain)}, %{acc | snaps: acc.snaps + 1}}

      {:ok, 5, _slot, seq, plain} ->
        client = send_kind(client, 6, <<seq::unsigned-little-32>>)
        acc = if Wire.chat?(plain), do: %{acc | heard: acc.heard + 1}, else: acc
        {client, acc}

      _ ->
        {client, acc}
    end
  end

  defp send_kind(client, kind, plain) do
    packet = Wire.seal(client.key, kind, client.slot, client.seq, 0, plain)
    :ok = :gen_udp.send(client.sock, client.ip, client.port, packet)
    %{client | seq: client.seq + 1}
  end

  defp wait_kind(sock, key, kind, timeout) do
    deadline = now_ms() + timeout

    Stream.repeatedly(fn -> :gen_udp.recv(sock, 0, max(deadline - now_ms(), 1)) end)
    |> Enum.find_value(fn
      {:ok, {_ip, _port, data}} ->
        case Wire.open(key, 1, data) do
          {:ok, ^kind, slot, seq, plain} -> {:ok, slot, seq, plain}
          _ -> nil
        end

      _ ->
        :error
    end)
  end

  defp post(host, port, name, password, planet) do
    body = JSON.encode!(%{"name" => name, "password" => password, "planet" => planet})

    req =
      "POST /login HTTP/1.1\r\nHost: #{host}\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
        body

    {:ok, sock} = :gen_tcp.connect(addr(host), port, [:binary, active: false], 3_000)
    :ok = :gen_tcp.send(sock, req)

    case recv_all(sock, <<>>) do
      {:ok, raw} ->
        :gen_tcp.close(sock)
        parse_http(raw)

      {:error, reason} ->
        :gen_tcp.close(sock)
        {:error, reason}
    end
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_http(raw) do
    case String.split(raw, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [line | _] = String.split(head, "\r\n")
        [_, code | _] = String.split(line, " ")
        {:ok, String.to_integer(code), body}

      _ ->
        {:error, :bad_http}
    end
  end

  defp addr(host) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    ip
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp blank, do: %{inputs: 0, chats: 0, snaps: 0, heard: 0}
end
