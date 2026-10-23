defmodule StressTester.Units do
  @moduledoc "Reading the durations people type, and writing numbers people read."

  @duration ~r/^\s*(\d+(?:\.\d+)?)\s*(us|µs|ms|s|m|h)?\s*$/

  # "500ms", "30s", "5m", "1h", or a bare number in `unit`; returns milliseconds
  def ms(nil, _unit), do: {:ok, nil}
  def ms(n, unit) when is_number(n) and n >= 0, do: {:ok, round(n * scale(unit))}

  def ms(text, unit) when is_binary(text) do
    case Regex.run(@duration, text) do
      [_, n, u] -> {:ok, round(number(n) * scale(String.to_atom(u)))}
      [_, n] -> {:ok, round(number(n) * scale(unit))}
      _ -> {:error, "#{inspect(text)} is not a duration (try 500ms, 30s, 5m)"}
    end
  end

  def ms(other, _unit), do: {:error, "#{inspect(other)} is not a duration"}

  defp scale(:us), do: 0.001
  defp scale(:μs), do: 0.001
  defp scale(:ms), do: 1
  defp scale(:s), do: 1_000
  defp scale(:m), do: 60_000
  defp scale(:h), do: 3_600_000

  defp number(text) do
    case Float.parse(text) do
      {f, ""} -> f
      _ -> String.to_integer(text)
    end
  end

  # "ping\n" typed on a shell arrives as a backslash and an n
  def unescape(text) do
    Regex.replace(~r/\\(x[0-9a-fA-F]{2}|n|r|t|0|\\)/, text, fn
      _, "n" -> "\n"
      _, "r" -> "\r"
      _, "t" -> "\t"
      _, "0" -> <<0>>
      _, "\\" -> "\\"
      _, "x" <> hex -> <<String.to_integer(hex, 16)>>
    end)
  end

  def time(nil), do: "-"
  def time(us) when us < 1_000, do: "#{round(us)}µs"
  def time(us) when us < 10_000, do: "#{fixed(us / 1_000, 2)}ms"
  def time(us) when us < 1_000_000, do: "#{fixed(us / 1_000, 1)}ms"
  def time(us) when us < 60_000_000, do: "#{fixed(us / 1_000_000, 2)}s"
  def time(us), do: "#{div(round(us), 60_000_000)}m#{pad(rem(div(round(us), 1_000_000), 60))}s"

  def bytes(nil), do: "-"
  def bytes(b) when b < 1_024, do: "#{round(b)}B"
  def bytes(b) when b < 1_048_576, do: "#{fixed(b / 1_024, 1)}KB"
  def bytes(b) when b < 1_073_741_824, do: "#{fixed(b / 1_048_576, 1)}MB"
  def bytes(b), do: "#{fixed(b / 1_073_741_824, 2)}GB"

  # a value in its histogram's unit
  def value(v, :us), do: time(v)
  def value(v, :bytes), do: bytes(v)
  def value(nil, _unit), do: "-"
  def value(v, _unit), do: count(v)

  def count(nil), do: "-"
  def count(n) when is_float(n) and n < 100, do: fixed(n, 1)
  def count(n) when is_float(n), do: count(round(n))

  def count(n) when is_integer(n) do
    digits = n |> abs() |> Integer.to_string()

    grouped =
      digits
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(",", &Enum.join/1)
      |> String.reverse()

    if n < 0, do: "-" <> grouped, else: grouped
  end

  # a number of any size to a few significant digits
  def figure(nil), do: "-"
  def figure(n) when is_integer(n), do: count(n)

  def figure(f) when is_float(f) do
    cond do
      f == 0 -> "0"
      abs(f) >= 100 -> count(round(f))
      abs(f) >= 10 -> fixed(f, 1)
      abs(f) >= 1 -> fixed(f, 2)
      true -> fixed(f, 4)
    end
  end

  def percent(ratio), do: "#{fixed(ratio * 100, 2)}%"

  def fixed(f, decimals), do: :erlang.float_to_binary(f * 1.0, decimals: decimals)

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
