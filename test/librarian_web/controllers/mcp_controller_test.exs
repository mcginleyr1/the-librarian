defmodule LibrarianWeb.McpControllerTest do
  use LibrarianWeb.ConnCase, async: true

  alias Librarian.{Accounts, Repo}

  @modern "2026-07-28"
  @tool_names ~w(search_notes read_note list_notebooks save_note search_articles read_article
                 recent_reading list_feeds follow_sites)

  setup %{conn: conn} do
    user = Accounts.ensure_api_token!(insert_allowed_user!("mcp"))

    Repo.put_user_id(user.id)
    %{conn: put_req_header(conn, "authorization", "Bearer #{user.api_token}")}
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post(~p"/mcp", Jason.encode!(body))
  end

  defp legacy(conn, method, params \\ %{}, version \\ "2025-11-25") do
    conn
    |> put_req_header("mcp-protocol-version", version)
    |> post_json(%{jsonrpc: "2.0", id: 1, method: method, params: params})
  end

  # A 2026-07-28 request: version and capabilities in `_meta`, mirrored into
  # the headers. `headers` overrides (or, with nil, drops) a mirrored header.
  defp modern(conn, method, params \\ %{}, headers \\ %{}) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    %{"mcp-protocol-version" => @modern, "mcp-method" => method, "mcp-name" => params["name"]}
    |> Map.merge(headers)
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> post_json(%{
      jsonrpc: "2.0",
      id: "req-1",
      method: method,
      params: Map.put(params, "_meta", meta)
    })
  end

  describe "authentication" do
    test "requires a valid API bearer token" do
      for conn <- [build_conn(), put_req_header(build_conn(), "authorization", "Bearer nope")] do
        conn = post_json(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"})
        assert json_response(conn, 401) == %{"error" => "unauthorized"}
      end
    end

    test "refuses browser requests from another origin", %{conn: conn} do
      foreign = conn |> put_req_header("origin", "https://evil.example") |> legacy("ping")
      assert json_response(foreign, 403)["error"]["code"] == -32_600

      own = conn |> put_req_header("origin", "http://localhost:4000") |> legacy("ping")
      assert json_response(own, 200)["result"] == %{}
    end
  end

  describe "transport" do
    test "GET and DELETE are 405, even for SSE probes", %{conn: conn} do
      conn = put_req_header(conn, "accept", "text/event-stream")

      for conn <- [get(conn, ~p"/mcp"), delete(conn, ~p"/mcp")] do
        assert response(conn, 405) == ""
        assert get_resp_header(conn, "allow") == ["POST"]
      end
    end

    test "notifications are accepted without a body", %{conn: conn} do
      conn = post_json(conn, %{jsonrpc: "2.0", method: "notifications/initialized"})
      assert response(conn, 202) == ""
    end

    test "anything that isn't a JSON-RPC request or notification is a 400", %{conn: conn} do
      for body <- [%{hello: "world"}, [%{jsonrpc: "2.0", id: 1, method: "ping"}]] do
        assert %{"id" => nil, "error" => %{"code" => -32_600}} =
                 conn |> post_json(body) |> json_response(400)
      end
    end
  end

  describe "2025 protocol versions (initialize handshake)" do
    test "initialize negotiates a version without minting a session", %{conn: conn} do
      conn =
        post_json(conn, %{
          jsonrpc: "2.0",
          id: 0,
          method: "initialize",
          params: %{protocolVersion: "2025-06-18", capabilities: %{}, clientInfo: %{name: "t"}}
        })

      assert %{"id" => 0, "result" => result} = json_response(conn, 200)
      assert result["protocolVersion"] == "2025-06-18"
      assert result["capabilities"] == %{"tools" => %{}}
      assert result["serverInfo"]["name"] == "the-librarian"
      assert result["instructions"] =~ "knowledge base"
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    test "initialize answers an unknown version with the latest supported one", %{conn: conn} do
      conn =
        post_json(conn, %{
          jsonrpc: "2.0",
          id: 0,
          method: "initialize",
          params: %{protocolVersion: "2024-11-05", capabilities: %{}}
        })

      assert json_response(conn, 200)["result"]["protocolVersion"] == "2025-11-25"
    end

    test "ping and tools/list", %{conn: conn} do
      assert conn |> legacy("ping") |> json_response(200) == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{}
             }

      result = conn |> legacy("tools/list", %{}, "2025-06-18") |> json_response(200)
      assert Enum.map(result["result"]["tools"], & &1["name"]) == @tool_names
      refute Map.has_key?(result["result"], "resultType")
    end

    test "a request without MCP-Protocol-Version is an unsupported 2025-03-26", %{conn: conn} do
      conn = post_json(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"})

      assert %{"code" => -32_022, "data" => data} = json_response(conn, 400)["error"]
      assert data["requested"] == "2025-03-26"
      assert @modern in data["supported"]
    end

    test "unknown methods are JSON-RPC errors", %{conn: conn} do
      assert conn |> legacy("resources/list") |> json_response(200) |> get_in(~w(error code)) ==
               -32_601
    end
  end

  describe "2026-07-28 (stateless)" do
    test "server/discover lists versions, capabilities and identity", %{conn: conn} do
      result = conn |> modern("server/discover") |> json_response(200) |> Map.fetch!("result")

      assert result["resultType"] == "complete"
      assert result["supportedVersions"] == [@modern, "2025-11-25", "2025-06-18"]
      assert result["capabilities"] == %{"tools" => %{}}
      assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "the-librarian"
    end

    test "tools/list is complete, cacheable and in a fixed order", %{conn: conn} do
      result = conn |> modern("tools/list") |> json_response(200) |> Map.fetch!("result")

      assert Enum.map(result["tools"], & &1["name"]) == @tool_names
      assert %{"resultType" => "complete", "ttlMs" => ttl, "cacheScope" => "private"} = result
      assert ttl > 0

      for tool <- result["tools"] do
        assert tool["description"] != ""
        assert tool["inputSchema"]["type"] == "object"
      end
    end

    test "an unsupported version is rejected with the supported list", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-protocol-version", "1900-01-01")
        |> put_req_header("mcp-method", "tools/list")
        |> post_json(%{
          jsonrpc: "2.0",
          id: 7,
          method: "tools/list",
          params: %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => "1900-01-01",
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        })

      assert %{"id" => 7, "error" => %{"code" => -32_022, "data" => data}} =
               json_response(conn, 400)

      assert data["requested"] == "1900-01-01"
      assert @modern in data["supported"]
    end

    test "headers must mirror the body", %{conn: conn} do
      call = %{"name" => "list_notebooks", "arguments" => %{}}

      for headers <- [
            %{"mcp-method" => nil},
            %{"mcp-method" => "tools/list"},
            %{"mcp-protocol-version" => nil},
            %{"mcp-protocol-version" => "2025-11-25"},
            %{"mcp-name" => nil},
            %{"mcp-name" => "read_note"}
          ] do
        conn = modern(conn, "tools/call", call, headers)
        assert %{"code" => -32_020} = json_response(conn, 400)["error"], inspect(headers)
      end
    end

    test "a base64-encoded Mcp-Name is decoded before comparing", %{conn: conn} do
      encoded = "=?base64?" <> Base.encode64("list_notebooks") <> "?="

      conn =
        modern(conn, "tools/call", %{"name" => "list_notebooks"}, %{"mcp-name" => encoded})

      assert json_response(conn, 200)["result"]["isError"] == false
    end

    test "client capabilities are required in _meta", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-protocol-version", @modern)
        |> put_req_header("mcp-method", "tools/list")
        |> post_json(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/list",
          params: %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => @modern}}
        })

      assert json_response(conn, 400)["error"]["code"] == -32_602
    end

    test "a modern header without _meta is malformed", %{conn: conn} do
      assert conn
             |> legacy("tools/list", %{}, @modern)
             |> json_response(400)
             |> get_in(~w(error code)) ==
               -32_602
    end

    test "methods it doesn't implement are 404, including the old handshake", %{conn: conn} do
      for method <- ["initialize", "ping", "resources/list"] do
        assert %{"id" => "req-1", "error" => %{"code" => -32_601}} =
                 conn |> modern(method) |> json_response(404)
      end
    end

    test "calling an unknown tool is an invalid-params error", %{conn: conn} do
      conn = modern(conn, "tools/call", %{"name" => "delete_everything", "arguments" => %{}})
      assert json_response(conn, 200)["error"]["code"] == -32_602
    end
  end
end
