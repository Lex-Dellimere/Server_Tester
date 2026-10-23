defmodule StressTester.Net do
  @moduledoc """
  Addresses, and the two stream transports. A socket here is `{:gen_tcp, s}`
  or `{:ssl, s}`, so the clients above do not care which one they hold.

  Names are resolved once when a run starts, not per connection, so DNS is
  not part of what is being measured.
  """

  # %{scheme, host, port, ip, tls, path}
  def origin(url, default_scheme \\ "http") do
    url = if String.contains?(url, "://"), do: url, else: "#{default_scheme}://#{url}"
    uri = URI.parse(url)

    cond do
      uri.host in [nil, ""] ->
        {:error, "#{inspect(url)} has no host"}

      true ->
        tls = uri.scheme in ["https", "wss"]
        port = uri.port || if(tls, do: 443, else: 80)

        with {:ok, ip} <- resolve(uri.host) do
          path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
          path = if path == "", do: "/", else: path
          {:ok, %{scheme: uri.scheme, host: uri.host, port: port, ip: ip, tls: tls, path: path}}
        end
    end
  end

  # "host:port", "[::1]:port", or a host with a default port
  def host_port(text, default_port) do
    case Regex.run(~r/^\[?([^\[\]]+?)\]?(?::(\d+))?$/, String.trim(text)) do
      [_, host] when default_port != nil ->
        with {:ok, ip} <- resolve(host), do: {:ok, host, ip, default_port}

      [_, host, port] ->
        with {:ok, ip} <- resolve(host), do: {:ok, host, ip, String.to_integer(port)}

      _ ->
        {:error, "#{inspect(text)} is not host:port"}
    end
  end

  def resolve(host) when is_binary(host) do
    chars = String.to_charlist(host)

    case :inet.parse_address(chars) do
      {:ok, ip} ->
        {:ok, ip}

      _ ->
        case :inet.getaddr(chars, :inet) do
          {:ok, ip} ->
            {:ok, ip}

          _ ->
            case :inet.getaddr(chars, :inet6) do
              {:ok, ip} -> {:ok, ip}
              {:error, reason} -> {:error, "cannot resolve #{host}: #{reason}"}
            end
        end
    end
  end

  def family(ip) when tuple_size(ip) == 8, do: [:inet6]
  def family(_ip), do: []

  # returns {:ok, sock, %{connect_us, tls_us}}
  def connect(origin, opts, timeout) do
    t0 = now()

    tcp_opts = [
      :binary,
      active: false,
      packet: :raw,
      nodelay: true,
      send_timeout: timeout,
      send_timeout_close: true
    ]

    case :gen_tcp.connect(origin.ip, origin.port, family(origin.ip) ++ tcp_opts, timeout) do
      {:ok, sock} ->
        t1 = now()

        if origin.tls do
          case :ssl.connect(sock, tls_options(origin.host, opts), timeout) do
            {:ok, tls} -> {:ok, {:ssl, tls}, %{connect_us: t1 - t0, tls_us: now() - t1}}
            {:error, reason} -> {:error, {:tls, reason}}
          end
        else
          {:ok, {:gen_tcp, sock}, %{connect_us: t1 - t0}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def tls_options(host, opts) do
    sni =
      if match?({:ok, _}, :inet.parse_address(String.to_charlist(host))),
        do: :disable,
        else: String.to_charlist(host)

    if opts[:insecure] do
      [verify: :verify_none, server_name_indication: sni]
    else
      [
        verify: :verify_peer,
        cacerts: opts[:cacerts] || :public_key.cacerts_get(),
        server_name_indication: sni,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    end
  end

  def send({mod, s}, data), do: mod.send(s, data)
  def recv({mod, s}, n, timeout), do: mod.recv(s, n, timeout)
  def close({mod, s}), do: mod.close(s)

  def setopts({:gen_tcp, s}, opts), do: :inet.setopts(s, opts)
  def setopts({:ssl, s}, opts), do: :ssl.setopts(s, opts)

  def raw({_mod, s}), do: s

  def now, do: System.monotonic_time(:microsecond)
end
