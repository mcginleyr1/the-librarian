defmodule Librarian.Settings do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]
  alias Librarian.Repo

  schema "settings" do
    field :b2_key_id, :string
    field :b2_application_key, :string
    field :b2_bucket_name, :string
    field :b2_endpoint, :string
    field :last_backup_at, :utc_datetime
    field :category_order, {:array, :string}, default: []
    field :pinned_lenses, {:array, :string}, default: []
    field :anthropic_api_key, :string
    field :llm_monthly_budget_cents, :integer, default: 2000
    field :discovery_paused, :boolean, default: false

    belongs_to :user, Librarian.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    cast(settings, attrs, [
      :b2_key_id,
      :b2_application_key,
      :b2_bucket_name,
      :b2_endpoint,
      :category_order,
      :pinned_lenses,
      :anthropic_api_key,
      :llm_monthly_budget_cents,
      :discovery_paused
    ])
    |> validate_number(:llm_monthly_budget_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:user_id, name: :settings_user_id_unique_index)
  end

  def get_settings do
    Repo.one(from s in __MODULE__, limit: 1)
  end

  def save_settings(attrs) do
    existing = get_settings() || %__MODULE__{user_id: Repo.user_id!()}

    existing
    |> changeset(attrs)
    |> Repo.insert_or_update()
  end

  def category_order do
    case get_settings() do
      %{category_order: order} when is_list(order) -> order
      _ -> []
    end
  end

  def discovery_paused? do
    match?(%{discovery_paused: true}, get_settings())
  end

  def pinned_lenses do
    case get_settings() do
      %{pinned_lenses: lenses} when is_list(lenses) -> lenses
      _ -> []
    end
  end

  def llm_monthly_budget_cents do
    case get_settings() do
      %{llm_monthly_budget_cents: cents} when is_integer(cents) -> cents
      _ -> 2000
    end
  end

  def configured? do
    case get_settings() do
      %{b2_key_id: key_id, b2_application_key: app_key}
      when not is_nil(key_id) and key_id != "" and
             not is_nil(app_key) and app_key != "" ->
        true

      _ ->
        false
    end
  end
end
