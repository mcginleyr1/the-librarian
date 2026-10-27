defmodule Librarian.SafeHTTP do
  @moduledoc """
  Outbound requests to user-supplied URLs (feeds, feed discovery, backup
  endpoints). Only http(s) is allowed, and any host resolving to a loopback,
  private, link-local, CGNAT/Tailscale or multicast address is refused —
  checked again on every redirect hop — so a feed URL can't reach the cluster,
  the tailnet or a metadata service.

  Responses are bounded: bodies stop at `:max_body_bytes`, the whole transfer
  at `:deadline_ms`, bodies are never decompressed or decoded (no gzip bombs,
  no surprise maps from JSON), and nothing is retried here (Oban retries jobs).

  The address check and the connection resolve DNS separately, so a rebinding
  host can still slip through; the cluster's egress NetworkPolicy is the
  backstop for that.
  """

  @max_redirects 5
  @max_body_bytes 10_000_000
  @deadline_ms 60_000

  def get(url, opts \\ []), do: follow(url, opts, @max_redirects)

  defp follow(url, opts, redirects_left) do
    with {:ok, uri} <- check_url(url),
         {:ok, resp} <- request(uri, opts) do
      location = Req.Response.get_header(resp, "location")

      cond do
        resp.status not in [301, 302, 303, 307, 308] or location == [] -> {:ok, resp}
        redirects_left == 0 -> {:error, :too_many_redirects}
        true -> follow(uri |> URI.merge(hd(location)) |> to_string(), opts, redirects_left - 1)
      end
    end
  end

  defp request(uri, opts) do
    {max_bytes, opts} = Keyword.pop(opts, :max_body_bytes, @max_body_bytes)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :deadline_ms, @deadline_ms)

    req_opts =
      [
        redirect: false,
        retry: false,
        # raw: no decompress_body / decode_body steps (no gzip bombs, no
        # decoded maps); compressed: false asks servers not to compress.
        compressed: false,
        raw: true,
        into: fn {:data, data}, {req, resp} ->
          resp = %{resp | body: resp.body <> data}

          cond do
            byte_size(resp.body) > max_bytes -> halt(req, resp, :body_too_large)
            System.monotonic_time(:millisecond) > deadline -> halt(req, resp, :deadline_exceeded)
            true -> {:cont, {req, resp}}
          end
        end
      ]
      |> Keyword.merge(Keyword.delete(opts, :deadline_ms))

    case Req.get(to_string(uri), req_opts) do
      {:ok, resp} ->
        case Req.Response.get_private(resp, :safe_http_error) do
          nil -> {:ok, resp}
          reason -> {:error, reason}
        end

      error ->
        error
    end
  end

  defp halt(req, resp, reason) do
    {:halt, {req, Req.Response.put_private(resp, :safe_http_error, reason)}}
  end

  @doc "`{:ok, uri}` if `url` is http(s) and its host resolves only to public addresses."
  def check_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :unsupported_scheme}
      uri.host in [nil, ""] -> {:error, :invalid_url}
      true -> check_host(uri)
    end
  end

  def check_url(_url), do: {:error, :invalid_url}

  defp check_host(uri) do
    case resolve(uri.host) do
      [] -> {:error, :nxdomain}
      ips -> if Enum.any?(ips, &internal?/1), do: {:error, :forbidden_address}, else: {:ok, uri}
    end
  end

  defp resolve(host) do
    host = String.to_charlist(host)

    case :inet.parse_address(host) do
      {:ok, ip} ->
        [ip]

      {:error, _} ->
        for family <- [:inet, :inet6],
            {:ok, ips} <- [:inet.getaddrs(host, family)],
            ip <- ips,
            do: ip
    end
  end

  @doc false
  def internal?({a, _, _, _}) when a in [0, 10, 127] or a >= 224, do: true
  def internal?({100, b, _, _}) when b in 64..127, do: true
  def internal?({169, 254, _, _}), do: true
  def internal?({172, b, _, _}) when b in 16..31, do: true
  def internal?({192, 168, _, _}), do: true
  def internal?({192, 0, 0, _}), do: true
  def internal?({198, b, _, _}) when b in 18..19, do: true
  def internal?({_, _, _, _}), do: false

  # IPv4-mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::a.b.c.d) embed an IPv4 address.
  def internal?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: internal?(ipv4(hi, lo))
  def internal?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: internal?(ipv4(hi, lo))
  def internal?({0, 0, 0, 0, 0, 0, 0, last}) when last in [0, 1], do: true

  def internal?({first, _, _, _, _, _, _, _}) do
    first in 0xFC00..0xFDFF or first in 0xFE80..0xFEBF or first >= 0xFF00
  end

  defp ipv4(hi, lo), do: {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}
end
