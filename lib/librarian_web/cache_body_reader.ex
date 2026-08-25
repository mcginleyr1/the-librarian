defmodule LibrarianWeb.CacheBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the raw request body for webhook
  routes (Stripe signatures are computed over the exact bytes, which the
  JSON parser would otherwise consume). All other paths read normally.
  """

  def read_body(%Plug.Conn{path_info: ["webhooks" | _]} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, chunk, store(conn, chunk)}
      {:more, chunk, conn} -> {:more, chunk, store(conn, chunk)}
      {:error, _reason} = error -> error
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  @doc "The cached raw body, or nil outside webhook routes."
  def raw_body(%Plug.Conn{private: %{raw_body: chunks}}) do
    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  def raw_body(_conn), do: nil

  defp store(conn, chunk) do
    chunks = [chunk | conn.private[:raw_body] || []]
    Plug.Conn.put_private(conn, :raw_body, chunks)
  end
end
