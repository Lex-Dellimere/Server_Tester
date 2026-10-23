defmodule StressTester.Dashboard.Server do
  @moduledoc """
  The dashboard's door: a small HTTP/1.1 server on 127.0.0.1, one process per
  connection. It serves the page, a JSON API, and a live stream of the run
  (`text/event-stream`, which a browser reads with `EventSource`).

      GET  /                 the page
      GET  /api/state        what is running, the tests on offer, past runs
      POST /api/run          start a test (JSON: test, address, players, …)
      POST /api/stop         stop the test that is running
      GET  /api/events       the live stream
      GET  /api/health?address=127.0.0.1:4001   is that server up?
      GET  /reports/:id      a past run as a full HTML report

  It listens on localhost only: anyone who can reach it can start load tests.
  """

  require Logger

  alias StressTester.Dashboard.Control
  alias StressTester.{History, Html}

  @page_path Path.join(__DIR__, "page.html")
  @external_resource @page_path
  @page File.read!(@page_path)

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    port = Keyword.get(opts, :port, 4100)

    case :gen_tcp.listen(port, [
           :binary,
           packet: :raw,
           active: false,
           reuseaddr: true,
           ip: {127, 0, 0, 1}
         ]) do
      {:ok, listen} ->
        pid = spawn_link(fn -> accept(listen) end)
        :gen_tcp.controlling_process(listen, pid)
        {:ok, real} = :inet.port(listen)
        :persistent_term.put({__MODULE__, :port}, real)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def port, do: :persistent_term.get({__MODULE__, :port}, nil)

  defp accept(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        pid = spawn(fn -> serve(sock) end)
        :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept(listen)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept(listen)
    end
  end

  defp serve(sock) do
    receive do
      :go -> :ok
    end

    case read(sock, <<>>) do
      {:ok, req} ->
        req |> route() |> reply(sock, req)

      :closed ->
        :gen_tcp.close(sock)
    end
  end

  # -- reading a request

  defp read(sock, buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, rest] ->
        [line | lines] = String.split(head, "\r\n")

        case String.split(line, " ") do
          [method, target, _version] ->
            headers =
              Map.new(lines, fn l ->
                case String.split(l, ":", parts: 2) do
                  [k, v] -> {String.downcase(k), String.trim(v)}
                  [k] -> {String.downcase(k), ""}
                end
              end)

            uri = URI.parse(target)
            want = String.to_integer(headers["content-length"] || "0")

            with {:ok, body} <- body(sock, rest, min(want, 65_536)) do
              {:ok,
               %{
                 method: method,
                 path: uri.path,
                 query: URI.decode_query(uri.query || ""),
                 headers: headers,
                 body: body
               }}
            end

          _ ->
            :closed
        end

      [_] ->
        if byte_size(buf) > 16_384 do
          :closed
        else
          case :gen_tcp.recv(sock, 0, 10_000) do
            {:ok, data} -> read(sock, buf <> data)
            _ -> :closed
          end
        end
    end
  end

  defp body(_sock, rest, want) when byte_size(rest) >= want, do: {:ok, binary_part(rest, 0, want)}

  defp body(sock, rest, want) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} -> body(sock, rest <> data, want)
      _ -> :closed
    end
  end

  # -- what each address does

  defp route(%{method: "GET", path: "/"}), do: {200, "text/html; charset=utf-8", @page}
  defp route(%{method: "GET", path: "/api/state"}), do: json(200, Control.state())
  defp route(%{method: "GET", path: "/api/events"}), do: :stream

  defp route(%{method: "GET", path: "/api/health", query: q}),
    do: json(200, Control.health(q["address"] || ""))

  defp route(%{method: "POST", path: "/api/run"} = req) do
    with {:ok, params} <- decode(req.body),
         {:ok, run} <- Control.run(params) do
      json(202, run)
    else
      {:error, :busy} -> json(409, %{"error" => "a test is already running; stop it first"})
      {:error, message} -> json(400, %{"error" => to_string(message)})
    end
  end

  defp route(%{method: "POST", path: "/api/stop"}) do
    case Control.stop() do
      :ok -> json(200, %{"ok" => true})
      {:error, :idle} -> json(409, %{"error" => "nothing is running"})
    end
  end

  defp route(%{method: "GET", path: "/reports/" <> id}) do
    with {n, ""} <- Integer.parse(id),
         %{} = report <- History.get(n) do
      {200, "text/html; charset=utf-8", Html.render(report)}
    else
      _ -> {404, "text/plain", "no such run"}
    end
  end

  defp route(_req), do: {404, "text/plain", "not found"}

  defp decode(""), do: {:ok, %{}}

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, "the request body is not a JSON object"}
    end
  end

  defp json(status, data), do: {status, "application/json", JSON.encode!(data)}

  # -- answering

  defp reply(:stream, sock, _req) do
    :gen_tcp.send(sock, [
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-cache\r\n",
      "connection: keep-alive\r\n\r\n",
      ": the run, live\n\n"
    ])

    :inet.setopts(sock, active: :once)
    # if the controller restarts, end this stream; the browser reconnects to the new one
    control = Process.monitor(Process.whereis(Control))
    Control.subscribe(self())
    stream(sock, control)
  end

  defp reply({status, type, body}, sock, _req) do
    :gen_tcp.send(sock, [
      "HTTP/1.1 #{status} #{reason(status)}\r\ncontent-type: #{type}\r\n",
      "content-length: #{IO.iodata_length(body)}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n",
      body
    ])

    :gen_tcp.close(sock)
  end

  # one event each time the run says something; a comment now and then keeps proxies from closing it
  defp stream(sock, control) do
    receive do
      {:event, name, data} ->
        case :gen_tcp.send(sock, ["event: ", name, "\ndata: ", JSON.encode!(data), "\n\n"]) do
          :ok -> stream(sock, control)
          {:error, _} -> :gen_tcp.close(sock)
        end

      {:tcp_closed, ^sock} ->
        :ok

      {:tcp, ^sock, _data} ->
        :inet.setopts(sock, active: :once)
        stream(sock, control)

      {:DOWN, ^control, :process, _pid, _reason} ->
        :gen_tcp.close(sock)
    after
      15_000 ->
        case :gen_tcp.send(sock, ": still here\n\n") do
          :ok -> stream(sock, control)
          {:error, _} -> :gen_tcp.close(sock)
        end
    end
  end

  defp reason(200), do: "OK"
  defp reason(202), do: "Accepted"
  defp reason(400), do: "Bad Request"
  defp reason(404), do: "Not Found"
  defp reason(409), do: "Conflict"
  defp reason(_), do: "OK"
end
