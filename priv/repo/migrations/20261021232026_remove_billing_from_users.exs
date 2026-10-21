defmodule Librarian.Repo.Migrations.RemoveBillingFromUsers do
  use Ecto.Migration

  def change do
    drop unique_index(:users, [:stripe_customer_id])

    alter table(:users) do
      remove :stripe_customer_id, :string
      remove :stripe_subscription_id, :string
      remove :subscription_status, :string
      remove :subscription_period_end, :utc_datetime
    end
  end
end
