defmodule StressTester.Reach.Api do
  @moduledoc """
  The Reach HTTP door as a bot uses it: one request per connection, JSON in and
  out. Login retries what a real client would retry: `slow_down` and `busy`
  (the server's password hashing is full), with a growing, jittered pause.
  """

  alias StressTester.{Http, Metrics}

  @retries 6

  # {:ok, status, decoded_body} | {:error, reason}
  def call(shared, method, path, json \\ nil, token \\ nil) do
    conn = Http.new(shared.origin, shared.tls)
    auth = if token, do: [{"authorization", "Bearer " <> token}], else: []
    headers = [{"content-type", "application/json"}, {"connection", "close"} | auth]
    body = if json, do: JSON.encode!(json)

    case Http.request(conn, method, path, headers, body, shared.timeout) do
      {:ok, conn, resp} ->
        Http.close(conn)
        {:ok, resp.status, decode(resp.body)}

      {:error, conn, reason} ->
        Http.close(conn)
        {:error, reason}
    end
  end

  def decode(body) do
    case JSON.decode(body) do
      {:ok, json} -> json
      _ -> body
    end
  end

  def login(shared, name, password \\ nil) do
    started = Metrics.now()

    case attempt(shared, name, password || shared.password, 0) do
      {:ok, tokens} ->
        Metrics.since("reach.login", started)
        {:ok, tokens}

      error ->
        error
    end
  end

  defp attempt(shared, name, password, tries) do
    case call(shared, "POST", "/v1/auth/login", %{"account" => name, "password" => password}) do
      {:ok, 200, %{"access_token" => _} = tokens} ->
        {:ok, tokens}

      {:ok, status, body} when tries < @retries ->
        if code(body) in ["slow_down", "busy"] do
          Metrics.count("reach.login_retry")
          Process.sleep(backoff(tries))
          attempt(shared, name, password, tries + 1)
        else
          {:error, {:login, name, status, code(body)}}
        end

      {:ok, status, body} ->
        {:error, {:login, name, status, code(body)}}

      {:error, reason} ->
        {:error, {:login, name, reason}}
    end
  end

  defp backoff(tries), do: 100 * Integer.pow(2, tries) + :rand.uniform(100)

  defp code(%{"error" => e}), do: e
  defp code(other), do: other

  # words for a failure, with the likely cause when there is one. The bot's name is left out on
  # purpose: a thousand bots failing the same way are one problem, and the report groups by words.
  def explain({:login, _name, 401, "bad_login"}),
    do:
      "login: bad_login (is the server running with stress logins on? dev has them; elsewhere set REACH_STRESS=1)"

  def explain({:login, _name, 429, "locked"}),
    do:
      "login: locked (ten wrong passwords in a row; wait fifteen minutes or use other names with --offset)"

  def explain({:login, _name, status, code}), do: "login: #{status} #{inspect(code)}"
  def explain({:login, _name, reason}), do: "login: #{Metrics.reason(reason)}"
  def explain(other), do: Metrics.reason(other)
end
