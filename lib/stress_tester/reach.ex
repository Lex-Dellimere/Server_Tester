defmodule StressTester.Reach do
  @moduledoc "Profile for the Reach server. Login on TCP, then load on UDP."

  @behaviour StressTester.Profile

  alias StressTester.Reach.Client

  @impl true
  def prepare(opts), do: Map.put_new(opts, :planet, "crystal-gate")

  @impl true
  def plan(opts), do: names(opts.workers)

  def names(count) when count >= 2 and count <= 198 do
    accord = div(count, 2)
    vigil = count - accord
    side("accord", accord) ++ side("vigil", vigil)
  end

  @impl true
  def open(opts, name), do: Client.open(opts, name, opts.planet)

  @impl true
  def close(session), do: Client.close(session)

  @impl true
  def drive(session, opts), do: Client.play(session, opts)

  @impl true
  def expect(rows) do
    chat =
      rows
      |> Enum.group_by(& &1.group)
      |> Enum.reduce(0, fn {_group, group}, acc ->
        sent = Enum.reduce(group, 0, fn row, n -> n + (row.sent["chat"] || 0) end)
        acc + sent * length(group)
      end)

    %{"state" => 0, "chat" => chat, "event" => 0}
  end

  @impl true
  def auth_rejected?(opts) do
    Client.login_status(opts.host, opts.port, "accord", "nope", opts.planet) == 401
  end

  @impl true
  def reconnect?(opts) do
    first = Client.open(opts, "host-01", "host-seed")
    second = Client.open(opts, "host-01", "host-seed")
    Client.close(first)
    Client.close(second)
    true
  end

  @impl true
  def ok?(report) do
    report.joined == report.workers and report.kinds["state"].received > 0 and
      report.kinds["chat"].received > 0 and report.auth_rejected and report.reconnect
  end

  defp side(faction, count) do
    Enum.map(1..count, fn n ->
      faction <> "-" <> String.pad_leading(Integer.to_string(n), 2, "0")
    end)
  end
end
