defmodule Librarian.SafeHTTPTest do
  use ExUnit.Case, async: true

  alias Librarian.SafeHTTP

  describe "check_url/1" do
    test "refuses non-http schemes and malformed URLs" do
      assert {:error, :unsupported_scheme} = SafeHTTP.check_url("file:///etc/passwd")
      assert {:error, :unsupported_scheme} = SafeHTTP.check_url("gopher://example.com")
      assert {:error, :invalid_url} = SafeHTTP.check_url("http://")
      assert {:error, :invalid_url} = SafeHTTP.check_url(nil)
    end

    test "refuses loopback, private, link-local, CGNAT and mapped addresses" do
      for url <- [
            "http://127.0.0.1/",
            "http://localhost:4000/",
            "http://10.0.0.5/",
            "http://172.20.1.1/",
            "http://192.168.1.1/",
            "http://169.254.169.254/computeMetadata/v1/",
            "http://100.101.102.103/",
            "http://0.0.0.0/",
            "http://[::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://[fd00::1]/",
            "http://[fe80::1]/"
          ] do
        assert {:error, :forbidden_address} = SafeHTTP.check_url(url), url
      end
    end

    test "accepts public addresses" do
      assert {:ok, %URI{host: "93.184.215.14"}} = SafeHTTP.check_url("https://93.184.215.14/feed")
      assert {:ok, _} = SafeHTTP.check_url("http://[2606:4700::1111]/")
    end
  end

  test "get/2 refuses internal targets before any request is made" do
    assert {:error, :forbidden_address} = SafeHTTP.get("http://127.0.0.1:1/feed.xml")
    assert {:error, :unsupported_scheme} = SafeHTTP.get("ftp://example.com/feed.xml")
  end
end
