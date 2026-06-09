defmodule TraiteeWeb.WebhookController do
  use Phoenix.Controller, formats: [:json]

  def handle(conn, %{"channel" => channel} = params) do
    case channel do
      "whatsapp" -> handle_whatsapp(conn, params)
      _ -> conn |> put_status(404) |> json(%{error: "unknown channel"})
    end
  end

  @doc """
  Meta webhook verification handshake (GET): echoes hub.challenge when
  hub.verify_token matches the configured WhatsApp verify token.
  """
  def verify(conn, %{"channel" => "whatsapp"} = params) do
    config = Traitee.Config.get([:channels, :whatsapp]) || %{}
    expected = config[:verify_token]

    if params["hub.mode"] == "subscribe" and is_binary(expected) and expected != "" and
         params["hub.verify_token"] == expected do
      text(conn, params["hub.challenge"] || "")
    else
      conn |> put_status(403) |> json(%{error: "verification failed"})
    end
  end

  def verify(conn, _params) do
    conn |> put_status(404) |> json(%{error: "unknown channel"})
  end

  defp handle_whatsapp(conn, params) do
    Traitee.Channels.WhatsApp.handle_webhook(params)
    conn |> put_status(200) |> json(%{status: "ok"})
  end
end
