defmodule StressTester.Reach.Wire do
  @moduledoc "Reach packet layout for the Reach profile. The runner does not use it."

  @tag 16

  def pack(kind, slot, seq, payload) do
    <<kind::8, slot::unsigned-little-16, seq::unsigned-little-32, payload::binary>>
  end

  def seal(key, kind, slot, seq, dir, plain) do
    hdr = pack(kind, slot, seq, <<>>)
    hdr <> box(key, dir, seq, hdr, plain)
  end

  def open(key, dir, packet) do
    with {:ok, kind, slot, seq, blob} <- unpack(packet),
         hdr = pack(kind, slot, seq, <<>>),
         {:ok, plain} <- unbox(key, dir, seq, hdr, blob) do
      {:ok, kind, slot, seq, plain}
    else
      _ -> :error
    end
  end

  def pack_input(tick) do
    <<tick::unsigned-little-32, 0::signed-little-16, 0::signed-little-16, 0::signed-little-16, 0,
      0>>
  end

  def pack_chat(text), do: <<1, byte_size(text)::8, text::binary>>

  def unpack_accept(
        <<slot::unsigned-little-16, tick::unsigned-little-32, nlen, planet::binary-size(nlen)>>
      ) do
    {:ok, %{slot: slot, tick: tick, planet: planet}}
  end

  def unpack_accept(_), do: :error

  def snapshot_tick(<<tick::unsigned-little-32, _rest::binary>>), do: tick
  def snapshot_tick(_), do: 0

  def chat?(<<1, nlen, text::binary-size(nlen)>>), do: text != ""
  def chat?(_), do: false

  defp unpack(<<kind::8, slot::unsigned-little-16, seq::unsigned-little-32, payload::binary>>),
    do: {:ok, kind, slot, seq, payload}

  defp unpack(_), do: :error

  defp box(key, dir, seq, aad, plain) do
    iv = <<dir::8, seq::unsigned-little-32, 0::56>>
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plain, aad, @tag, true)
    cipher <> tag
  end

  defp unbox(key, dir, seq, aad, blob) when byte_size(blob) >= @tag do
    iv = <<dir::8, seq::unsigned-little-32, 0::56>>
    size = byte_size(blob) - @tag
    <<cipher::binary-size(size), tag::binary-size(@tag)>> = blob

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, aad, tag, false) do
      plain when is_binary(plain) -> {:ok, plain}
      _ -> :error
    end
  end

  defp unbox(_key, _dir, _seq, _aad, _blob), do: :error
end
