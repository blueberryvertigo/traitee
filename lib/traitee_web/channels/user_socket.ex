defmodule TraiteeWeb.UserSocket do
  use Phoenix.Socket

  channel "chat:*", TraiteeWeb.ChatChannel

  # When web.api_token is configured the socket requires a matching token
  # param; when unconfigured the webchat stays open (inbound messages still
  # go through the Router pairing policy).
  @impl true
  def connect(params, socket, _connect_info) do
    configured = Traitee.Config.get([:web, :api_token])
    token = params["token"]

    cond do
      is_nil(configured) or configured == "" ->
        {:ok, assign(socket, :client_sender_id, params["sender_id"])}

      is_binary(token) and Plug.Crypto.secure_compare(token, configured) ->
        {:ok, assign(socket, :client_sender_id, params["sender_id"])}

      true ->
        :error
    end
  end

  @impl true
  def id(_socket), do: nil
end
