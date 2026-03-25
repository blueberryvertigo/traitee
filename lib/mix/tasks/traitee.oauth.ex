defmodule Mix.Tasks.Traitee.Oauth do
  @moduledoc """
  Manage Claude subscription authentication.

      mix traitee.oauth            # Log in via browser (OAuth PKCE)
      mix traitee.oauth --status   # Show token status and expiry
      mix traitee.oauth --logout   # Clear stored tokens
  """

  use Mix.Task

  alias IO.ANSI
  alias Traitee.LLM.OAuth.TokenManager

  @shortdoc "Link a Claude Pro/Max subscription via OAuth"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["--status"] -> show_status()
      ["--logout"] -> logout()
      _ -> login()
    end
  end

  defp login do
    IO.puts("""

      #{ANSI.bright()}Claude Subscription Login#{ANSI.reset()}

      #{ANSI.faint()}Opening your browser to sign in with your Claude account...#{ANSI.reset()}
    """)

    case TokenManager.login() do
      :ok ->
        IO.puts("""

          #{ANSI.green()}#{ANSI.bright()}Authenticated!#{ANSI.reset()}

          Add this to your config (#{Traitee.config_path()}):

            #{ANSI.cyan()}[agent]
            model = "sub/claude-sonnet-4"#{ANSI.reset()}

          Available models: claude-sonnet-4, claude-opus-4, claude-opus-4.6, claude-haiku-3.5
        """)

      {:error, reason} ->
        IO.puts("#{ANSI.red()}Login failed: #{inspect(reason)}#{ANSI.reset()}")
    end
  end

  defp show_status do
    case TokenManager.status() do
      {:ready, expires_at} ->
        remaining = DateTime.diff(expires_at, DateTime.utc_now(), :minute)

        IO.puts("""

          #{ANSI.green()}Status: ready#{ANSI.reset()}
          Expires: #{DateTime.to_iso8601(expires_at)} (#{remaining} min remaining)
        """)

      {:refreshing, expires_at} ->
        IO.puts("""

          #{ANSI.yellow()}Status: refreshing#{ANSI.reset()}
          Expires: #{if expires_at, do: DateTime.to_iso8601(expires_at), else: "unknown"}
        """)

      {:expired, _} ->
        IO.puts("""

          #{ANSI.red()}Status: expired#{ANSI.reset()}
          Run #{ANSI.cyan()}mix traitee.oauth#{ANSI.reset()} to re-authenticate.
        """)

      {:unconfigured, _} ->
        IO.puts("""

          #{ANSI.faint()}Status: not configured#{ANSI.reset()}
          Run #{ANSI.cyan()}mix traitee.oauth#{ANSI.reset()} to set up.
        """)
    end
  end

  defp logout do
    TokenManager.logout()
    IO.puts("#{ANSI.green()}Subscription tokens cleared.#{ANSI.reset()}")
  end
end
