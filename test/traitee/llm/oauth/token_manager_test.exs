defmodule Traitee.LLM.OAuth.TokenManagerTest do
  use Traitee.DataCase, async: false

  alias Traitee.LLM.OAuth.TokenManager
  alias Traitee.Secrets.CredentialStore

  setup do
    # Clean up any existing tokens before each test
    CredentialStore.delete(:claude_subscription, "access_token")
    CredentialStore.delete(:claude_subscription, "refresh_token")
    CredentialStore.delete(:claude_subscription, "expires_at")
    :ok
  end

  describe "status/0" do
    test "reports unconfigured when no tokens stored" do
      assert {status, _} = TokenManager.status()
      assert status in [:unconfigured, :ready]
    end
  end

  describe "store_tokens/1 and get_access_token/0" do
    test "stores and retrieves tokens" do
      expires = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      :ok =
        TokenManager.store_tokens(%{
          "access_token" => "test-access-token",
          "refresh_token" => "test-refresh-token",
          "expires_at" => expires
        })

      assert {:ok, "test-access-token"} = TokenManager.get_access_token()
      assert TokenManager.authenticated?()
      assert {:ready, _} = TokenManager.status()
    end

    test "persists tokens to credential store" do
      :ok =
        TokenManager.store_tokens(%{
          "access_token" => "persisted-token",
          "refresh_token" => "persisted-refresh"
        })

      assert {:ok, "persisted-token"} = CredentialStore.load(:claude_subscription, "access_token")

      assert {:ok, "persisted-refresh"} =
               CredentialStore.load(:claude_subscription, "refresh_token")
    end

    test "handles expires_in as integer seconds" do
      :ok =
        TokenManager.store_tokens(%{
          "access_token" => "exp-token",
          "expires_in" => 7200
        })

      {:ready, expires_at} = TokenManager.status()
      assert expires_at != nil
      remaining = DateTime.diff(expires_at, DateTime.utc_now(), :second)
      assert remaining > 7000 and remaining <= 7200
    end

    test "defaults to 8h expiry when no expiry info" do
      :ok = TokenManager.store_tokens(%{"access_token" => "no-exp-token"})

      {:ready, expires_at} = TokenManager.status()
      assert expires_at != nil
      remaining = DateTime.diff(expires_at, DateTime.utc_now(), :second)
      assert remaining > 28_000
    end
  end

  describe "logout/0" do
    test "clears tokens" do
      :ok =
        TokenManager.store_tokens(%{
          "access_token" => "to-clear",
          "refresh_token" => "to-clear-refresh"
        })

      assert TokenManager.authenticated?()

      :ok = TokenManager.logout()
      refute TokenManager.authenticated?()
      assert {:error, :not_authenticated} = TokenManager.get_access_token()
    end

    test "clears credential store" do
      :ok = TokenManager.store_tokens(%{"access_token" => "to-wipe"})
      :ok = TokenManager.logout()

      assert :not_found = CredentialStore.load(:claude_subscription, "access_token")
    end
  end

  describe "authenticated?/0" do
    test "returns false when unconfigured" do
      TokenManager.logout()
      refute TokenManager.authenticated?()
    end
  end
end
