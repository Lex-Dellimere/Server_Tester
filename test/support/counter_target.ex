defmodule StressTester.Test.Counter do
  @moduledoc false
  # a target that talks to nobody: it counts, and can be told to misbehave

  @behaviour StressTester.Target

  alias StressTester.Metrics

  @impl true
  def init(opts) do
    {:ok,
     %{
       work_ms: opts[:work_ms] || 0,
       fail_connect: opts[:fail_connect],
       fail_every: opts[:fail_every],
       crash_at: opts[:crash_at],
       stop_at: opts[:stop_at]
     }}
  end

  @impl true
  def describe(_shared), do: "counter"

  @impl true
  def connect(%{fail_connect: n}, vu) when is_integer(n) and vu <= n, do: {:error, :refused}
  def connect(shared, vu), do: {:ok, %{shared: shared, vu: vu, n: 0, pokes: 0}}

  @impl true
  def iterate(st) do
    n = st.n + 1
    st = %{st | n: n}
    Metrics.count("test.iterations")
    Metrics.observe("test.work", 100 + n)
    if st.shared.work_ms > 0, do: Process.sleep(st.shared.work_ms)
    s = st.shared

    cond do
      s.crash_at == n -> raise "boom"
      s.stop_at == n -> {:stop, :enough, st}
      s.fail_every && rem(n, s.fail_every) == 0 -> {:error, :flaky, st}
      true -> {:ok, st}
    end
  end

  @impl true
  def handle_message({:poke, from}, st) do
    send(from, {:poked, st.vu})
    {:ok, %{st | pokes: st.pokes + 1}}
  end

  def handle_message(_other, st), do: {:ok, st}

  @impl true
  def disconnect(_st), do: Metrics.count("test.disconnected")

  @impl true
  def derive(c, _shared),
    do: %{"test.per_vu" => (c["test.iterations"] || 0) / max(c["vu.started"] || 1, 1)}
end
