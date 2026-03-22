defmodule TraiteeWeb.WebhookController do
  use Phoenix.Controller, formats: [:json]

  def handle(conn, %{"channel" => channel} = params) do
    case channel do
      "whatsapp" -> handle_whatsapp(conn, params)
      _ -> conn |> put_status(404) |> json(%{error: "unknown channel"})
    end
  end

  defp handle_whatsapp(conn, params) do
    Traitee.Channels.WhatsApp.handle_webhook(params)
    conn |> put_status(200) |> json(%{status: "ok"})
  end
end
