defmodule Librarian.CredoChecks.RawSQL do
  @moduledoc """
  Flags raw SQL (`Repo.query`, `Repo.query!`, `Ecto.Adapters.SQL.query`), which
  bypasses `Librarian.Repo.prepare_query/3` and its tenancy enforcement.

  Raw SQL against a tenanted table MUST filter `user_id` by hand
  (`WHERE user_id = $1` with `Repo.user_id!()`). When a call is verified safe,
  silence this check on its line:

      # credo:disable-for-next-line Librarian.CredoChecks.RawSQL
      Repo.query!(sql, [Repo.user_id!()])

  See [[tenancy_boundaries]] and `test/librarian/tenancy_enforcement_test.exs`,
  which enforces the same rule as a hard build failure.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Raw SQL is not scoped to the current tenant by Repo.prepare_query. Every
      raw query against a user-owned table must filter user_id explicitly, then
      annotate the call with `# credo:disable-for-next-line` once verified.
      """
    ]

  @impl Credo.Check
  def run(%Credo.SourceFile{} = source_file, params) do
    issue_meta = Credo.IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse(
         {{:., _, [{:__aliases__, _, mods}, fun]}, meta, _args} = ast,
         issues,
         issue_meta
       )
       when fun in [:query, :query!] do
    if List.last(mods) in [:Repo, :SQL] do
      {ast, [issue_for(issue_meta, meta[:line], fun) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue_for(issue_meta, line_no, fun) do
    format_issue(
      issue_meta,
      message:
        "Raw SQL (#{fun}) bypasses Repo tenancy enforcement — filter user_id explicitly, " <>
          "then add `# credo:disable-for-next-line Librarian.CredoChecks.RawSQL`.",
      line_no: line_no
    )
  end
end
