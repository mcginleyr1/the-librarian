defmodule LibrarianWeb.DashboardLiveTest do
  use LibrarianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Librarian.{Reader, Repo, Stream}
  alias Librarian.Reader.Article

  test "renders signal stats and the rebuild control", %{conn: conn} do
    {:ok, feed} =
      Reader.create_feed(%{
        title: "F",
        feed_url: "https://x/#{System.unique_integer([:positive])}"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    article =
      %Article{}
      |> Article.changeset(%{feed_id: feed.id, guid: "g1", title: "OTP guide", fetched_at: now})
      |> Repo.insert!()

    Stream.record_interaction(article.id, :like)

    {:ok, view, _html} = live(conn, "/dashboard")

    assert has_element?(view, "#rebuild-model")
    assert render(view) =~ "Feedback Dashboard"
    assert render(view) =~ "Learned profile"

    # rebuilding the model keeps the page healthy
    assert view |> element("#rebuild-model") |> render_click() =~ "Interest clusters"
  end
end
