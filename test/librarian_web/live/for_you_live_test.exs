defmodule LibrarianWeb.ForYouLiveTest do
  use LibrarianWeb.ConnCase, async: true
  use Oban.Testing, repo: Librarian.Repo

  import Phoenix.LiveViewTest

  alias Librarian.{Discovery, Settings}
  alias Librarian.Discovery.CandidateSource
  alias Librarian.Repo

  setup :log_in_owner

  test "discover popup opens with explore form and pause toggle", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/foryou")

    refute has_element?(view, "#discover-popup")

    view |> element("#discover-open") |> render_click()

    assert has_element?(view, "#discover-popup")
    assert has_element?(view, "#explore-intent-form")
    assert has_element?(view, "#discovery-pause-toggle")
  end

  test "explore enqueues the intent worker", %{conn: conn} do
    {:ok, _} = Settings.save_settings(%{anthropic_api_key: "sk-test"})
    {:ok, view, _html} = live(conn, "/foryou")

    view |> element("#discover-open") |> render_click()
    view |> element("#explore-intent-form") |> render_submit(%{"query" => "  marine insurance "})

    assert_enqueued(
      worker: Librarian.Workers.ExploreIntentWorker,
      args: %{"query" => "marine insurance"}
    )
  end

  test "dismissing a pending candidate deletes it", %{conn: conn} do
    [candidate] =
      Discovery.register_intent_sources([%{"domain" => "example.org", "title" => "E"}], "area")

    {:ok, view, _html} = live(conn, "/foryou")
    view |> element("#discover-open") |> render_click()

    view |> element("#dismiss-candidate-#{candidate.id}") |> render_click()

    refute Repo.get(CandidateSource, candidate.id)
    refute has_element?(view, "#dismiss-candidate-#{candidate.id}")
  end

  test "saving an article stars it and marks it read", %{conn: conn} do
    {:ok, feed} = Librarian.Reader.create_feed(%{title: "F", feed_url: "https://f.example/rss"})

    article =
      Repo.insert!(%Librarian.Reader.Article{
        feed_id: feed.id,
        guid: "save-me",
        title: "Save me",
        fetched_at: DateTime.utc_now(:second)
      })

    {:ok, view, _html} = live(conn, "/foryou")
    render_hook(view, "feedback", %{"id" => to_string(article.id), "kind" => "save"})

    read_state = Librarian.Reader.get_article!(article.id).read_state
    assert read_state.starred
    assert read_state.read_at
  end

  test "pause toggle flips the setting", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/foryou")
    view |> element("#discover-open") |> render_click()

    refute Settings.discovery_paused?()
    view |> element("#discovery-pause-toggle") |> render_click()
    assert Settings.discovery_paused?()
  end
end
