defmodule StressTester.Reach.Lane do
  @moduledoc """
  The reliable lane as a bot needs it: receive messages in order and tell the
  server what to ack; send a few messages (spawn, chat) and resend them until
  acked. Sequence numbers are 16-bit and wrap, so the comparisons are modular,
  the same way the server does them.

  This is deliberately small — a load bot sends little on this lane — but it
  acks correctly, so the server does not retransmit forever and the backlog
  cannot build up.
  """

  import Bitwise

  @mod 65_536
  @half 32_768
  @window 32

  defstruct next_out: 1, inflight: %{}, next_in: 1, buffer: %{}, rto: 250

  def new, do: %__MODULE__{}

  # -- receiving

  # returns {lane, delivered_payloads_in_order}
  def receive(lane, seq, payload) do
    cond do
      before?(seq, lane.next_in) -> {lane, []}
      distance(lane.next_in, seq) >= 256 -> {lane, []}
      seq == lane.next_in -> drain(%{lane | next_in: inc(seq)}, [payload])
      true -> {%{lane | buffer: Map.put(lane.buffer, seq, payload)}, []}
    end
  end

  def ack_state(lane) do
    bits =
      Enum.reduce(lane.buffer, 0, fn {seq, _}, acc ->
        d = distance(lane.next_in, seq) - 1
        if d >= 0 and d < 32, do: acc ||| 1 <<< d, else: acc
      end)

    {lane.next_in, bits}
  end

  # -- sending

  # returns {lane, messages_to_send_now}
  def push(lane, payload, now) do
    seq = lane.next_out
    lane = %{lane | next_out: inc(seq), inflight: Map.put(lane.inflight, seq, {payload, now, 1})}
    {lane, [{seq, payload}]}
  end

  # drop whatever the peer acked
  def acked(lane, next, bits) do
    keep =
      Enum.reject(lane.inflight, fn {seq, _} -> before?(seq, next) or bit?(bits, next, seq) end)

    %{lane | inflight: Map.new(keep)}
  end

  # messages whose timer ran out, for resend (wait doubles per try, capped)
  def due(lane, now) do
    {inflight, out} =
      Enum.reduce(lane.inflight, {lane.inflight, []}, fn {seq, {payload, sent, tries}},
                                                         {acc, out} ->
        wait = min(lane.rto * (1 <<< min(tries - 1, 4)), 2_000)

        if now - sent >= wait,
          do: {Map.put(acc, seq, {payload, now, tries + 1}), [{seq, payload} | out]},
          else: {acc, out}
      end)

    {%{lane | inflight: inflight}, out}
  end

  def pending(lane), do: map_size(lane.inflight)

  # -- modular sequence math

  defp inc(seq), do: rem(seq + 1, @mod)
  defp distance(from, to), do: Integer.mod(to - from, @mod)
  defp before?(a, b), do: a != b and distance(a, b) < @half

  defp bit?(bits, next, seq) do
    d = distance(next, seq) - 1
    d >= 0 and d < 32 and (bits &&& 1 <<< d) != 0
  end

  defp drain(lane, out) do
    case Map.pop(lane.buffer, lane.next_in) do
      {nil, _} ->
        {lane, Enum.reverse(out)}

      {payload, buffer} ->
        drain(%{lane | buffer: buffer, next_in: inc(lane.next_in)}, [payload | out])
    end
  end

  def window, do: @window
end
