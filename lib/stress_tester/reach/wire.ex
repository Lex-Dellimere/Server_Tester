defmodule StressTester.Reach.Wire do
  @moduledoc """
  The Reach fight packets, protocol 2, as the client sees them. Little-endian
  throughout. The backend's `lib/reach/packet.ex` and `docs/PROTOCOL.md` are the
  source of truth; this is the subset a load bot needs to build and read.

  Every packet is a 7-byte header (`kind`, `slot`, `seq`) and, except for the
  first connect, an AES-256-GCM box with that header as associated data and a
  nonce of `direction, seq, 0`.
  """

  @tag 16

  # packet kinds
  def connect, do: 1
  def accept, do: 2
  def deny, do: 3
  def state, do: 4
  def reliable, do: 5
  def ack, do: 6
  def bye, do: 7

  def pack(kind, slot, seq, payload) do
    <<kind::8, slot::unsigned-little-16, seq::unsigned-little-32, payload::binary>>
  end

  def unpack(<<kind::8, slot::unsigned-little-16, seq::unsigned-little-32, payload::binary>>),
    do: {:ok, kind, slot, seq, payload}

  def unpack(_), do: :error

  def seal(key, kind, slot, seq, dir, plain) do
    hdr = pack(kind, slot, seq, <<>>)
    iv = <<dir::8, seq::unsigned-little-32, 0::56>>
    plain = IO.iodata_to_binary(plain)
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plain, hdr, @tag, true)
    hdr <> cipher <> tag
  end

  def open(key, dir, packet) do
    with {:ok, kind, slot, seq, blob} <- unpack(packet),
         true <- byte_size(blob) >= @tag,
         hdr = pack(kind, slot, seq, <<>>),
         iv = <<dir::8, seq::unsigned-little-32, 0::56>>,
         size = byte_size(blob) - @tag,
         <<cipher::binary-size(size), tag::binary-size(@tag)>> = blob,
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, hdr, tag, false) do
      {:ok, kind, slot, seq, plain}
    else
      _ -> :error
    end
  end

  # -- accept / deny

  def unpack_accept(
        <<version::8, slot::unsigned-little-16, tick::unsigned-little-32,
          tick_ms::unsigned-little-16, every::8, flags::8, plen::8, place::binary-size(plen)>>
      ) do
    {:ok,
     %{
       version: version,
       slot: slot,
       tick: tick,
       tick_ms: tick_ms,
       every: every,
       rejoin: flags == 1,
       place: place
     }}
  end

  def unpack_accept(_), do: :error

  def unpack_deny(<<code::8>>), do: {:ok, code}
  def unpack_deny(_), do: :error

  # -- input (client -> server)

  def pack_input(ack_snap, client_ms, {rel_next, rel_bits}, frames) when length(frames) in 1..4 do
    [
      <<ack_snap::unsigned-little-32, client_ms::unsigned-little-32, rel_next::unsigned-little-16,
        rel_bits::unsigned-little-32, length(frames)::8>>,
      Enum.map(frames, &pack_frame/1)
    ]
  end

  defp pack_frame(f) do
    <<f.tick::unsigned-little-32, f.view_tick::unsigned-little-32, f.x::signed-little-32,
      f.y::signed-little-32, f.z::signed-little-32, clamp16(f.vx)::signed-little-16,
      clamp16(f.vy)::signed-little-16, clamp16(f.vz)::signed-little-16, f.yaw::unsigned-little-16,
      f.pitch::signed-little-16, f.posture::8, f.weapon::8, f.buttons::unsigned-little-16>>
  end

  # -- snapshot (server -> client); only the fixed head, not the entity delta

  def unpack_snapshot(
        <<tick::unsigned-little-32, base::unsigned-little-32, input_tick::unsigned-little-32,
          echo_ms::unsigned-little-32, hold_ms::unsigned-little-16, rel_next::unsigned-little-16,
          rel_bits::unsigned-little-32, me::binary-14, delta::binary>>
      ) do
    {:ok,
     %{
       tick: tick,
       base: base,
       input_tick: input_tick,
       echo_ms: echo_ms,
       hold_ms: hold_ms,
       ack: {rel_next, rel_bits},
       me: unpack_me(me),
       delta: delta
     }}
  end

  def unpack_snapshot(_), do: :error

  defp unpack_me(
         <<weapon::8, ammo::unsigned-little-16, magazine::unsigned-little-16,
           reload::unsigned-little-16, ability::unsigned-little-16, grenade::unsigned-little-16,
           respawn::unsigned-little-16, flags::8>>
       ) do
    import Bitwise

    %{
      weapon: weapon,
      ammo: ammo,
      magazine: magazine,
      reload_cs: reload,
      ability_cs: ability,
      grenade_cs: grenade,
      respawn_cs: respawn,
      dead: (flags &&& 1) != 0,
      can_spawn: (flags &&& 2) != 0,
      no_body: (flags &&& 128) != 0
    }
  end

  # -- reliable lane framing

  def pack_reliable({rel_next, rel_bits}, messages) do
    [
      <<rel_next::unsigned-little-16, rel_bits::unsigned-little-32, length(messages)::8>>,
      Enum.map(messages, fn {rseq, payload} ->
        <<rseq::unsigned-little-16, byte_size(payload)::unsigned-little-16, payload::binary>>
      end)
    ]
  end

  def unpack_reliable(
        <<rel_next::unsigned-little-16, rel_bits::unsigned-little-32, count::8, rest::binary>>
      ) do
    case take_messages(rest, count, []) do
      {:ok, messages} -> {:ok, {rel_next, rel_bits}, messages}
      :error -> :error
    end
  end

  def unpack_reliable(_), do: :error

  defp take_messages(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp take_messages(
         <<rseq::unsigned-little-16, len::unsigned-little-16, payload::binary-size(len),
           rest::binary>>,
         n,
         acc
       )
       when n > 0,
       do: take_messages(rest, n - 1, [{rseq, payload} | acc])

  defp take_messages(_, _, _), do: :error

  def pack_ack({rel_next, rel_bits}),
    do: <<rel_next::unsigned-little-16, rel_bits::unsigned-little-32>>

  def unpack_ack(<<rel_next::unsigned-little-16, rel_bits::unsigned-little-32>>),
    do: {:ok, {rel_next, rel_bits}}

  def unpack_ack(_), do: :error

  def pack_bye(reason), do: <<reason::8>>

  @byes %{
    0 => :quit,
    1 => :kicked,
    2 => :replaced,
    3 => :overflow,
    4 => :idle,
    5 => :closed,
    6 => :moved
  }
  def bye_reason(code), do: Map.get(@byes, code, code)

  @denies %{1 => :expired, 2 => :used, 3 => :full, 4 => :closed, 5 => :banned, 6 => :version}
  def deny_reason(code), do: Map.get(@denies, code, code)

  # -- reliable payloads a bot sends

  def say_team(text), do: <<1, byte_size(text)::8, text::binary>>
  def spawn_request(index), do: <<6, index::8>>

  # -- reliable payloads a bot reads (just enough to classify and to follow corrections)

  def read_server(
        <<6, tick::unsigned-little-32, x::signed-little-32, y::signed-little-32,
          z::signed-little-32, vx::signed-little-16, vy::signed-little-16, vz::signed-little-16,
          reason::8>>
      ),
      do: {:correct, %{tick: tick, pos: {x, y, z}, vel: {vx, vy, vz}, reason: reason}}

  def read_server(
        <<1, kind::8, _tick::unsigned-little-32, a::unsigned-little-16, b::unsigned-little-16,
          value::signed-little-32, extra::8>>
      ),
      do: {:event, %{kind: kind, a: a, b: b, value: value, extra: extra}}

  def read_server(
        <<2, channel::8, from::unsigned-little-16, nlen::8, name::binary-size(nlen), tlen::8,
          text::binary-size(tlen)>>
      ),
      do: {:chat, %{channel: channel, from: from, name: name, text: text}}

  def read_server(<<7, _len::unsigned-little-16, _json::binary>>), do: {:result, nil}
  def read_server(<<type::8, _rest::binary>>), do: {:other, type}
  def read_server(_), do: :error

  defp clamp16(v), do: v |> round() |> max(-32_768) |> min(32_767)
end
