ExUnit.start()

# The deployment owner (first user) that tests run as; committed outside the
# sandbox so every test sees the same row.
Librarian.Repo.insert!(%Librarian.Accounts.User{email: "owner@example.com", name: "Owner"},
  on_conflict: :nothing,
  conflict_target: :email
)

Ecto.Adapters.SQL.Sandbox.mode(Librarian.Repo, :manual)
