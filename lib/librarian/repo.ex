defmodule Librarian.Repo do
  use Ecto.Repo,
    otp_app: :librarian,
    adapter: Ecto.Adapters.Postgres

  @moduledoc """
  Repo with tenancy enforcement. The current user is process state
  (`put_user_id/1`, set by the auth plug / LiveView mount / worker entry), and
  `prepare_query/3` auto-scopes every query whose FROM is a tenanted schema.

  Rules the callback enforces:

  - A query FROM a tenanted schema gets `where: user_id == ^current` injected.
    With no tenant set it raises — fail fast, no silent cross-tenant reads.
  - A tenanted schema may not appear as a direct join source; join through a
    user-scoped subquery instead (see `Reader.my_read_states/0`), because a
    plain WHERE would break left-join semantics.
  - Untenanted schemas (the shared feed/article catalog, users, Oban) pass
    through untouched.
  - System queries that legitimately cross tenants pass `skip_tenant: true`.

  Inserts are not covered — writes stamp `user_id: Repo.user_id!()` explicitly.
  Subqueries inside a passing query are not inspected; scoped helpers must
  bake the user filter in.
  """

  import Ecto.Query, only: [where: 2]

  @tenant_key {__MODULE__, :user_id}

  @tenanted [
    Librarian.Reader.Subscription,
    Librarian.Reader.ReadState,
    Librarian.Stream.Interaction,
    Librarian.Vault.Note,
    Librarian.Vault.Notebook,
    Librarian.Vault.Tag,
    Librarian.Vault.Annotation,
    Librarian.Vault.Edge,
    Librarian.Interest.Centroid,
    Librarian.Interest.Affinity,
    Librarian.Discovery.CandidateSource,
    Librarian.Settings,
    Librarian.LLM.Usage
  ]

  @doc """
  The schemas this Repo enforces tenancy on. `tenancy_enforcement_test.exs`
  asserts every schema with a `user_id` field is in this list, so a new
  tenanted schema can't silently ship unscoped.
  """
  def tenanted_schemas, do: @tenanted

  def put_user_id(user_id), do: Process.put(@tenant_key, user_id)

  def user_id! do
    Process.get(@tenant_key) ||
      raise "no tenant set — call Librarian.Repo.put_user_id/1 before touching tenanted data"
  end

  @doc "Runs `fun` with the tenant set to `user_id`, restoring the previous tenant after."
  def with_user(user_id, fun) do
    previous = Process.get(@tenant_key)
    Process.put(@tenant_key, user_id)

    try do
      fun.()
    after
      if previous,
        do: Process.put(@tenant_key, previous),
        else: Process.delete(@tenant_key)
    end
  end

  @doc """
  Captures the current tenant and returns a zero-arity function that
  re-establishes it before invoking `fun`. Use this to hand tenanted work to a
  freshly spawned process — `start_async`, `Task.start`, `Task.async_stream` —
  which does not inherit the caller's process-dictionary tenant.

      start_async(socket, :mind_map, Repo.bind_tenant(&Vault.mind_map/0))
  """
  def bind_tenant(fun) when is_function(fun, 0) do
    user_id = user_id!()
    fn -> with_user(user_id, fun) end
  end

  # The tenant travels in the query opts (not just the process dictionary)
  # because Ecto's preloader runs preload queries in Task processes that
  # don't inherit the pdict — opts are captured at the call site.
  @impl true
  def default_options(_operation) do
    [tenant_user_id: Process.get(@tenant_key)]
  end

  @impl true
  def prepare_query(_operation, query, opts) do
    if opts[:skip_tenant] || opts[:schema_migration] do
      {query, opts}
    else
      assert_no_raw_tenanted_joins!(query)

      cond do
        not tenanted_from?(query) ->
          {query, opts}

        user_id = opts[:tenant_user_id] ->
          {where(query, user_id: ^user_id), opts}

        true ->
          raise "no tenant set — call Librarian.Repo.put_user_id/1 before touching tenanted data"
      end
    end
  end

  defp tenanted_from?(%{from: %{source: {_table, schema}}}) when schema in @tenanted, do: true
  defp tenanted_from?(_query), do: false

  defp assert_no_raw_tenanted_joins!(query) do
    Enum.each(query.joins, fn
      %{source: {_table, schema}} when schema in @tenanted ->
        raise ArgumentError,
              "#{inspect(schema)} is tenanted and cannot be joined directly — " <>
                "join it through a user-scoped subquery (or pass skip_tenant: true)"

      _join ->
        :ok
    end)
  end
end
