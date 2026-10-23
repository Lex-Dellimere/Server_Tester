defmodule StressTester.Reach.Lobby do
  @moduledoc """
  The lobby socket ("the ship") as a bot uses it. While connecting, reads are
  passive: send an op with an `id`, then `await/3` until the answer with the
  same `re` arrives, keeping the pushes that came before it. After that the
  caller runs the socket active and feeds frames to `decode/1` itself.
  """

  alias StressTester.{Metrics, WebSocket}

  # {:ok, ws, welcome, pushes} | {:error, reason}
  def connect(shared, token, character) do
    started = Metrics.now()
    opts = Map.put(shared.tls, :path, "/v1/lobby")

    with {:ok, ws, _timing} <- WebSocket.connect(shared.origin, opts, shared.timeout),
         :ok <-
           send_op(ws, %{"op" => "hello", "id" => 1, "token" => token, "character" => character}),
         {:ok, ws, welcome, pushes} <- await(ws, 1, shared.timeout) do
      Metrics.since("reach.lobby_connect", started)

      if welcome["ok"] == true do
        {:ok, ws, welcome, pushes}
      else
        WebSocket.close(ws)
        {:error, {:hello, welcome["error"]}}
      end
    end
  end

  # ask for a seat in a place; the ticket fields are in the answer
  def ticket(shared, ws, place) do
    started = Metrics.now()
    :ok = send_op(ws, %{"op" => "battle.join", "id" => 2, "place" => place})

    with {:ok, ws, reply, pushes} <- await(ws, 2, shared.timeout) do
      Metrics.since("reach.ticket", started)
      ticket_reply(ws, reply, pushes)
    end
  end

  # the rejoin ticket for the place the character was last in
  def rejoin(shared, ws) do
    :ok = send_op(ws, %{"op" => "battle.rejoin", "id" => 3})

    with {:ok, ws, reply, pushes} <- await(ws, 3, shared.timeout) do
      ticket_reply(ws, reply, pushes)
    end
  end

  defp ticket_reply(ws, %{"ok" => false} = reply, _pushes),
    do: close_with(ws, {:ticket, reply["error"]})

  defp ticket_reply(ws, %{"ticket" => _} = reply, pushes), do: {:ok, ws, reply, pushes}

  defp ticket_reply(ws, reply, _pushes),
    do: close_with(ws, {:ticket, {:no_ticket, Map.keys(reply)}})

  # join the matchmaker and wait for the seat to come as a push
  def queue(shared, ws, planet, wait_ms) do
    :ok = send_op(ws, %{"op" => "mm.queue", "id" => 2, "planet" => planet})

    with {:ok, ws, reply, pushes} <- await(ws, 2, shared.timeout) do
      cond do
        reply["ok"] == false -> close_with(ws, {:queue, reply["error"]})
        matched = Enum.find(pushes, &(&1["op"] == "mm.matched")) -> {:ok, ws, matched}
        true -> wait_matched(ws, wait_ms)
      end
    end
  end

  defp wait_matched(ws, wait_ms) do
    done = fn m ->
      m["op"] == "mm.matched" or
        (m["op"] == "mm.status" and m["status"] in ["cancelled", "timeout", "error"])
    end

    with {:ok, ws, m, _} <- await_by(ws, done, wait_ms) do
      if m["op"] == "mm.matched", do: {:ok, ws, m}, else: close_with(ws, {:queue, m["status"]})
    end
  end

  def await(ws, id, timeout), do: await_by(ws, &(&1["re"] == id), timeout)

  def await_by(ws, match, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    # frames that came in with the upgrade answer are already buffered
    with {:ok, ws, msgs} <- WebSocket.feed(ws, <<>>), do: scan(ws, msgs, match, deadline, [])
  end

  defp scan(ws, [], match, deadline, pushes) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {:error, :timeout}
    else
      case WebSocket.recv(ws, left) do
        {:ok, ws, msgs} -> scan(ws, msgs, match, deadline, pushes)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp scan(ws, [msg | rest], match, deadline, pushes) do
    case msg do
      {:text, json} ->
        m = decode(json)

        if match.(m),
          do: {:ok, ws, m, Enum.reverse(pushes) ++ for({:text, j} <- rest, do: decode(j))},
          else: scan(ws, rest, match, deadline, [m | pushes])

      {:close, code, reason} ->
        {:error, {:closed, code, reason}}

      _ ->
        scan(ws, rest, match, deadline, pushes)
    end
  end

  def decode(json) do
    case JSON.decode(json) do
      {:ok, %{} = m} -> m
      _ -> %{"op" => "unreadable"}
    end
  end

  def send_op(ws, map), do: WebSocket.text(ws, JSON.encode!(map))

  defp close_with(ws, reason) do
    WebSocket.close(ws)
    {:error, reason}
  end
end
