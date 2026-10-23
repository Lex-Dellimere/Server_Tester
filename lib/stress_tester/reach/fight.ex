defmodule StressTester.Reach.Fight do
  @moduledoc """
  One player's end of a Reach fight over UDP (protocol 2): what a game client
  does on that socket, with the numbers a load test wants.

    1. `open/2` sends the ticket until the server accepts or denies, then
       answers the accept with a sealed ack (the server sends nothing else
       until it hears one).
    2. `packet/2` takes each datagram: decrypt, drop replays, decode the
       snapshot against the baseline it names, ack and deliver reliable
       messages in order.
    3. `input/2` sends one input packet (the last three frames, the newest
       snapshot decoded, the clock, the reliable ack).

  The caller owns the socket's messages (`{:udp, …}`) and calls `packet/2`.
  Counters go to `StressTester.Metrics` as they happen and are kept in
  `counts` too, so a one-off check can read them without a run.
  """

  import Bitwise

  alias StressTester.{Metrics, Net}
  alias StressTester.Reach.{Lane, Snapshot, Wire}

  @keep 64
  @active 200

  defstruct [
    :sock,
    :ip,
    :port,
    :key,
    :slot,
    :tick_ms,
    :every,
    :place,
    rejoined: false,
    out_seq: 1,
    in_max: 0,
    seen: 0,
    lane: nil,
    states: %{},
    latest: 0,
    me: nil,
    pos: nil,
    frames: [],
    last_tick: 0,
    over: false,
    snap_first: nil,
    snap_max: 0,
    snap_got: 0,
    counts: %{
      snapshots: 0,
      decode_errors: 0,
      corrections: 0,
      messages: 0,
      hits: 0,
      kills: 0,
      deaths: 0,
      chats: 0
    }
  ]

  # -- connecting

  # ticket: the decoded JSON of a ticket reply or an mm.matched push
  def open(ticket, opts \\ %{}) do
    timeout = opts[:timeout] || 5_000
    udp = ticket["udp"] || %{}
    host = opts[:udp_host] || udp["host"]

    with {:ok, host} <- present(host, :no_udp_host),
         {:ok, ip} <- Net.resolve(host),
         {:ok, bytes} <- hex(ticket["ticket"]),
         {:ok, key} <- hex(ticket["key"]),
         :ok <- if(byte_size(key) == 32, do: :ok, else: {:error, :bad_key}),
         {:ok, port} <- present(udp["port"], :no_udp_port),
         {:ok, sock} <-
           :gen_udp.open(0, [:binary, active: false, recbuf: 1_048_576] ++ Net.family(ip)) do
      f = %__MODULE__{sock: sock, ip: ip, port: port, key: key, lane: Lane.new()}

      case handshake(f, bytes, Metrics.now(), now_ms() + timeout) do
        {:ok, f} ->
          :ok = :inet.setopts(sock, active: @active)
          {:ok, f}

        {:error, reason} ->
          :gen_udp.close(sock)
          {:error, reason}
      end
    end
  end

  defp present(v, error), do: if(v in [nil, ""], do: {:error, error}, else: {:ok, v})

  defp hex(text) when is_binary(text) do
    case Base.decode16(text, case: :mixed) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :bad_hex}
    end
  end

  defp hex(_), do: {:error, :bad_hex}

  # connect every 200 ms until an accept or a deny
  defp handshake(f, ticket, started, deadline) do
    if now_ms() >= deadline do
      {:error, :no_accept}
    else
      _ = :gen_udp.send(f.sock, f.ip, f.port, Wire.pack(Wire.connect(), 0, 0, ticket))

      case reply(f, now_ms() + 200) do
        {:accept, f, accept} ->
          Metrics.since("reach.udp_connect", started)

          f = %{
            f
            | slot: accept.slot,
              latest: accept.tick,
              tick_ms: accept.tick_ms,
              every: accept.every,
              place: accept.place,
              rejoined: accept.rejoin
          }

          {:ok, send_packet(f, Wire.ack(), Wire.pack_ack(Lane.ack_state(f.lane)))}

        {:deny, code} ->
          Metrics.count("reach.denied")
          {:error, {:denied, Wire.deny_reason(code)}}

        :none ->
          handshake(f, ticket, started, deadline)
      end
    end
  end

  defp reply(f, until) do
    left = until - now_ms()

    if left <= 0 do
      :none
    else
      case :gen_udp.recv(f.sock, 0, left) do
        {:ok, {_ip, _port, data}} ->
          case Wire.open(f.key, 1, data) do
            {:ok, 2, _slot, seq, plain} ->
              case Wire.unpack_accept(plain) do
                {:ok, accept} -> {:accept, mark(f, seq), accept}
                :error -> reply(f, until)
              end

            {:ok, 3, _slot, _seq, plain} ->
              case Wire.unpack_deny(plain) do
                {:ok, code} -> {:deny, code}
                :error -> reply(f, until)
              end

            _ ->
              reply(f, until)
          end

        {:error, :timeout} ->
          :none

        {:error, _reason} ->
          Process.sleep(20)
          reply(f, until)
      end
    end
  end

  # -- receiving

  def rearm(f), do: :inet.setopts(f.sock, active: @active)

  # {:ok, fight} | {:bye, reason, fight}
  def packet(f, data) do
    case Wire.open(f.key, 1, data) do
      {:ok, kind, _slot, seq, plain} ->
        if fresh?(f, seq) do
          Metrics.count("reach.bytes_in", byte_size(data))
          on_packet(mark(f, seq), kind, plain, byte_size(data))
        else
          Metrics.count("reach.duplicate")
          {:ok, f}
        end

      :error ->
        Metrics.count("reach.bad_packet")
        {:ok, f}
    end
  end

  defp on_packet(f, 4, plain, size) do
    with {:ok, head} <- Wire.unpack_snapshot(plain),
         {:ok, base} <- baseline(f, head.base),
         {:ok, held} <- Snapshot.decode(head.delta, base) do
      {next, bits} = head.ack
      Metrics.count("reach.snapshot")
      Metrics.observe("reach.snapshot_bytes", size, :bytes)
      rtt(head)

      f = %{
        f
        | lane: Lane.acked(f.lane, next, bits),
          states: f.states |> Map.put(head.tick, held) |> prune(head.tick),
          latest: max(f.latest, head.tick),
          me: head.me,
          snap_first: f.snap_first || head.tick,
          snap_max: max(f.snap_max, head.tick),
          snap_got: f.snap_got + 1
      }

      {:ok, count(f, :snapshots)}
    else
      error ->
        Metrics.count("reach.decode_error")

        Metrics.error(
          "snapshot",
          if(error == :no_base, do: "baseline missing", else: "cannot decode")
        )

        {:ok, count(f, :decode_errors)}
    end
  end

  defp on_packet(f, 5, plain, _size) do
    case Wire.unpack_reliable(plain) do
      {:ok, {next, bits}, messages} ->
        lane = Lane.acked(f.lane, next, bits)

        {lane, got} =
          Enum.reduce(messages, {lane, []}, fn {rseq, payload}, {lane, acc} ->
            {lane, more} = Lane.receive(lane, rseq, payload)
            {lane, acc ++ more}
          end)

        f = send_packet(%{f | lane: lane}, Wire.ack(), Wire.pack_ack(Lane.ack_state(lane)))
        {:ok, Enum.reduce(got, f, &message(&2, Wire.read_server(&1)))}

      :error ->
        Metrics.count("reach.bad_packet")
        {:ok, f}
    end
  end

  defp on_packet(f, 6, plain, _size) do
    case Wire.unpack_ack(plain) do
      {:ok, {next, bits}} -> {:ok, %{f | lane: Lane.acked(f.lane, next, bits)}}
      :error -> {:ok, f}
    end
  end

  defp on_packet(f, 7, <<reason::8>>, _size), do: {:bye, Wire.bye_reason(reason), f}
  defp on_packet(f, _kind, _plain, _size), do: {:ok, f}

  defp baseline(_f, 0), do: {:ok, nil}

  defp baseline(f, tick) do
    case f.states do
      %{^tick => base} -> {:ok, base}
      _ -> :no_base
    end
  end

  defp prune(states, tick) when map_size(states) > @keep,
    do: Map.reject(states, fn {t, _} -> t < tick - @keep end)

  defp prune(states, _tick), do: states

  # the server echoes our clock; the round trip is now − echo − the time it held it
  defp rtt(%{echo_ms: 0}), do: :ok

  defp rtt(head) do
    ms = now32() - head.echo_ms &&& 0xFFFFFFFF
    ms = ms - head.hold_ms
    if ms >= 0 and ms < 10_000, do: Metrics.observe("reach.rtt", ms * 1_000), else: :ok
  end

  # -- what the reliable lane brought

  defp message(f, {:correct, %{pos: pos, reason: reason}}) do
    Metrics.count("reach.correct")
    Metrics.count("reach.correct.#{reason}")
    f |> count(:messages) |> count(:corrections) |> Map.put(:pos, pos)
  end

  defp message(f, {:event, %{kind: 1, a: a}}) when a == f.slot do
    Metrics.count("reach.hit")
    f |> count(:messages) |> count(:hits)
  end

  defp message(f, {:event, %{kind: 8, a: victim, b: killer}}) do
    cond do
      killer == f.slot ->
        Metrics.count("reach.kill")
        f |> count(:messages) |> count(:kills)

      victim == f.slot ->
        Metrics.count("reach.death")
        f |> count(:messages) |> count(:deaths)

      true ->
        count(f, :messages)
    end
  end

  defp message(f, {:chat, _}) do
    Metrics.count("reach.chat_heard")
    f |> count(:messages) |> count(:chats)
  end

  defp message(f, {:result, _}) do
    Metrics.count("reach.result")
    %{count(f, :messages) | over: true}
  end

  defp message(f, :error) do
    Metrics.count("reach.unreadable_message")
    f
  end

  defp message(f, _other), do: count(f, :messages)

  defp count(f, key), do: %{f | counts: Map.update!(f.counts, key, &(&1 + 1))}

  # -- sending

  # fields: x y z vx vy vz yaw pitch buttons
  def input(f, fields) do
    tick = max(f.latest + 2, f.last_tick + 1) |> min(f.latest + 8)

    frame = %{
      tick: tick,
      view_tick: max(f.latest - 2, 0),
      x: fields.x,
      y: fields.y,
      z: fields.z,
      vx: fields.vx,
      vy: fields.vy,
      vz: fields.vz,
      yaw: fields.yaw,
      pitch: fields.pitch,
      posture: 0,
      weapon: 0,
      buttons: fields.buttons
    }

    frames = Enum.take([frame | Enum.reject(f.frames, &(&1.tick >= tick))], 3)
    plain = Wire.pack_input(f.latest, now32(), Lane.ack_state(f.lane), frames)
    Metrics.count("reach.input")
    f = send_packet(f, Wire.state(), plain)
    %{f | frames: frames, last_tick: tick, pos: {fields.x, fields.y, fields.z}}
  end

  # send a reliable message (chat, spawn request)
  def say(f, payload, now) do
    {lane, out} = Lane.push(f.lane, payload, now)
    send_reliable(%{f | lane: lane}, out)
  end

  # resend what was not acked in time
  def resend(f, now) do
    if Lane.pending(f.lane) == 0 do
      f
    else
      {lane, due} = Lane.due(f.lane, now)
      if due != [], do: Metrics.count("reach.resend", length(due))
      send_reliable(%{f | lane: lane}, due)
    end
  end

  defp send_reliable(f, []), do: f

  defp send_reliable(f, messages) do
    messages
    |> Enum.chunk_every(16)
    |> Enum.reduce(f, fn chunk, f ->
      send_packet(f, Wire.reliable(), Wire.pack_reliable(Lane.ack_state(f.lane), chunk))
    end)
  end

  def bye(f, reason \\ 0) do
    send_packet(f, Wire.bye(), Wire.pack_bye(reason))
    close(f)
  end

  def close(f) do
    account(f)
    :gen_udp.close(f.sock)
  end

  # The server numbers its snapshots by tick, so between the first and the newest we
  # know how many there should have been: the rest never arrived (or came too late).
  def account(f) do
    if f.snap_first do
      expected = div(f.snap_max - f.snap_first, max(f.every || 1, 1)) + 1
      Metrics.count("reach.snapshot_expected", expected)
      Metrics.count("reach.snapshot_lost", max(expected - f.snap_got, 0))
    end

    f
  end

  defp send_packet(f, kind, plain) do
    packet = Wire.seal(f.key, kind, f.slot || 0, f.out_seq, 0, plain)

    case :gen_udp.send(f.sock, f.ip, f.port, packet) do
      :ok ->
        Metrics.count("reach.packets_out")
        Metrics.count("reach.bytes_out", byte_size(packet))

      {:error, reason} ->
        Metrics.error("udp_send", reason)
    end

    %{f | out_seq: f.out_seq + 1}
  end

  # -- views for the bot and the checks

  def entities(f), do: Map.get(f.states, f.latest, %{})
  def self(f), do: Map.get(entities(f), f.slot)

  # -- the replay window: 64 packets behind the newest

  defp fresh?(f, seq) do
    cond do
      seq > f.in_max -> true
      f.in_max - seq >= 64 -> false
      true -> (f.seen &&& 1 <<< (f.in_max - seq)) == 0
    end
  end

  defp mark(f, seq) do
    if seq > f.in_max do
      shift = seq - f.in_max
      seen = if shift >= 64, do: 1, else: (f.seen <<< shift ||| 1) &&& (1 <<< 64) - 1
      %{f | in_max: seq, seen: seen}
    else
      %{f | seen: f.seen ||| 1 <<< (f.in_max - seq)}
    end
  end

  defp now32, do: System.monotonic_time(:millisecond) &&& 0xFFFFFFFF
  defp now_ms, do: System.monotonic_time(:millisecond)
end
