defmodule Traitee.LLM.OAuth.PKCE do
  @moduledoc """
  OAuth PKCE flow for Claude subscription authentication.

  Opens a browser to claude.ai/oauth/authorize, listens for the callback
  on a temporary local HTTP server, exchanges the authorization code for
  OAuth credentials, and returns the token set.
  """

  require Logger

  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @authorize_url "https://claude.ai/oauth/authorize"
  @token_url "https://platform.claude.com/v1/oauth/token"
  @scopes "org:create_api_key user:profile user:inference user:sessions:claude_code"

  @doc """
  Runs the full PKCE login flow:
  1. Generates PKCE verifier + challenge
  2. Starts a temporary local HTTP server for the callback
  3. Opens the browser to the authorize URL
  4. Waits for the callback with code + state
  5. Exchanges code for tokens
  6. Returns `{:ok, %{access_token, refresh_token, expires_in}}` or `{:error, reason}`
  """
  def run_login_flow do
    verifier = generate_verifier()
    challenge = generate_challenge(verifier)
    state = generate_state()

    {:ok, {server_ref, port}} = start_callback_server(state)

    redirect_uri = "http://localhost:#{port}/callback"
    url = build_authorize_url(redirect_uri, state, challenge)

    Logger.info("[oauth] Opening browser for Claude authentication...")
    open_browser(url)

    IO.puts("  Waiting for authorization (browser should open)...")
    IO.puts("  URL: #{url}")

    result =
      receive do
        {:oauth_callback, ^state, code} ->
          stop_callback_server(server_ref)
          exchange_code(code, verifier, redirect_uri, state)

        {:oauth_callback_error, reason} ->
          stop_callback_server(server_ref)
          {:error, reason}
      after
        300_000 ->
          stop_callback_server(server_ref)
          {:error, :timeout}
      end

    result
  end

  # -- PKCE Crypto --

  def generate_verifier do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  def generate_challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp generate_state do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # -- URL Building --

  defp build_authorize_url(redirect_uri, state, challenge) do
    # Build query string manually to avoid over-encoding colons in scopes.
    # JavaScript's URLSearchParams encodes minimally; Elixir's URI.encode_query
    # encodes colons as %3A which claude.ai rejects.
    params = [
      {"code", "true"},
      {"client_id", @client_id},
      {"response_type", "code"},
      {"redirect_uri", redirect_uri},
      {"scope", @scopes},
      {"code_challenge", challenge},
      {"code_challenge_method", "S256"},
      {"state", state}
    ]

    query =
      Enum.map_join(params, "&", fn {k, v} ->
        "#{k}=#{URI.encode(v, &uri_unreserved?/1)}"
      end)

    "#{@authorize_url}?#{query}"
  end

  # Match JavaScript URLSearchParams encoding: don't encode : @ ! $ ' ( ) * , ;
  defp uri_unreserved?(c) do
    URI.char_unreserved?(c) or c in ~c[:@!$'()*,;]
  end

  # -- Token Exchange --

  defp exchange_code(code, verifier, redirect_uri, state) do
    body =
      Jason.encode!(%{
        code: code,
        state: state,
        grant_type: "authorization_code",
        client_id: @client_id,
        redirect_uri: redirect_uri,
        code_verifier: verifier
      })

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "axios/1.13.6"}
    ]

    case Req.post(@token_url, body: body, headers: headers, receive_timeout: 15_000, retry: false) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, resp}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:exchange_failed, status, resp}}

      {:error, reason} ->
        {:error, {:exchange_request_failed, reason}}
    end
  end

  # -- Callback Server --

  defp start_callback_server(expected_state) do
    parent = self()

    {:ok, server_ref} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(server_ref)

    spawn_link(fn -> accept_loop(server_ref, parent, expected_state) end)

    {:ok, {server_ref, port}}
  end

  defp accept_loop(server_ref, parent, expected_state) do
    case :gen_tcp.accept(server_ref, 300_000) do
      {:ok, client} ->
        {:ok, data} = :gen_tcp.recv(client, 0, 10_000)
        handle_http_request(data, client, parent, expected_state)

      {:error, :timeout} ->
        send(parent, {:oauth_callback_error, :timeout})

      {:error, reason} ->
        send(parent, {:oauth_callback_error, reason})
    end
  end

  defp handle_http_request(data, client, parent, expected_state) do
    request_line = data |> String.split("\r\n") |> hd()

    case Regex.run(~r"GET /callback\?(.+) HTTP", request_line) do
      [_, query_string] ->
        params = URI.decode_query(query_string)
        code = params["code"]
        state = params["state"]

        if state == expected_state && code do
          send_http_response(client, 200, success_html())
          send(parent, {:oauth_callback, state, code})
        else
          send_http_response(client, 400, "Invalid state or missing code")
          send(parent, {:oauth_callback_error, :invalid_state})
        end

      _ ->
        send_http_response(client, 404, "Not found")
        accept_loop(:gen_tcp.listen(0, []) |> elem(1), parent, expected_state)
    end
  end

  defp send_http_response(client, status, body) do
    status_text = if status == 200, do: "OK", else: "Error"

    response =
      "HTTP/1.1 #{status} #{status_text}\r\n" <>
        "Content-Type: text/html\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n" <>
        "\r\n" <>
        body

    :gen_tcp.send(client, response)
    :gen_tcp.close(client)
  end

  defp stop_callback_server(server_ref) do
    :gen_tcp.close(server_ref)
  catch
    _, _ -> :ok
  end

  defp success_html do
    """
    <!DOCTYPE html>
    <html>
    <head><title>Traitee - Authorization Complete</title></head>
    <body style="font-family: system-ui; text-align: center; padding: 60px;">
    <h1>Authorization complete</h1>
    <p>You can close this tab and return to Traitee.</p>
    </body>
    </html>
    """
  end

  # -- Browser --

  defp open_browser(url) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [url])
      {:unix, _} -> System.cmd("xdg-open", [url])
      {:win32, _} -> System.cmd("cmd", ["/c", "start", url])
    end
  rescue
    _ -> Logger.warning("[oauth] Could not open browser automatically")
  end
end
