defmodule StressTester.Metrics do
  @moduledoc """
  What a virtual user records. A target calls these from inside the user's own
  process; the numbers stay there and go to the run about once a second, so a
  sample costs a map update, not a message.

      Metrics.count("http.status.200")
      Metrics.observe("http.ttfb", microseconds)
      Metrics.observe("ws.frame", bytes, :bytes)
      Metrics.time("login", fn -> ... end)
      Metrics.error("login", :timeout)

  Errors are counted by where and why; `errors` is their total.
  """

  alias StressTester.Histogram

  @key :stress_metrics

  def count(name, n \\ 1) do
    d = data()
    put(%{d | c: Map.update(d.c, name, n, &(&1 + n))})
  end

  def observe(name, value, unit \\ :us) do
    d = data()

    h =
      case d.h do
        %{^name => h} -> h
        _ -> Histogram.new(unit)
      end

    put(%{d | h: Map.put(d.h, name, Histogram.add(h, value))})
  end

  def since(name, started), do: observe(name, now() - started)

  def time(name, fun) do
    started = now()
    result = fun.()
    since(name, started)
    result
  end

  def error(where, reason) do
    d = data()
    key = {where, reason(reason)}

    put(%{
      d
      | e: Map.update(d.e, key, 1, &(&1 + 1)),
        c: Map.update(d.c, "errors", 1, &(&1 + 1))
    })
  end

  def now, do: System.monotonic_time(:microsecond)

  # the runner side

  def take do
    d = data()
    Process.put(@key, empty())
    d
  end

  def empty, do: %{c: %{}, h: %{}, e: %{}}

  def empty?(d), do: map_size(d.c) == 0 and map_size(d.h) == 0 and map_size(d.e) == 0

  def merge(a, b) do
    %{
      c: Map.merge(a.c, b.c, fn _k, x, y -> x + y end),
      h: Map.merge(a.h, b.h, fn _k, x, y -> Histogram.merge(x, y) end),
      e: Map.merge(a.e, b.e, fn _k, x, y -> x + y end)
    }
  end

  # error kinds stay few, so one noisy failure cannot swamp the report
  def cap_errors(d, max) when map_size(d.e) <= max, do: d

  def cap_errors(d, max) do
    {keep, extra} = d.e |> Enum.sort_by(fn {_k, n} -> -n end) |> Enum.split(max - 1)
    other = Enum.reduce(extra, 0, fn {_k, n}, acc -> acc + n end)

    %{
      d
      | e: keep |> Map.new() |> Map.update({"other", "more kinds of error"}, other, &(&1 + other))
    }
  end

  def reason(r) when is_binary(r), do: String.slice(r, 0, 160)
  def reason(r) when is_atom(r), do: Atom.to_string(r)
  def reason({:status, code}), do: "status #{code}"
  def reason(%{__exception__: true} = e), do: e |> Exception.message() |> reason()
  def reason(r), do: r |> inspect(limit: 6, printable_limit: 100) |> reason()

  defp data, do: Process.get(@key) || empty()

  defp put(d) do
    Process.put(@key, d)
    :ok
  end
end
