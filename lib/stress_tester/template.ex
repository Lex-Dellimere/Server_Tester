defmodule StressTester.Template do
  @moduledoc """
  `{{holes}}` in strings, filled for each user and iteration:

      {{vu}}          the user's number; {{vu:4}} pads it to 0042
      {{iteration}}   this user's iteration, from 1
      {{rand:100}}    a random number from 1 to 100
      {{uuid}}        a random UUID
      {{now}}         unix time in milliseconds
      {{env:NAME}}    an environment variable, read once at the start
      {{anything}}    a variable a step captured, or empty

  Templates are compiled once; a string with no holes stays a plain string.
  """

  @hole ~r/\{\{\s*([^{}]+?)\s*\}\}/

  def compile(text) when is_binary(text) do
    if String.contains?(text, "{{") do
      parts =
        @hole
        |> Regex.split(text, include_captures: true, trim: true)
        |> Enum.map(&part/1)

      {:tpl, parts}
    else
      text
    end
  end

  # every string inside a JSON-like value
  def compile_value(v) when is_binary(v), do: compile(v)
  def compile_value(v) when is_list(v), do: Enum.map(v, &compile_value/1)
  def compile_value(%{} = v), do: Map.new(v, fn {k, x} -> {k, compile_value(x)} end)
  def compile_value(v), do: v

  def render(text, _vars) when is_binary(text), do: text
  def render({:tpl, parts}, vars), do: parts |> Enum.map(&fill(&1, vars)) |> IO.iodata_to_binary()

  def render_value({:tpl, _} = t, vars), do: render(t, vars)
  def render_value(v, vars) when is_list(v), do: Enum.map(v, &render_value(&1, vars))

  def render_value(%{} = v, vars) when not is_struct(v),
    do: Map.new(v, fn {k, x} -> {k, render_value(x, vars)} end)

  def render_value(v, _vars), do: v

  defp part("{{" <> _ = hole) do
    [_, name] = Regex.run(@hole, hole)

    case String.split(name, ":", parts: 2) do
      ["vu"] -> {:vu, 0}
      ["vu", width] -> {:vu, String.to_integer(width)}
      ["iteration"] -> :iteration
      ["rand", n] -> {:rand, String.to_integer(n)}
      ["uuid"] -> :uuid
      ["now"] -> :now
      ["env", var] -> System.get_env(var, "")
      _ -> {:var, name}
    end
  end

  defp part(text), do: text

  defp fill(text, _vars) when is_binary(text), do: text

  defp fill({:vu, width}, vars),
    do: vars |> Map.get("vu", 0) |> Integer.to_string() |> String.pad_leading(width, "0")

  defp fill(:iteration, vars), do: Integer.to_string(Map.get(vars, "iteration", 0))
  defp fill({:rand, n}, _vars), do: Integer.to_string(:rand.uniform(max(n, 1)))
  defp fill(:uuid, _vars), do: uuid()
  defp fill(:now, _vars), do: Integer.to_string(System.os_time(:millisecond))
  defp fill({:var, name}, vars), do: to_text(Map.get(vars, name))

  defp to_text(nil), do: ""
  defp to_text(v) when is_binary(v), do: v
  defp to_text(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp to_text(v), do: JSON.encode!(v)

  def uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    [<<a::32>>, <<b::16>>, <<4::4, c::12>>, <<2::2, d::14>>, <<e::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  # "a.b.0.c" into decoded JSON
  def dig(value, ""), do: value
  def dig(value, path) when is_binary(path), do: dig(value, String.split(path, "."))
  def dig(value, []), do: value
  def dig(%{} = map, [key | rest]), do: map |> Map.get(key) |> dig(rest)

  def dig(list, [key | rest]) when is_list(list) do
    case Integer.parse(key) do
      {i, ""} -> list |> Enum.at(i) |> dig(rest)
      _ -> nil
    end
  end

  def dig(_value, _path), do: nil
end
