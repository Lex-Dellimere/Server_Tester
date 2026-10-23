defmodule StressTester.History do
  @moduledoc """
  The runs made since this VM started, newest last, so an IEx session can go
  back to any of them (`runs/0`, `run/1`, `last/0` in `StressTester.Shell`).
  Kept in memory only; `save/2` writes one to disk.
  """

  use Agent

  @keep 100

  def start_link(_opts), do: Agent.start_link(fn -> {0, []} end, name: __MODULE__)

  # the report back, numbered; unnumbered when the history is not running
  def add(report) do
    if Process.whereis(__MODULE__) do
      Agent.get_and_update(__MODULE__, fn {n, list} ->
        id = n + 1
        report = Map.put(report, :run, id)
        {report, {id, Enum.take([%{id: id, report: report} | list], @keep)}}
      end)
    else
      report
    end
  end

  def all do
    if Process.whereis(__MODULE__),
      do: Agent.get(__MODULE__, fn {_n, list} -> Enum.reverse(list) end),
      else: []
  end

  def get(id), do: Enum.find_value(all(), fn e -> if e.id == id, do: e.report end)

  def last do
    case all() do
      [] -> nil
      list -> List.last(list).report
    end
  end

  def clear,
    do: if(Process.whereis(__MODULE__), do: Agent.update(__MODULE__, fn _ -> {0, []} end))
end
