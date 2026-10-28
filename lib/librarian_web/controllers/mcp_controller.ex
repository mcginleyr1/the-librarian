defmodule LibrarianWeb.McpController do
  @moduledoc """
  A Model Context Protocol server on the Streamable HTTP transport: one
  JSON-RPC message per POST to `/mcp`, each request answered with a single
  JSON response (no SSE streams, no sessions). It sits behind the API bearer
  token, so every tool runs as the token's user inside their tenancy (see
  `LibrarianWeb.McpTools`).

  Both protocol eras are served on the one endpoint:

  - 2026-07-28 is stateless: each request carries its version and client
    capabilities in `_meta`, mirrored into `MCP-Protocol-Version`, `Mcp-Method`
    and `Mcp-Name` headers that must match the body.
  - 2025-11-25 and 2025-06-18 open with `initialize`. No `Mcp-Session-Id` is
    minted, so each later request stands alone on its `MCP-Protocol-Version`.
  """
  use LibrarianWeb, :controller

  alias LibrarianWeb.McpTools

  @modern_versions ["2026-07-28"]
  @legacy_versions ["2025-11-25", "2025-06-18"]
  @supported_versions @modern_versions ++ @legacy_versions

  @server_info %{
    name: "the-librarian",
    title: "The Librarian",
    version: Mix.Project.config()[:version]
  }
  @capabilities %{tools: %{}}
  # Clients may cache tool lists this long; they only change on deploy.
  @cache %{ttlMs: 300_000, cacheScope: "private"}

  # JSON-RPC error codes, then the MCP-defined ones.
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @header_mismatch -32_020
  @unsupported_version -32_022

  @instructions """
  The Librarian is the user's personal knowledge base: their own notes \
  (markdown notes, web clips and saved PDFs, filed in notebooks) and the \
  articles from the RSS feeds they follow. Search it before answering \
  questions about things the user wrote, saved or read, then read the note or \
  article you need in full. Only save a note when the user asks for something \
  to be written down.\
  """

  def create(conn, _params) do
    if origin_allowed?(conn),
      do: handle(conn, conn.body_params),
      else: reply(conn, 403, error(nil, @invalid_request, "Origin not allowed"))
  end

  def method_not_allowed(conn, _params) do
    conn |> put_resp_header("allow", "POST") |> send_resp(405, "")
  end

  defp handle(conn, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = message)
       when (is_binary(id) or is_integer(id)) and is_binary(method) do
    params = if is_map(message["params"]), do: message["params"], else: %{}

    case params do
      %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}} ->
        modern(conn, id, method, params, version)

      _ ->
        legacy(conn, id, method, params)
    end
  end

  # Notifications (notifications/initialized, notifications/cancelled) need
  # no answer.
  defp handle(conn, %{"jsonrpc" => "2.0", "method" => method} = message)
       when is_binary(method) and not is_map_key(message, "id"),
       do: send_resp(conn, 202, "")

  defp handle(conn, _message),
    do: reply(conn, 400, error(nil, @invalid_request, "Invalid Request"))

  defp modern(conn, id, method, params, version) do
    cond do
      version not in @modern_versions ->
        unsupported_version(conn, id, version)

      mismatch = header_mismatch(conn, method, params, version) ->
        reply(conn, 400, error(id, @header_mismatch, "Header mismatch: " <> mismatch))

      not is_map(params["_meta"]["io.modelcontextprotocol/clientCapabilities"]) ->
        missing_meta(conn, id, "clientCapabilities")

      true ->
        run(conn, id, :modern, method, params)
    end
  end

  defp legacy(conn, id, "initialize", params) do
    requested = params["protocolVersion"]
    version = if requested in @legacy_versions, do: requested, else: hd(@legacy_versions)

    reply(conn, 200, %{
      jsonrpc: "2.0",
      id: id,
      result: %{
        protocolVersion: version,
        capabilities: @capabilities,
        serverInfo: @server_info,
        instructions: @instructions
      }
    })
  end

  # Without a session the version comes from the header on every request; one
  # without it would be 2025-03-26, which isn't served.
  defp legacy(conn, id, method, params) do
    case get_req_header(conn, "mcp-protocol-version") do
      [version] when version in @legacy_versions ->
        run(conn, id, :legacy, method, params)

      [version] when version in @modern_versions ->
        missing_meta(conn, id, "protocolVersion")

      headers ->
        unsupported_version(conn, id, List.first(headers, "2025-03-26"))
    end
  end

  defp run(conn, id, era, method, params) do
    case dispatch(era, method, params) do
      {:ok, result} ->
        reply(conn, 200, %{jsonrpc: "2.0", id: id, result: complete(era, result)})

      {:error, :method_not_found} ->
        status = if era == :modern, do: 404, else: 200
        reply(conn, status, error(id, @method_not_found, "Method not found: #{method}"))

      {:error, code, message} ->
        reply(conn, 200, error(id, code, message))
    end
  end

  defp dispatch(:legacy, "ping", _params), do: {:ok, %{}}

  defp dispatch(:modern, "server/discover", _params) do
    {:ok,
     Map.merge(@cache, %{
       supportedVersions: @supported_versions,
       capabilities: @capabilities,
       instructions: @instructions
     })}
  end

  defp dispatch(:modern, "tools/list", _params),
    do: {:ok, Map.put(@cache, :tools, McpTools.list())}

  defp dispatch(:legacy, "tools/list", _params), do: {:ok, %{tools: McpTools.list()}}

  defp dispatch(_era, "tools/call", %{"name" => name} = params) when is_binary(name) do
    arguments = if is_map(params["arguments"]), do: params["arguments"], else: %{}

    case McpTools.call(name, arguments) do
      {:ok, data} ->
        {:ok, %{content: [%{type: "text", text: Jason.encode!(data)}], isError: false}}

      {:error, message} ->
        {:ok, %{content: [%{type: "text", text: message}], isError: true}}

      :unknown_tool ->
        {:error, @invalid_params, "Unknown tool: #{name}"}
    end
  end

  defp dispatch(_era, "tools/call", _params),
    do: {:error, @invalid_params, "tools/call needs a name"}

  defp dispatch(_era, _method, _params), do: {:error, :method_not_found}

  defp complete(:legacy, result), do: result

  defp complete(:modern, result) do
    Map.merge(result, %{
      resultType: "complete",
      _meta: %{"io.modelcontextprotocol/serverInfo" => @server_info}
    })
  end

  defp header_mismatch(conn, method, params, version) do
    cond do
      header(conn, "mcp-protocol-version") != version ->
        "MCP-Protocol-Version does not match _meta"

      header(conn, "mcp-method") != method ->
        "Mcp-Method does not match the request method"

      method == "tools/call" and decode(header(conn, "mcp-name")) != params["name"] ->
        "Mcp-Name does not match the tool name"

      true ->
        nil
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  # Header values outside plain ASCII arrive as `=?base64?<value>?=`.
  defp decode("=?base64?" <> encoded = raw) do
    case encoded |> String.replace_suffix("?=", "") |> Base.decode64() do
      {:ok, value} -> value
      :error -> raw
    end
  end

  defp decode(value), do: value

  # The transport's DNS-rebinding guard: a page on another origin may not
  # drive the endpoint from a browser. Non-browser clients send no Origin.
  defp origin_allowed?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin | _] -> URI.parse(origin).host == LibrarianWeb.Endpoint.host()
    end
  end

  defp unsupported_version(conn, id, requested) do
    data = %{supported: @supported_versions, requested: requested}
    reply(conn, 400, error(id, @unsupported_version, "Unsupported protocol version", data))
  end

  defp missing_meta(conn, id, field) do
    message = "_meta is missing io.modelcontextprotocol/#{field}"
    reply(conn, 400, error(id, @invalid_params, message))
  end

  defp reply(conn, status, body), do: conn |> put_status(status) |> json(body)

  defp error(id, code, message, data \\ nil) do
    error = reject_nil(%{code: code, message: message, data: data})
    reject_nil(%{jsonrpc: "2.0", id: id, error: error})
  end

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
