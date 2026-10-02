defmodule LibrarianWeb.BillingHTML do
  @moduledoc "Subscription pages rendered by BillingController."
  use LibrarianWeb, :html

  embed_templates "billing_html/*"
end
