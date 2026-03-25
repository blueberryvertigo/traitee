defmodule Traitee.LLM.OAuth.TokenManager do
  @moduledoc """
  GenServer managing Claude subscription OAuth token lifecycle.

  On first use (or when unconfigured), runs a PKCE OAuth flow via browser
  to obtain access_token + refresh_token. Proactively refreshes before expiry.
  """

  use GenServer

  require Logger

  alias Traitee.LLM.OAuth.PKCE
  alias Traitee.Secrets.CredentialStore

  @provider :claude_subscription
  @refresh_margin_ms 30 * 60 * 1_000
  @retry_delay_ms 60 * 1_000
  @token_url "https://platform.claude.com/v1/oauth/token"
  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @max_refresh_retries 2

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current access token, running PKCE login if needed."
  def get_access_token do
    GenServer.call(__MODULE__, :get_access_token, 600_000)
  end

  @doc "Runs the PKCE login flow and stores the resulting tokens."
  def login do
    GenServer.call(__MODULE__, :login, 600_000)
  end

  @doc "Stores already-exchanged tokens directly."
  def store_tokens(token_map) do
    GenServer.call(__MODULE__, {:store_tokens, token_map})
  end

  @doc "Forces an immediate token refresh."
  def refresh do
    GenServer.call(__MODULE__, :refresh, 30_000)
  end

  @doc "Returns true if a valid access token is available."
  def authenticated? do
    GenServer.call(__MODULE__, :authenticated?)
  end

  @doc "Clears all stored tokens."
  def logout do
    GenServer.call(__MODULE__, :logout)
  end

  @doc "Returns `{status, expires_at}` for diagnostics."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    state = load_persisted_tokens()
    {:ok, maybe_schedule_refresh(state)}
  end

  @impl true
  def handle_call(:get_access_token, _from, %{status: :ready} = state) do
    {:reply, {:ok, state.access_token}, state}
  end

  def handle_call(:get_access_token, _from, %{status: :refreshing} = state) do
    {:reply, {:ok, state.access_token}, state}
  end

  def handle_call(:get_access_token, _from, state) do
    {:reply, {:error, :not_authenticated}, state}
  end

  @impl true
  def handle_call(:login, _from, state) do
    case PKCE.run_login_flow() do
      {:ok, token_resp} ->
        new_state = persist_and_update(token_resp, state)
        Logger.info("[claude_subscription] OAuth login successful")
        {:reply, :ok, maybe_schedule_refresh(new_state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:store_tokens, token_map}, _from, state) do
    new_state = persist_and_update(token_map, state)
    {:reply, :ok, maybe_schedule_refresh(new_state)}
  end

  def handle_call(:refresh, _from, state) do
    case do_refresh(state) do
      {:ok, new_state} -> {:reply, :ok, maybe_schedule_refresh(new_state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:authenticated?, _from, state) do
    {:reply, state.status in [:ready, :refreshing], state}
  end

  def handle_call(:logout, _from, state) do
    cancel_timer(state)
    CredentialStore.delete(@provider, "access_token")
    CredentialStore.delete(@provider, "refresh_token")
    CredentialStore.delete(@provider, "expires_at")

    {:reply, :ok, blank_state()}
  end

  def handle_call(:status, _from, state) do
    {:reply, {state.status, state.expires_at}, state}
  end

  @impl true
  def handle_info(:proactive_refresh, state) do
    case do_refresh(state) do
      {:ok, new_state} ->
        Logger.info("[claude_subscription] Token refreshed successfully")
        {:noreply, maybe_schedule_refresh(%{new_state | retry_count: 0})}

      {:error, reason} ->
        retry_count = state.retry_count + 1

        Logger.warning(
          "[claude_subscription] Token refresh failed (attempt #{retry_count}): #{inspect(reason)}"
        )

        if retry_count < @max_refresh_retries do
          timer = Process.send_after(self(), :proactive_refresh, @retry_delay_ms)

          {:noreply,
           %{state | refresh_timer: timer, retry_count: retry_count, status: :refreshing}}
        else
          Logger.error(
            "[claude_subscription] Token expired after #{retry_count} refresh attempts. Run `mix traitee.oauth` to re-authenticate."
          )

          {:noreply, %{state | status: :expired, refresh_timer: nil, retry_count: 0}}
        end
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private: Refresh --

  defp do_refresh(%{refresh_token: nil}), do: {:error, :no_refresh_token}

  defp do_refresh(%{refresh_token: refresh_token} = state) do
    body =
      Jason.encode!(%{
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: @client_id
      })

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    case Req.post(@token_url, body: body, headers: headers, receive_timeout: 15_000, retry: false) do
      {:ok, %{status: 200, body: resp}} ->
        new_state = persist_and_update(resp, state)
        {:ok, new_state}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:refresh_failed, status, resp}}

      {:error, reason} ->
        {:error, {:refresh_request_failed, reason}}
    end
  end

  # -- Private: Persistence --

  defp blank_state do
    %{
      access_token: nil,
      refresh_token: nil,
      expires_at: nil,
      status: :unconfigured,
      refresh_timer: nil,
      retry_count: 0
    }
  end

  defp load_persisted_tokens do
    case CredentialStore.load(@provider, "access_token") do
      {:ok, access_token} ->
        refresh_token =
          case CredentialStore.load(@provider, "refresh_token") do
            {:ok, rt} -> rt
            :not_found -> nil
          end

        expires_at = load_expires_at()

        %{
          access_token: access_token,
          refresh_token: refresh_token,
          expires_at: expires_at,
          status: :ready,
          refresh_timer: nil,
          retry_count: 0
        }

      :not_found ->
        blank_state()
    end
  end

  defp load_expires_at do
    case CredentialStore.load(@provider, "expires_at") do
      {:ok, ts} -> parse_datetime(ts)
      :not_found -> nil
    end
  end

  defp persist_and_update(token_map, state) do
    cancel_timer(state)

    access_token = token_map["access_token"] || token_map[:access_token]
    refresh_token = token_map["refresh_token"] || token_map[:refresh_token]

    expires_at =
      cond do
        ts = token_map["expires_at"] || token_map[:expires_at] ->
          parse_datetime(ts)

        ei = token_map["expires_in"] || token_map[:expires_in] ->
          DateTime.add(DateTime.utc_now(), ei, :second)

        true ->
          DateTime.add(DateTime.utc_now(), 8 * 3600, :second)
      end

    CredentialStore.store(@provider, "access_token", access_token)

    if refresh_token do
      CredentialStore.store(@provider, "refresh_token", refresh_token)
    end

    CredentialStore.store(@provider, "expires_at", DateTime.to_iso8601(expires_at))

    %{
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at: expires_at,
      status: :ready,
      refresh_timer: nil,
      retry_count: 0
    }
  end

  # -- Private: Scheduling --

  defp maybe_schedule_refresh(%{expires_at: nil} = state), do: state
  defp maybe_schedule_refresh(%{refresh_token: nil} = state), do: state

  defp maybe_schedule_refresh(state) do
    cancel_timer(state)
    now = DateTime.utc_now()
    ms_until_expiry = DateTime.diff(state.expires_at, now, :millisecond)
    refresh_in = max(ms_until_expiry - @refresh_margin_ms, 1_000)

    timer = Process.send_after(self(), :proactive_refresh, refresh_in)
    %{state | refresh_timer: timer}
  end

  defp cancel_timer(%{refresh_timer: nil}), do: :ok
  defp cancel_timer(%{refresh_timer: ref}), do: Process.cancel_timer(ref)

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(seconds) when is_integer(seconds) do
    DateTime.add(DateTime.utc_now(), seconds, :second)
  end

  defp parse_datetime(_), do: nil
end
