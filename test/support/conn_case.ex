defmodule LibrarianWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use LibrarianWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint LibrarianWeb.Endpoint

      use LibrarianWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import LibrarianWeb.ConnCase
    end
  end

  setup tags do
    Librarian.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Logs the given user into the test connection's session.
  """
  def log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  @doc """
  Setup helper (`setup :log_in_owner`) that logs in the deployment owner —
  the first user, seeded in test_helper.exs.
  """
  def log_in_owner(%{conn: conn}) do
    user = Librarian.Accounts.owner!()
    %{conn: log_in_user(conn, user), user: user}
  end
end
