defmodule Librarian.Accounts do
  @moduledoc """
  Users: OAuth sign-in gated by the `ALLOWED_EMAILS` allowlist, API tokens,
  the deployment owner, and per-user fan-out of cron jobs.
  """

  import Ecto.Query
  alias Librarian.Accounts.User
  alias Librarian.Repo

  def get_user(id), do: Repo.get(User, id)

  @doc """
  The deployment owner: the first user. CLI import and release tasks write
  into this user's vault; API requests act as their token's user.
  """
  def owner! do
    Repo.one!(from u in User, order_by: [asc: u.id], limit: 1)
  end

  def list_user_ids do
    Repo.all(from u in User, select: u.id, order_by: u.id)
  end

  @doc """
  Enqueues `worker` once per user (args `%{"user_id" => id}`) — the entry point
  for cron workers that touch every tenant's data. One job per user means one
  user's failure retries alone instead of starving everyone after them.
  """
  def enqueue_per_user(worker) do
    list_user_ids() |> Enum.map(&worker.new(%{"user_id" => &1})) |> Oban.insert_all()
    :ok
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

  @doc """
  Whether the email is on the operator allowlist (`ALLOWED_EMAILS`), the
  sign-in gate. Allowlisted users are also admins (Oban dashboard).
  """
  def allowed_email?(email) when is_binary(email) do
    allowed = Enum.map(Application.fetch_env!(:librarian, :allowed_emails), &String.downcase/1)
    String.downcase(email) in allowed
  end

  def allowed_email?(_), do: false

  def admin?(%User{email: email}), do: allowed_email?(email)
  def admin?(_), do: false

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
