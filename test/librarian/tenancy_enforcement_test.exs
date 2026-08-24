defmodule Librarian.TenancyEnforcementTest do
  @moduledoc """
  Structural guards so new features can't quietly skip tenancy. These fail the
  build (they run in `mix precommit`) rather than relying on review to notice.

  Tenancy lives in `Librarian.Repo` — see [[tenancy_boundaries]]. Ecto queries
  are auto-scoped and fail fast, but two paths have no runtime guard: a new
  schema forgetting `@tenanted`, and raw SQL / `skip_tenant` that bypass
  `prepare_query`. These tests cover exactly those.
  """
  use ExUnit.Case, async: true

  @lib_files Path.wildcard("lib/**/*.ex")

  describe "every user-owned schema is registered as tenanted" do
    test "a schema with a user_id field must be in Repo.tenanted_schemas/0" do
      schemas_with_user_id =
        :librarian
        |> Application.spec(:modules)
        |> Enum.filter(&Code.ensure_loaded?/1)
        |> Enum.filter(&function_exported?(&1, :__schema__, 1))
        |> Enum.filter(&(:user_id in &1.__schema__(:fields)))

      unregistered = schemas_with_user_id -- Librarian.Repo.tenanted_schemas()

      assert unregistered == [],
             """
             These schemas have a user_id but are not in Librarian.Repo's @tenanted list,
             so their queries are NOT auto-scoped to the current user:

                 #{inspect(unregistered)}

             Add them to @tenanted (or, if they are genuinely shared/global, drop the
             user_id column).
             """
    end
  end

  describe "raw SQL is confined to a reviewed allowlist" do
    # Raw SQL bypasses Repo.prepare_query entirely, so each of these MUST filter
    # user_id by hand. When you add a site, confirm it is user-scoped, then add
    # its file here (and annotate the call with a credo:disable comment).
    @raw_sql_allowlist ~w(
      lib/librarian/vault.ex
      lib/librarian/ranking.ex
    )

    test "no unlisted file issues raw SQL" do
      offenders =
        @lib_files
        |> Enum.filter(fn file ->
          File.read!(file) =~ ~r/\bRepo\.query!?\(|Ecto\.Adapters\.SQL/
        end)

      assert offenders -- @raw_sql_allowlist == [],
             """
             New raw SQL found outside the tenancy allowlist:

                 #{inspect(offenders -- @raw_sql_allowlist)}

             Raw SQL skips Repo's tenancy enforcement. Filter user_id explicitly
             (e.g. `WHERE user_id = $1` with `Repo.user_id!()`), then add the file to
             @raw_sql_allowlist in this test.
             """
    end
  end

  describe "skip_tenant is confined to a reviewed allowlist" do
    # skip_tenant deliberately disables scoping. Each read must either re-scope
    # via Repo.with_user(row.user_id, ...) or be a genuine cross-tenant/system op.
    @skip_tenant_allowlist ~w(
      lib/librarian/repo.ex
      lib/librarian/reader.ex
      lib/librarian/workers/embed_articles_worker.ex
      lib/librarian/workers/extract_edges_worker.ex
      lib/librarian/workers/vet_candidate_source_worker.ex
      lib/mix/tasks/librarian.embed_backfill.ex
    )

    test "no unlisted file passes skip_tenant" do
      offenders =
        @lib_files
        |> Enum.filter(fn file -> File.read!(file) =~ "skip_tenant" end)

      assert offenders -- @skip_tenant_allowlist == [],
             """
             New skip_tenant usage found outside the allowlist:

                 #{inspect(offenders -- @skip_tenant_allowlist)}

             skip_tenant disables tenancy. Ensure the read re-scopes with
             Repo.with_user/2 or is a true cross-tenant op, then add the file to
             @skip_tenant_allowlist in this test.
             """
    end
  end
end
