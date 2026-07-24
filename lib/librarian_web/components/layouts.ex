defmodule LibrarianWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use LibrarianWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://hexdocs.pm/phoenix/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @nav_items [
    {:for_you, "For You", "/foryou"},
    {:reader, "Reader", "/reader"},
    {:vault, "Vault", "/vault"},
    {:dashboard, "Dashboard", "/dashboard"}
  ]

  @doc """
  The app-wide section switcher. `compact` fits the narrow reader/vault
  sidebars; the default matches the For You / Dashboard top bars.
  """
  attr :active, :atom, required: true, values: [:for_you, :reader, :vault, :dashboard]
  attr :compact, :boolean, default: false
  attr :class, :string, default: nil

  def nav_pills(assigns) do
    assigns = assign(assigns, :items, @nav_items)

    ~H"""
    <nav class={[
      "flex items-center gap-1 rounded-full bg-base-200",
      if(@compact, do: "p-0.5", else: "p-1"),
      @class
    ]}>
      <%= for {key, label, path} <- @items do %>
        <span
          :if={@active == key}
          class={[
            "rounded-full bg-base-100 shadow-sm font-semibold whitespace-nowrap",
            pill_size(@compact)
          ]}
        >
          {label}
        </span>
        <.link
          :if={@active != key}
          navigate={path}
          class={[
            "rounded-full text-base-content/60 hover:text-base-content hover:bg-base-100/60 transition whitespace-nowrap",
            pill_size(@compact)
          ]}
        >
          {label}
        </.link>
      <% end %>
    </nav>
    """
  end

  defp pill_size(true), do: "px-2 py-1 text-[11px]"
  defp pill_size(false), do: "px-3 py-1 text-xs"

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def reader(assigns) do
    ~H"""
    <div class="h-dvh flex flex-col bg-base-100 overflow-hidden">
      <.flash_group flash={@flash} />
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def vault(assigns) do
    ~H"""
    <div class="h-dvh flex flex-col bg-base-100 overflow-hidden">
      <.flash_group flash={@flash} />
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="min-h-dvh flex items-center justify-center bg-base-200 px-4">
      <.flash_group flash={@flash} />
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
