defmodule Traitee.LLM.OAuth.PKCE do
  @moduledoc """
  OAuth PKCE flow for Claude subscription authentication.

  Opens a browser to claude.ai/oauth/authorize. The user authorizes, gets
  redirected to platform.claude.com which displays the code. User pastes
  the code back into the terminal. We exchange it with our PKCE verifier.
  """

  require Logger

  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @authorize_url "https://claude.ai/oauth/authorize"
  @redirect_uri "https://platform.claude.com/oauth/code/callback"
  @token_url "https://platform.claude.com/v1/oauth/token"
  @scope "user:inference"

  @doc """
  Runs the PKCE login flow:
  1. Generates PKCE verifier + challenge
  2. Opens browser to authorize URL
  3. User authorizes and gets a code displayed on screen
  4. User pastes the code back
  5. Exchanges code for tokens with our verifier
  6. Returns `{:ok, token_map}` or `{:error, reason}`
  """
  def run_login_flow do
    verifier = generate_verifier()
    challenge = generate_challenge(verifier)
    state = generate_state()

    url = build_authorize_url(state, challenge)

    Logger.info("[oauth] Opening browser for Claude authentication...")
    open_browser(url)

    IO.puts("  Browser should open. Authorize, then paste the code shown on screen.")
    IO.puts("  (If browser didn't open, visit this URL manually:)")
    IO.puts("  #{url}\n")

    raw = IO.gets("  Paste code here: ") |> to_string() |> String.trim()

    if raw == "" do
      {:error, :no_code_provided}
    else
      {code, callback_state} = parse_callback(raw)

      if callback_state && callback_state != state do
        {:error, :state_mismatch}
      else
        exchange_code(code, verifier, callback_state || state)
      end
    end
  end

  # -- PKCE Crypto --

  def generate_verifier do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  def generate_challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp generate_state do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # -- URL Building --

  defp build_authorize_url(state, challenge) do
    params =
      URI.encode_query(%{
        "code" => "true",
        "client_id" => @client_id,
        "response_type" => "code",
        "redirect_uri" => @redirect_uri,
        "scope" => @scope,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state
      })

    "#{@authorize_url}?#{params}"
  end

  # -- Parsing callback input --

  defp parse_callback(input) do
    trimmed = String.trim(input)

    # Try URL format: https://...?code=...&state=...
    case URI.parse(trimmed) do
      %URI{query: query} when is_binary(query) ->
        params = URI.decode_query(query)

        if params["code"] && params["state"] do
          {params["code"], params["state"]}
        else
          parse_hash_format(trimmed)
        end

      _ ->
        parse_hash_format(trimmed)
    end
  end

  # code#state format
  defp parse_hash_format(input) do
    case String.split(input, "#", parts: 2) do
      [code, state] when code != "" and state != "" -> {code, state}
      _ -> {input, nil}
    end
  end

  # -- Token Exchange --

  defp exchange_code(code, verifier, state) do
    body = %{
      code: code,
      state: state,
      grant_type: "authorization_code",
      client_id: @client_id,
      redirect_uri: @redirect_uri,
      code_verifier: verifier
    }

    case Req.post(@token_url,
           json: body,
           headers: [
             {"accept", "application/json, text/plain, */*"},
             {"user-agent", "axios/1.13.6"}
           ],
           receive_timeout: 15_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, resp}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:exchange_failed, status, resp}}

      {:error, reason} ->
        {:error, {:exchange_request_failed, reason}}
    end
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
