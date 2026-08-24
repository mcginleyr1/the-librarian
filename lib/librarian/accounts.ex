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

  def list_user_ids do
    Repo.all(from u in User, select: u.id, order_by: u.id)
  end

  @doc """
  Runs `fun` once per user with that user's tenant set — the entry point for
  cross-user maintenance passes (cron workers that touch every tenant's data).
  """
  def each_user(fun) when is_function(fun, 0) do
    Enum.each(list_user_ids(), fn user_id -> Repo.with_user(user_id, fun) end)
  end

  def get_user_by_api_token(token) when is_binary(token) and token != "" do
    Repo.get_by(User, api_token: token)
  end

  def get_user_by_api_token(_token), do: nil

  @doc "Returns the user's API token, generating and persisting one if absent."
  def ensure_api_token!(%User{api_token: token} = user) when is_binary(token), do: user

  def ensure_api_token!(%User{} = user) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    user |> Ecto.Changeset.change(api_token: token) |> Repo.update!()
  end

  def regenerate_api_token!(%User{} = user) do
    ensure_api_token!(%{user | api_token: nil})
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
