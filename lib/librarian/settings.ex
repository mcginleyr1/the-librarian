defmodule Librarian.Settings do
  use Ecto.Schema
  import Ecto.Changeset
  alias Librarian.Repo

  @primary_key {:id, :id, autogenerate: false}
  schema "settings" do
    field :b2_key_id, :string
    field :b2_application_key, :string
    field :b2_bucket_name, :string
    field :b2_endpoint, :string
    field :last_backup_at, :utc_datetime
    field :category_order, {:array, :string}, default: []
    field :pinned_lenses, {:array, :string}, default: []

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
      :pinned_lenses
    ])
  end

  def get_settings do
    Repo.get(__MODULE__, 1)
  end

  def save_settings(attrs) do
    existing = get_settings() || %__MODULE__{id: 1, user_id: Librarian.Accounts.owner!().id}

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

  def pinned_lenses do
    case get_settings() do
      %{pinned_lenses: lenses} when is_list(lenses) -> lenses
      _ -> []
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
