defmodule Traitee.Channels.Supervisor do
  @moduledoc """
  Supervises all channel GenServers (Discord, Telegram, WhatsApp, Signal).
  Only starts channels that are configured and enabled.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = build_children()
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children do
    []
    |> maybe_add_discord()
    |> maybe_add_telegram()
    |> maybe_add_whatsapp()
    |> maybe_add_signal()
  end

  defp maybe_add_discord(children) do
    config = Traitee.Config.get([:channels, :discord])

    if config[:enabled] do
      [Traitee.Channels.Discord | children]
    else
      children
    end
  end

  defp maybe_add_telegram(children) do
    config = Traitee.Config.get([:channels, :telegram])

    if config[:enabled] do
      [Traitee.Channels.Telegram | children]
    else
      children
    end
  end

  defp maybe_add_whatsapp(children) do
    config = Traitee.Config.get([:channels, :whatsapp])

    if config[:enabled] do
      [Traitee.Channels.WhatsApp | children]
    else
      children
    end
  end

  defp maybe_add_signal(children) do
    config = Traitee.Config.get([:channels, :signal])

    if config[:enabled] do
      [Traitee.Channels.Signal | children]
    else
      children
    end
  end
end
