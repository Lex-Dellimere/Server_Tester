defmodule StressTester.Tcp do
  @moduledoc "Writes one line at a time to any TCP port and counts the replies."

  @behaviour StressTester.Profile

  @impl true
  def prepare(opts), do: Map.put_new(opts, :payload, "ping\n")

  @impl true
  def plan(opts), do: Enum.to_list(1..opts.workers)

  @impl true
  def open(opts, _id) do
    started = System.monotonic_time(:microsecond)

    {:ok, sock} =
      :gen_tcp.connect(addr(opts.host), opts.port, [:binary, packet: :line, active: false], 3_000)

    joined = System.monotonic_time(:microsecond)
    %{sock: sock, connect_us: joined - started, join_us: joined - started}
  end

  @impl true
  def close(%{sock: sock}), do: :gen_tcp.close(sock)

  @impl true
  def drive(session, opts) do
    deadline = System.monotonic_time(:millisecond) + opts.seconds * 1_000
    step = max(div(1_000, max(opts.hz, 1)), 1)

    {sent, got} =
      loop(session.sock, deadline, System.monotonic_time(:millisecond), step, opts.payload, 0, 0)

    %{
      group: nil,
      sent: %{"messages" => sent},
      got: %{"messages" => got},
      connect_us: session.connect_us,
      join_us: session.join_us
    }
  end

  @impl true
  def expect(_rows), do: %{"messages" => 0}

  @impl true
  def auth_rejected?(_opts), do: true

  @impl true
  def reconnect?(opts) do
    first = open(opts, 1)
    close(first)
    second = open(opts, 2)
    close(second)
    true
  end

  @impl true
  def ok?(report) do
    report.joined == report.workers and report.kinds["messages"].received > 0 and report.reconnect
  end

  defp loop(sock, deadline, next, step, payload, sent, got) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {sent, got}
    else
      {sent, next} =
        if now >= next do
          :ok = :gen_tcp.send(sock, payload)
          {sent + 1, now + step}
        else
          {sent, next}
        end

      got =
        case :gen_tcp.recv(
               sock,
               0,
               max(min(next, deadline) - System.monotonic_time(:millisecond), 1)
             ) do
          {:ok, _data} -> got + 1
          _ -> got
        end

      loop(sock, deadline, next, step, payload, sent, got)
    end
  end

  defp addr(host) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    ip
  end
end
