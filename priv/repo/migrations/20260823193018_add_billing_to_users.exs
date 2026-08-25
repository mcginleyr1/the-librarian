defmodule Librarian.Repo.Migrations.AddBillingToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :stripe_customer_id, :string
      add :stripe_subscription_id, :string
      add :subscription_status, :string
      add :subscription_period_end, :utc_datetime
    end

    create unique_index(:users, [:stripe_customer_id])
  end
end
