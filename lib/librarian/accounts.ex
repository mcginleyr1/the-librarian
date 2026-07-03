defmodule Librarian.Accounts do
  import Ecto.Query
  alias Librarian.Accounts.User
  alias Librarian.Repo

  def get_user(id), do: Repo.get(User, id)

  @doc """
  The deployment owner: the first (in practice, only) user. All data created
  by background workers and the clip API is bound to this user.
  """
  def owner! do
    Repo.one!(from u in User, order_by: [asc: u.id], limit: 1)
  end

  def allowed_email?(email) when is_binary(email) do
    String.downcase(email) in Application.fetch_env!(:librarian, :allowed_emails)
  end

  def allowed_email?(_), do: false

  @doc """
  Finds or creates the user for a completed `Ueberauth.Auth`. Matches by
  email so the migration-created owner row (which has no provider uid yet)
  is claimed on first login.
  """
  def upsert_user_from_auth(%Ueberauth.Auth{} = auth) do
    attrs = %{
      email: auth.info.email,
      name: auth.info.name,
      avatar_url: auth.info.image,
      provider: to_string(auth.provider),
      provider_uid: to_string(auth.uid)
    }

    case Repo.get_by(User, email: String.downcase(auth.info.email)) do
      nil -> %User{}
      user -> user
    end
    |> User.changeset(attrs)
    |> Repo.insert_or_update()
  end
end
