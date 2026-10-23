defmodule StressTester.Test.TinyServer do
  @moduledoc false
  # a scripted HTTP/1.1 server: the handler decides each answer, byte for byte

  # handler: fn %{method, path, headers, body}, conn_no -> {:reply, iodata} | {:reply_close, iodata} | :close end
  # returns {port, connections_counter}
  def start(handler) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    conns = :counters.new(1, [])
    spawn_link(fn -> accept(listen, handler, conns) end)
    {port, conns}
  end

  def connections(counter), do: :counters.get(counter, 1)

  # the same, over TLS with a certificate made on the spot that nothing trusts
  def start_tls(handler) do
    {:ok, _} = Application.ensure_all_started(:ssl)

    # sha256: the default (sha1) signature is refused by a modern client, and the server then has no certificate it may offer
    ec = [key: {:namedCurve, :secp256r1}, digest: :sha256]
    chain = %{root: ec, peer: ec}

    %{server_config: config, client_config: client} =
      :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})

    {:ok, listen} =
      :ssl.listen(0, config ++ [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :ssl.sockname(listen)
    conns = :counters.new(1, [])
    spawn(fn -> accept_tls(listen, handler, conns) end)
    {port, conns, client[:cacerts]}
  end

  # each connection is accepted, shaken hands with, and served by one process; it starts the next acceptor first
  defp accept_tls(listen, handler, conns) do
    case :ssl.transport_accept(listen) do
      {:ok, tcp} ->
        spawn(fn -> accept_tls(listen, handler, conns) end)
        :counters.add(conns, 1, 1)
        n = :counters.get(conns, 1)

        case :ssl.handshake(tcp, 5_000) do
          {:ok, sock} -> serve_tls(sock, handler, n)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp serve_tls(sock, handler, n) do
    case :ssl.recv(sock, 0, 5_000) do
      {:ok, data} ->
        [line | _] = String.split(data, "\r\n")
        [method, path | _] = String.split(line, " ")

        case handler.(%{method: method, path: path, headers: %{}, body: ""}, n) do
          {:reply, out} ->
            :ssl.send(sock, out)
            serve_tls(sock, handler, n)

          _ ->
            :ssl.close(sock)
        end

      _ ->
        :ssl.close(sock)
    end
  end

  defp accept(listen, handler, conns) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        :counters.add(conns, 1, 1)
        n = :counters.get(conns, 1)
        pid = spawn(fn -> serve(sock, handler, n, <<>>) end)
        :gen_tcp.controlling_process(sock, pid)
        accept(listen, handler, conns)

      _ ->
        :ok
    end
  end

  defp serve(sock, handler, n, buf) do
    case request(sock, buf) do
      {:ok, req, rest} ->
        case handler.(req, n) do
          {:reply, data} ->
            :gen_tcp.send(sock, data)
            serve(sock, handler, n, rest)

          {:reply_close, data} ->
            :gen_tcp.send(sock, data)
            :gen_tcp.close(sock)

          :close ->
            :gen_tcp.close(sock)
        end

      :closed ->
        :gen_tcp.close(sock)
    end
  end

  defp request(sock, buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, rest] ->
        [line | lines] = String.split(head, "\r\n")
        [method, path | _] = String.split(line, " ")

        headers =
          Map.new(lines, fn l ->
            [k, v] = String.split(l, ":", parts: 2)
            {String.downcase(k), String.trim(v)}
          end)

        want = String.to_integer(headers["content-length"] || "0")
        body(sock, %{method: method, path: path, headers: headers}, rest, want)

      [_] ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, data} -> request(sock, buf <> data)
          _ -> :closed
        end
    end
  end

  defp body(_sock, req, rest, want) when byte_size(rest) >= want do
    <<b::binary-size(want), more::binary>> = rest
    {:ok, Map.put(req, :body, b), more}
  end

  defp body(sock, req, rest, want) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> body(sock, req, rest <> data, want)
      _ -> :closed
    end
  end
end
