defmodule StressTester.Http do
  @moduledoc """
  An HTTP/1.1 client made for load: one connection per user and origin, kept
  open between requests the way a browser or game client keeps it. Responses
  are read with the VM's own HTTP parser (`:erlang.decode_packet/3`), with
  bodies by length, chunked, or until close.

  A request that finds its kept-open connection already closed by the server
  is sent once more on a fresh one; that is the server's right under HTTP/1.1,
  not an error. Each response says how long the connect, the TLS handshake, and
  the first byte took.
  """

  alias StressTester.Net

  defstruct [:origin, :sock, opts: %{}, requests: 0]

  def new(origin, opts \\ %{}), do: %__MODULE__{origin: origin, opts: opts}

  def close(%__MODULE__{sock: nil} = c), do: c

  def close(c) do
    Net.close(c.sock)
    %{c | sock: nil, requests: 0}
  end

  # {:ok, conn, %{status, headers, body, ttfb_us, bytes, connect_us?, tls_us?}} | {:error, conn, reason}
  def request(conn, method, path, headers, body, timeout) do
    deadline = now_ms() + timeout
    reused = conn.sock != nil

    case attempt(conn, method, path, headers, body, deadline) do
      {:error, conn, {:stale, _}} when reused ->
        case attempt(conn, method, path, headers, body, deadline) do
          {:error, conn, {:stale, reason}} -> {:error, conn, reason}
          other -> other
        end

      {:error, conn, {:stale, reason}} ->
        {:error, conn, reason}

      other ->
        other
    end
  end

  defp attempt(conn, method, path, headers, body, deadline) do
    with {:ok, conn, timing} <- ensure(conn, deadline),
         :ok <- write(conn, method, path, headers, body),
         {:ok, resp} <- read(conn.sock, method, deadline, conn.requests > 0) do
      conn = %{conn | requests: conn.requests + 1}
      conn = if resp.close, do: close(conn), else: conn
      {:ok, conn, Map.merge(Map.delete(resp, :close), timing)}
    else
      {:error, reason} -> {:error, close(conn), reason}
      {:error, conn, reason} -> {:error, close(conn), reason}
    end
  end

  defp ensure(%{sock: nil} = conn, deadline) do
    case Net.connect(conn.origin, conn.opts, remaining(deadline)) do
      {:ok, sock, timing} -> {:ok, %{conn | sock: sock, requests: 0}, timing}
      {:error, reason} -> {:error, conn, reason}
    end
  end

  defp ensure(conn, _deadline), do: {:ok, conn, %{}}

  defp write(conn, method, path, headers, body) do
    host = conn.origin.host
    port = conn.origin.port
    default = if conn.origin.tls, do: 443, else: 80
    host = if port == default, do: host, else: "#{host}:#{port}"

    sized =
      if body == nil and method in ["GET", "HEAD", "DELETE", "OPTIONS"],
        do: [],
        else: ["content-length: ", Integer.to_string(IO.iodata_length(body || "")), "\r\n"]

    data = [
      method,
      " ",
      path,
      " HTTP/1.1\r\nhost: ",
      host,
      "\r\n",
      Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      sized,
      "\r\n",
      body || ""
    ]

    case Net.send(conn.sock, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:stale, reason}}
    end
  end

  # -- the answer

  defp read(sock, method, deadline, reused) do
    sent = Net.now()

    with {:ok, buf, first} <- first_bytes(sock, deadline, reused),
         {:ok, version, status, buf} <- status_line(sock, buf, deadline),
         {:ok, headers, buf} <- header_lines(sock, buf, deadline, []) do
      if status in 100..199 and status != 101 do
        # an interim answer; the real one follows
        read_after_interim(sock, method, deadline, buf, sent, first)
      else
        body_and_finish(sock, method, deadline, version, status, headers, buf, first - sent)
      end
    end
  end

  defp read_after_interim(sock, method, deadline, buf, sent, first) do
    with {:ok, version, status, buf} <- status_line(sock, buf, deadline),
         {:ok, headers, buf} <- header_lines(sock, buf, deadline, []) do
      body_and_finish(sock, method, deadline, version, status, headers, buf, first - sent)
    end
  end

  defp body_and_finish(sock, method, deadline, version, status, headers, buf, ttfb) do
    connection = header(headers, "connection") |> String.downcase()

    closing =
      String.contains?(connection, "close") or
        (version == {1, 0} and not String.contains?(connection, "keep-alive"))

    result =
      cond do
        method == "HEAD" or status in [204, 304] or status in 100..199 ->
          {:ok, "", false}

        header(headers, "transfer-encoding")
        |> String.downcase()
        |> String.contains?("chunked") ->
          chunked(sock, buf, deadline, [])

        (len = header(headers, "content-length")) != "" ->
          case Integer.parse(len) do
            {n, _} -> sized(sock, buf, n, deadline)
            :error -> {:error, :bad_length}
          end

        true ->
          until_close(sock, buf, deadline)
      end

    case result do
      {:ok, body, closed} ->
        {:ok,
         %{
           status: status,
           headers: headers,
           body: body,
           ttfb_us: ttfb,
           bytes: byte_size(body),
           close: closing or closed
         }}

      {:error, _} = error ->
        error
    end
  end

  defp first_bytes(sock, deadline, reused) do
    case Net.recv(sock, 0, remaining(deadline)) do
      {:ok, data} -> {:ok, data, Net.now()}
      {:error, :closed} when reused -> {:error, {:stale, :closed}}
      {:error, :econnreset} when reused -> {:error, {:stale, :econnreset}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp status_line(sock, buf, deadline) do
    case :erlang.decode_packet(:http_bin, buf, []) do
      {:ok, {:http_response, version, status, _reason}, rest} -> {:ok, version, status, rest}
      {:ok, {:http_error, line}, _} -> {:error, {:bad_status_line, String.slice(line, 0, 60)}}
      {:ok, _other, _} -> {:error, :bad_status_line}
      {:more, _} -> more(sock, buf, deadline, &status_line/3)
      {:error, reason} -> {:error, {:bad_status_line, reason}}
    end
  end

  defp header_lines(sock, buf, deadline, acc) do
    case :erlang.decode_packet(:httph_bin, buf, []) do
      {:ok, {:http_header, _n, name, _orig, value}, rest} ->
        header_lines(sock, rest, deadline, [
          {name |> to_string() |> String.downcase(), value} | acc
        ])

      {:ok, :http_eoh, rest} ->
        {:ok, Enum.reverse(acc), rest}

      {:ok, {:http_error, _line}, rest} ->
        header_lines(sock, rest, deadline, acc)

      {:more, _} ->
        more(sock, buf, deadline, fn s, b, d -> header_lines(s, b, d, acc) end)

      {:error, reason} ->
        {:error, {:bad_header, reason}}
    end
  end

  defp more(sock, buf, deadline, next) do
    case Net.recv(sock, 0, remaining(deadline)) do
      {:ok, data} -> next.(sock, buf <> data, deadline)
      {:error, reason} -> {:error, reason}
    end
  end

  defp sized(_sock, buf, n, _deadline) when byte_size(buf) >= n,
    do: {:ok, binary_part(buf, 0, n), false}

  defp sized(sock, buf, n, deadline) do
    case Net.recv(sock, n - byte_size(buf), remaining(deadline)) do
      {:ok, data} -> sized(sock, buf <> data, n, deadline)
      {:error, reason} -> {:error, reason}
    end
  end

  defp chunked(sock, buf, deadline, acc) do
    case :binary.split(buf, "\r\n") do
      [line, rest] ->
        size = line |> String.split(";", parts: 2) |> hd() |> String.trim()

        case Integer.parse(size, 16) do
          {0, ""} ->
            trailers(sock, rest, deadline, acc)

          {n, ""} when byte_size(rest) >= n + 2 ->
            <<chunk::binary-size(n), "\r\n", more::binary>> = rest
            chunked(sock, more, deadline, [acc | chunk])

          {_n, ""} ->
            more(sock, buf, deadline, fn s, b, d -> chunked(s, b, d, acc) end)

          _ ->
            {:error, :bad_chunk}
        end

      [_] ->
        more(sock, buf, deadline, fn s, b, d -> chunked(s, b, d, acc) end)
    end
  end

  defp trailers(sock, buf, deadline, acc) do
    cond do
      String.starts_with?(buf, "\r\n") -> {:ok, IO.iodata_to_binary(acc), false}
      String.contains?(buf, "\r\n\r\n") -> {:ok, IO.iodata_to_binary(acc), false}
      true -> more(sock, buf, deadline, fn s, b, d -> trailers(s, b, d, acc) end)
    end
  end

  defp until_close(sock, buf, deadline) do
    case Net.recv(sock, 0, remaining(deadline)) do
      {:ok, data} -> until_close(sock, buf <> data, deadline)
      {:error, :closed} -> {:ok, buf, true}
      {:error, reason} -> {:error, reason}
    end
  end

  def header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, v} -> v
      nil -> ""
    end
  end

  defp remaining(deadline), do: max(deadline - now_ms(), 0)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
