defmodule StressTester.Targets.Http do
  @moduledoc """
  Websites and HTTP APIs. One iteration runs the steps in order on the user's
  kept-open connections; a step that fails ends that iteration.

  From the command line, one step:

      stress http http://127.0.0.1:4001/v1/meta --rate 200
      stress http https://api.example.com/login --method POST --json '{"user":"u{{vu}}"}' \\
        --header 'x-client: stress' --expect-status 200

  From a scenario file, many steps, with captures:

      {"target": "http", "url": "http://127.0.0.1:4001", "vus": 20, "duration": "30s",
       "setup": [{"name": "login", "method": "POST", "path": "/v1/auth/login",
                  "json": {"account": "vigil-{{vu:4}}", "password": "stress"},
                  "capture": {"token": "access_token"}}],
       "steps": [{"name": "me", "path": "/v1/me", "headers": {"authorization": "Bearer {{token}}"}},
                 {"name": "fronts", "path": "/v1/fronts", "expect": {"status": 200}}]}

  `setup` runs once per user, `steps` every iteration. A step has `name`,
  `method` (GET), `path` or `url`, `headers`, `body` or `json`, `expect`
  (`status`: a code or a list, default any 2xx or 3xx; `contains`: text the
  body must hold; `json`: fields that must equal), and `capture` (a variable
  from a JSON field path like `data.items.0.id`, or `header:etag`).

  Records `http.req` (whole request), `http.ttfb`, `http.connect`, `http.tls`,
  one histogram per step (`http <name>`), `http.status.<code>`, and bytes.
  """

  @behaviour StressTester.Target

  alias StressTester.{Http, Metrics, Net, Template, Units}

  @impl true
  def options do
    [
      url: :string,
      address: :string,
      method: :string,
      header: :keep,
      body: :string,
      json: :string,
      expect_status: :string,
      name: :string,
      timeout: :string,
      insecure: :boolean
    ]
  end

  def usage do
    """
    stress http URL [options]
      --method POST              (GET)
      --header 'k: v'            repeat for more
      --body TEXT | --json JSON  the request body; both may use {{vu}}, {{iteration}}, {{rand:N}}
      --expect-status 200,201    (any 2xx or 3xx)
      --name NAME                the step's name in the report
      --timeout 10s              per request
      --insecure                 do not check the TLS certificate
    Several steps, setup, and captures need a scenario file; see `StressTester.Targets.Http`.
    """
  end

  @impl true
  def defaults(_opts),
    do: %{vus: 10, thresholds: ["iterations.failed:ratio<1%"], live: ["http.req"]}

  @impl true
  def init(opts) do
    # the command line's address wins over a URL written in a scenario file
    base = opts[:address] || opts[:url]

    with {:ok, base_origin} <- if(base, do: Net.origin(base), else: {:error, "give a URL"}),
         {:ok, timeout} <- Units.ms(opts[:timeout] || "10s", :s),
         {:ok, common} <- headers(opts[:headers] || opts[:header] || []),
         {:ok, setup} <- steps(opts[:setup] || [], base_origin),
         {:ok, steps} <- steps(opts[:steps] || [single(opts, base_origin)], base_origin) do
      origins = Map.new(setup ++ steps, &{&1.origin_key, &1.origin})

      {:ok,
       %{
         base: base,
         setup: Enum.map(setup, &Map.delete(&1, :origin)),
         steps: Enum.map(steps, &Map.delete(&1, :origin)),
         origins: origins,
         common: common,
         timeout: timeout,
         tls: %{insecure: opts[:insecure] == true}
       }}
    end
  end

  # the command-line request
  defp single(opts, origin) do
    %{
      "name" => opts[:name],
      "method" => opts[:method] || if(opts[:body] || opts[:json], do: "POST", else: "GET"),
      "path" => origin.path,
      "body" => opts[:body],
      # text, not a value: {{holes}} may stand for numbers, which is not JSON until they are filled
      "json_text" => opts[:json],
      "expect" =>
        if(s = opts[:expect_status],
          do: %{
            "status" => s |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1)))
          }
        )
    }
  end

  defp steps(list, base) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn raw, {:ok, acc} ->
      case step(Map.new(raw, fn {k, v} -> {to_string(k), v} end), base) do
        {:ok, s} -> {:cont, {:ok, acc ++ [s]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp steps(_, _), do: {:error, "steps must be a list"}

  defp step(raw, base) do
    method = String.upcase(raw["method"] || "GET")

    with {:ok, origin, path} <- where(raw, base),
         {:ok, headers} <- headers(raw["headers"] || []) do
      name = raw["name"] || "#{method} #{path}"

      body =
        cond do
          raw["json"] != nil -> {:json, Template.compile_value(raw["json"])}
          raw["json_text"] != nil -> {:json_text, Template.compile(raw["json_text"])}
          raw["body"] != nil -> {:raw, Template.compile(raw["body"])}
          true -> nil
        end

      headers =
        if elem(body || {nil}, 0) in [:json, :json_text],
          do: put_new(headers, "content-type", "application/json"),
          else: headers

      {:ok,
       %{
         name: name,
         metric: "http " <> name,
         method: method,
         origin: origin,
         origin_key: {origin.host, origin.port, origin.tls},
         path: Template.compile(path),
         headers: headers,
         body: body,
         expect: expect(raw["expect"]),
         capture: capture(raw["capture"])
       }}
    end
  end

  defp where(%{"url" => url}, _base) when is_binary(url) do
    with {:ok, origin} <- Net.origin(url), do: {:ok, origin, origin.path}
  end

  defp where(raw, base) do
    path = raw["path"] || base.path
    path = if String.starts_with?(path, "/"), do: path, else: "/" <> path
    {:ok, base, path}
  end

  defp headers(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      {k, v}, {:ok, acc} ->
        {:cont, {:ok, acc ++ [{String.downcase(to_string(k)), Template.compile(to_string(v))}]}}

      text, {:ok, acc} when is_binary(text) ->
        case String.split(text, ":", parts: 2) do
          [k, v] ->
            {:cont,
             {:ok, acc ++ [{String.downcase(String.trim(k)), Template.compile(String.trim(v))}]}}

          _ ->
            {:halt, {:error, "header #{inspect(text)} needs a colon"}}
        end
    end)
  end

  defp headers(%{} = map), do: headers(Enum.to_list(map))

  defp put_new(headers, k, v),
    do: if(List.keymember?(headers, k, 0), do: headers, else: headers ++ [{k, v}])

  defp expect(nil), do: %{status: :ok, contains: nil, json: nil}

  defp expect(raw) do
    status =
      case raw["status"] do
        nil -> :ok
        n when is_integer(n) -> [n]
        list when is_list(list) -> list
      end

    %{status: status, contains: raw["contains"], json: raw["json"]}
  end

  defp capture(nil), do: []
  defp capture(map), do: Enum.map(map, fn {var, path} -> {to_string(var), path} end)

  @impl true
  def describe(s) do
    case s.steps do
      [one] -> "http #{one.method} #{s.base}"
      many -> "http #{length(many)} steps on #{s.base}"
    end
  end

  @impl true
  def connect(shared, vu) do
    state = %{shared: shared, vars: %{"vu" => vu, "iteration" => 0}, conns: %{}}

    case run_steps(state, shared.setup) do
      {:ok, state} -> {:ok, state}
      {:error, reason, state} -> close_all(state) && {:error, reason}
    end
  end

  @impl true
  def iterate(state) do
    state = put_in(state.vars["iteration"], state.vars["iteration"] + 1)
    run_steps(state, state.shared.steps)
  end

  @impl true
  def disconnect(state), do: close_all(state)

  defp close_all(state) do
    Enum.each(state.conns, fn {_k, c} -> Http.close(c) end)
    true
  end

  defp run_steps(state, []), do: {:ok, state}

  defp run_steps(state, [step | rest]) do
    case run_step(state, step) do
      {:ok, state} -> run_steps(state, rest)
      {:error, reason, state} -> {:error, "#{step.name}: #{Metrics.reason(reason)}", state}
    end
  end

  defp run_step(state, step) do
    shared = state.shared
    vars = state.vars

    conn =
      Map.get(state.conns, step.origin_key) ||
        Http.new(shared.origins[step.origin_key], shared.tls)

    path = Template.render(step.path, vars)

    headers =
      Enum.map(shared.common ++ step.headers, fn {k, v} -> {k, Template.render(v, vars)} end)

    body =
      case step.body do
        nil -> nil
        {kind, t} when kind in [:raw, :json_text] -> Template.render(t, vars)
        {:json, v} -> JSON.encode!(Template.render_value(v, vars))
      end

    t0 = Metrics.now()

    case Http.request(conn, step.method, path, headers, body, shared.timeout) do
      {:ok, conn, resp} ->
        took = Metrics.now() - t0
        Metrics.observe("http.req", took)
        Metrics.observe(step.metric, took)
        Metrics.observe("http.ttfb", resp.ttfb_us)
        if resp[:connect_us], do: Metrics.observe("http.connect", resp.connect_us)
        if resp[:tls_us], do: Metrics.observe("http.tls", resp.tls_us)
        Metrics.count("http.status.#{resp.status}")
        Metrics.count("http.bytes_in", resp.bytes)
        if body, do: Metrics.count("http.bytes_out", byte_size(body))
        state = %{state | conns: Map.put(state.conns, step.origin_key, conn)}

        with :ok <- check(step.expect, resp),
             {:ok, vars} <- captures(step.capture, resp, vars) do
          {:ok, %{state | vars: vars}}
        else
          {:error, reason} -> {:error, reason, state}
        end

      {:error, conn, reason} ->
        Metrics.count("http.failed")
        {:error, reason, %{state | conns: Map.put(state.conns, step.origin_key, conn)}}
    end
  end

  defp check(expect, resp) do
    cond do
      expect.status == :ok and resp.status not in 200..399 ->
        {:error, {:status, resp.status}}

      is_list(expect.status) and resp.status not in expect.status ->
        {:error, {:status, resp.status}}

      expect.contains && not String.contains?(resp.body, expect.contains) ->
        {:error, "body lacks #{inspect(expect.contains)}"}

      expect.json ->
        json_matches(expect.json, resp.body)

      true ->
        :ok
    end
  end

  defp json_matches(want, body) do
    case JSON.decode(body) do
      {:ok, got} ->
        case Enum.find(want, fn {path, v} -> Template.dig(got, path) != v end) do
          nil ->
            :ok

          {path, v} ->
            {:error, "#{path} is #{inspect(Template.dig(got, path))}, not #{inspect(v)}"}
        end

      _ ->
        {:error, "body is not JSON"}
    end
  end

  defp captures([], _resp, vars), do: {:ok, vars}

  defp captures(list, resp, vars) do
    json =
      if Enum.any?(list, fn {_v, path} -> not String.starts_with?(path, "header:") end) do
        case JSON.decode(resp.body) do
          {:ok, j} -> j
          _ -> nil
        end
      end

    Enum.reduce_while(list, {:ok, vars}, fn {var, path}, {:ok, acc} ->
      value =
        case path do
          "header:" <> name -> Http.header(resp.headers, String.downcase(name))
          _ -> Template.dig(json, path)
        end

      if value in [nil, ""],
        do: {:halt, {:error, "nothing to capture at #{path}"}},
        else: {:cont, {:ok, Map.put(acc, var, value)}}
    end)
  end
end
