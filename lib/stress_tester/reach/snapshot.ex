defmodule StressTester.Reach.Snapshot do
  @moduledoc """
  Reads the entity part of a fight snapshot (protocol 2) against the baseline
  the client holds. The bot needs this to see where the enemies are, and the
  tester needs it to notice when the server sends something that cannot be read.

      removed::u16  [id::u16] × removed
      count::u16    [entity] × count
      entity: id::u16 mask::u16, then each group whose mask bit is set:
        0 spawn    kind::u8 team::u8 max_hp::u16 max_shield::u16
        1 position x::i32 y::i32 z::i32
        2 velocity vx::i16 vy::i16 vz::i16
        3 aim      yaw::u16 pitch::i16
        4 hp       5 shield   (u16 each)
        6 posture  7 flags    8 weapon   (u8 each)
        9 progress u16
        10 team    u8   (only when bit 0 is not set)

  An entity the server skipped (to stay under the packet size) keeps its old
  values, so a decoded snapshot is the baseline with the changes applied.
  """

  import Bitwise

  def decode(binary, baseline) do
    base = baseline || %{}

    with <<removed::unsigned-little-16, rest::binary>> <- binary,
         {:ok, gone, rest} <- take_ids(rest, removed, []),
         <<count::unsigned-little-16, rest::binary>> <- rest,
         {:ok, held} <- entities(rest, count, Map.drop(base, gone)) do
      {:ok, held}
    else
      _ -> :error
    end
  end

  defp take_ids(rest, 0, acc), do: {:ok, acc, rest}

  defp take_ids(<<id::unsigned-little-16, rest::binary>>, n, acc),
    do: take_ids(rest, n - 1, [id | acc])

  defp take_ids(_, _, _), do: :error

  defp entities(<<>>, 0, held), do: {:ok, held}

  defp entities(<<id::unsigned-little-16, mask::unsigned-little-16, rest::binary>>, n, held)
       when n > 0 do
    case read(Map.get_lazy(held, id, fn -> blank(id) end), mask, rest) do
      {:ok, e, rest} -> entities(rest, n - 1, Map.put(held, id, e))
      :error -> :error
    end
  end

  defp entities(_, _, _), do: :error

  defp read(e, mask, bin) do
    with {:ok, e, bin} <- spawn_group(e, mask, bin),
         {:ok, e, bin} <- position(e, mask, bin),
         {:ok, e, bin} <- velocity(e, mask, bin),
         {:ok, e, bin} <- aim(e, mask, bin),
         {:ok, e, bin} <- u16(e, mask, 4, :hp, bin),
         {:ok, e, bin} <- u16(e, mask, 5, :shield, bin),
         {:ok, e, bin} <- u8(e, mask, 6, :posture, bin),
         {:ok, e, bin} <- u8(e, mask, 7, :flags, bin),
         {:ok, e, bin} <- u8(e, mask, 8, :weapon, bin),
         {:ok, e, bin} <- u16(e, mask, 9, :progress, bin) do
      if on?(mask, 10) and not on?(mask, 0), do: u8(e, mask, 10, :team, bin), else: {:ok, e, bin}
    end
  end

  defp spawn_group(e, mask, bin) do
    if on?(mask, 0) do
      case bin do
        <<kind::8, team::8, hp::unsigned-little-16, shield::unsigned-little-16, rest::binary>> ->
          {:ok, %{e | kind: kind, team: team, max_hp: hp, max_shield: shield}, rest}

        _ ->
          :error
      end
    else
      {:ok, e, bin}
    end
  end

  defp position(e, mask, bin) do
    if on?(mask, 1) do
      case bin do
        <<x::signed-little-32, y::signed-little-32, z::signed-little-32, rest::binary>> ->
          {:ok, %{e | x: x, y: y, z: z}, rest}

        _ ->
          :error
      end
    else
      {:ok, e, bin}
    end
  end

  defp velocity(e, mask, bin) do
    if on?(mask, 2) do
      case bin do
        <<vx::signed-little-16, vy::signed-little-16, vz::signed-little-16, rest::binary>> ->
          {:ok, %{e | vx: vx, vy: vy, vz: vz}, rest}

        _ ->
          :error
      end
    else
      {:ok, e, bin}
    end
  end

  defp aim(e, mask, bin) do
    if on?(mask, 3) do
      case bin do
        <<yaw::unsigned-little-16, pitch::signed-little-16, rest::binary>> ->
          {:ok, %{e | yaw: yaw, pitch: pitch}, rest}

        _ ->
          :error
      end
    else
      {:ok, e, bin}
    end
  end

  defp u16(e, mask, bit, key, bin) do
    if on?(mask, bit) do
      case bin do
        <<v::unsigned-little-16, rest::binary>> -> {:ok, Map.put(e, key, v), rest}
        _ -> :error
      end
    else
      {:ok, e, bin}
    end
  end

  defp u8(e, mask, bit, key, bin) do
    if on?(mask, bit) do
      case bin do
        <<v::8, rest::binary>> -> {:ok, Map.put(e, key, v), rest}
        _ -> :error
      end
    else
      {:ok, e, bin}
    end
  end

  defp on?(mask, bit), do: (mask &&& 1 <<< bit) != 0

  def blank(id) do
    %{
      id: id,
      kind: 0,
      team: 255,
      x: 0,
      y: 0,
      z: 0,
      vx: 0,
      vy: 0,
      vz: 0,
      yaw: 0,
      pitch: 0,
      hp: 0,
      shield: 0,
      max_hp: 0,
      max_shield: 0,
      posture: 0,
      flags: 0,
      weapon: 0,
      progress: 0
    }
  end
end
