defmodule Traitee.Onboard.Wizard do
  @moduledoc "Interactive onboarding wizard for first-time setup."

  alias IO.ANSI
  alias Traitee.Secrets.CredentialStore

  @providers %{
    "1" => {:openai, "OpenAI", "OPENAI_API_KEY"},
    "2" => {:anthropic, "Anthropic", "ANTHROPIC_API_KEY"},
    "3" => {:ollama, "Ollama (local)", nil}
  }

  @channels %{
    "1" => {:discord, "Discord", "DISCORD_BOT_TOKEN"},
    "2" => {:telegram, "Telegram", "TELEGRAM_BOT_TOKEN"},
    "3" => {:whatsapp, "WhatsApp", "WHATSAPP_TOKEN"},
    "4" => {:signal, "Signal", nil}
  }

  def run do
    welcome()
    |> step_llm_provider()
    |> step_embeddings()
    |> step_channels()
    |> step_workspace()
    |> step_cognitive_security()
    |> step_test_connection()
    |> step_daemon()
    |> summary()
  rescue
    _ ->
      puts("\n#{ANSI.yellow()}Setup interrupted. Run `mix traitee.onboard` to try again.#{ANSI.reset()}")
  end

  defp welcome do
    puts("""
    #{ANSI.cyan()}#{ANSI.bright()}
    ╔══════════════════════════════════════╗
    ║        Welcome to Traitee! 🤖       ║
    ╚══════════════════════════════════════╝
    #{ANSI.reset()}
    Traitee is a personal AI assistant that connects to your
    favorite messaging platforms with persistent memory.

    Let's get you set up.
    """)

    %{providers: [], channels: [], toml_entries: %{}}
  end

  defp step_llm_provider(state) do
    puts(heading("Step 1: LLM Provider"))
    puts("Which LLM provider do you want to use?\n")

    for {key, {_id, name, _}} <- Enum.sort(@providers) do
      puts("  #{key}) #{name}")
    end

    choice = prompt("\nYour choice [1]") |> normalize("1")
    {provider_id, provider_name, env_var} = Map.get(@providers, choice, Map.fetch!(@providers, "1"))

    entries =
      if env_var do
        api_key = prompt_secret("Enter your #{provider_name} API key")
        toml = Map.put(state.toml_entries, env_var, api_key)

        CredentialStore.store(provider_id, "api_key", api_key)
        app_key = String.to_atom("#{provider_id}_api_key")
        Application.put_env(:traitee, app_key, api_key)

        model =
          case provider_id do
            :openai -> "openai/gpt-4o"
            :anthropic -> "anthropic/claude-sonnet-4"
            _ -> "ollama/llama3"
          end

        Map.put(toml, :model, model)
      else
        Map.put(state.toml_entries, :model, "ollama/llama3")
      end

    puts("#{ANSI.green()}✓ #{provider_name} configured#{ANSI.reset()}\n")
    %{state | providers: [provider_id | state.providers], toml_entries: entries}
  end

  defp step_embeddings(state) do
    if :openai in state.providers do
      puts("#{ANSI.green()}✓ Embeddings: OpenAI text-embedding-3-small (already configured)#{ANSI.reset()}\n")
      state
    else
      puts(heading("Step 2: Embeddings (optional)"))
      puts("""
      Traitee uses vector embeddings for semantic memory search --
      finding relevant past conversations by meaning, not just keywords.

      Your LLM provider doesn't support embeddings, but OpenAI's
      text-embedding-3-small is fast and very cheap (~$0.02 per million tokens).
      """)

      if confirm?("Add an OpenAI API key for embeddings?") do
        api_key = prompt_secret("Enter your OpenAI API key")

        if api_key != "" do
          CredentialStore.store(:openai, "api_key", api_key)
          Application.put_env(:traitee, :openai_api_key, api_key)
          puts("#{ANSI.green()}✓ Embeddings enabled via OpenAI text-embedding-3-small#{ANSI.reset()}\n")
        else
          puts("#{ANSI.yellow()}Skipped. Keyword search will still work. Add later with:#{ANSI.reset()}")
          puts("  #{ANSI.cyan()}Traitee.Secrets.CredentialStore.store(:openai, \"api_key\", \"sk-...\")#{ANSI.reset()}\n")
        end
      else
        puts("#{ANSI.yellow()}Skipped. Keyword search will still work. Add later with:#{ANSI.reset()}")
        puts("  #{ANSI.cyan()}Traitee.Secrets.CredentialStore.store(:openai, \"api_key\", \"sk-...\")#{ANSI.reset()}\n")
      end

      state
    end
  end

  defp step_channels(state) do
    puts(heading("Step 3: Messaging Channels"))
    puts("Which channels do you want to enable? (comma-separated, or 'none')\n")

    for {key, {_id, name, _}} <- Enum.sort(@channels) do
      puts("  #{key}) #{name}")
    end

    puts("  0) None (CLI only)")

    input = prompt("\nYour choices [0]") |> normalize("0")

    if input == "0" do
      puts("#{ANSI.green()}✓ CLI-only mode#{ANSI.reset()}\n")
      state
    else
      choices = input |> String.split(~r/[\s,]+/) |> Enum.uniq()

      entries =
        Enum.reduce(choices, state.toml_entries, fn choice, acc ->
          case Map.get(@channels, choice) do
            {channel_id, name, env_var} when is_binary(env_var) ->
              token = prompt_secret("Enter #{name} token/key")
              CredentialStore.store(channel_id, "bot_token", token)
              app_key = String.to_atom("#{channel_id}_bot_token")
              Application.put_env(:traitee, app_key, token)
              Map.put(acc, env_var, token)

            {_id, name, nil} ->
              puts("#{ANSI.yellow()}#{name} requires manual config in config.toml#{ANSI.reset()}")
              acc

            nil ->
              acc
          end
        end)

      configured = choices |> Enum.map_join(", ", &elem(Map.get(@channels, &1, {:unknown, "?", nil}), 1))
      puts("#{ANSI.green()}✓ Channels configured: #{configured}#{ANSI.reset()}\n")

      puts("""
      #{ANSI.bright()}Owner ID#{ANSI.reset()}
      To restrict admin commands (/pairing, /doctor) to you only,
      enter your user ID from the channel you just configured.
      (In Telegram: message @userinfobot to get your numeric ID)
      """)

      owner_id = prompt("Your user ID (or leave blank to skip)") |> normalize("")

      entries =
        if owner_id != "" do
          puts("#{ANSI.green()}✓ Owner set to #{owner_id}#{ANSI.reset()}\n")
          Map.put(entries, :owner_id, owner_id)
        else
          puts("#{ANSI.yellow()}⚠  No owner ID set — anyone can run admin commands.#{ANSI.reset()}")
          puts("  Set it later in config.toml: [security] owner_id = \"your_id\"\n")
          entries
        end

      %{state | toml_entries: entries, channels: choices}
    end
  end

  defp step_workspace(state) do
    puts(heading("Step 4: Workspace"))
    Traitee.Workspace.ensure_workspace!()
    dir = Traitee.Workspace.workspace_dir()
    puts("#{ANSI.green()}✓ Workspace initialized at #{dir}#{ANSI.reset()}")

    puts("  Running database migrations...")
    run_migrations()
    puts("#{ANSI.green()}✓ Database ready#{ANSI.reset()}\n")

    write_config(state)
    state
  end

  defp step_cognitive_security(state) do
    puts(heading("Step 5: Cognitive Security"))
    puts("""
    Traitee includes an LLM-as-judge system that screens every incoming
    message for prompt injection, manipulation, and jailbreak attempts --
    in any language, encoding, or phrasing.

    This uses xAI's Grok (fast, non-reasoning) as a security classifier.
    Cost is negligible (~$0.0001 per message).
    """)

    if confirm?("Enable the LLM security judge?") do
      api_key = prompt_secret("Enter your xAI API key (from console.x.ai)")

      if api_key != "" do
        CredentialStore.store(:xai, "api_key", api_key)
        Application.put_env(:traitee, :xai_api_key, api_key)
        puts("#{ANSI.green()}✓ Cognitive security judge enabled with Grok#{ANSI.reset()}\n")
      else
        puts(safety_warning())
      end
    else
      puts(safety_warning())
    end

    state
  end

  defp safety_warning do
    """
    #{ANSI.yellow()}#{ANSI.bright()}⚠  Security judge skipped#{ANSI.reset()}
    #{ANSI.yellow()}Without the LLM judge, Traitee relies only on regex pattern matching
    for prompt injection detection. This means attacks using other languages,
    base64 encoding, paraphrasing, or novel techniques will NOT be caught
    at the input layer.

    Your assistant will still have:
      - Regex-based sanitization (English patterns only)
      - Persistent system reminders
      - Canary token leak detection
      - Output guard checks

    To enable the judge later, run:
      #{ANSI.cyan()}mix traitee.onboard#{ANSI.reset()}#{ANSI.yellow()}
    or set your xAI key manually:
      #{ANSI.cyan()}Traitee.Secrets.CredentialStore.store(:xai, "api_key", "xai-...")#{ANSI.reset()}
    """
  end

  defp step_test_connection(state) do
    puts(heading("Step 6: Connection Test"))

    if confirm?("Send a test message to the LLM?") do
      puts("Sending test message...")

      case Traitee.LLM.Router.complete(%{
             messages: [%{role: "user", content: "Say hello in one sentence."}]
           }) do
        {:ok, resp} ->
          puts("#{ANSI.green()}✓ LLM responded: #{resp.content}#{ANSI.reset()}\n")

        {:error, reason} ->
          puts("#{ANSI.red()}✗ Connection failed: #{inspect(reason)}#{ANSI.reset()}")
          puts("  You can fix this later in ~/.traitee/config.toml\n")
      end
    end

    state
  end

  defp step_daemon(state) do
    puts(heading("Step 7: Background Service"))
    platform = Traitee.Daemon.Service.platform()
    platform_name = platform |> to_string() |> String.capitalize()

    if confirm?("Install Traitee as a #{platform_name} background service?") do
      case Traitee.Daemon.Service.install() do
        :ok ->
          puts("#{ANSI.green()}✓ Service installed. Use `mix traitee.daemon start` to run.#{ANSI.reset()}\n")

        {:error, reason} ->
          puts("#{ANSI.red()}✗ Failed: #{inspect(reason)}#{ANSI.reset()}")
          puts("  You can install manually later with `mix traitee.daemon install`\n")
      end
    end

    state
  end

  defp summary(state) do
    puts(heading("Setup Complete!"))

    puts("""
    #{ANSI.bright()}What's next:#{ANSI.reset()}

      #{ANSI.cyan()}mix traitee.chat#{ANSI.reset()}       - Start a CLI chat session
      #{ANSI.cyan()}mix traitee.serve#{ANSI.reset()}      - Start the gateway server
      #{ANSI.cyan()}mix traitee.daemon start#{ANSI.reset()} - Run as background service

    Config file: #{Traitee.config_path()}
    Workspace:   #{Traitee.Workspace.workspace_dir()}
    """)

    state
  end

  # -- Helpers --

  defp write_config(state) do
    path = Traitee.config_path()
    File.mkdir_p!(Path.dirname(path))

    model = state.toml_entries[:model] || "openai/gpt-4o"

    channel_sections =
      state.channels
      |> Enum.map(&Map.get(@channels, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {channel_id, _name, env_var} ->
        token_line =
          if env_var do
            ~s(# Token loaded from credential store. To use env var instead:\n# token = "env:#{env_var}")
          else
            ~s(# Configure manually below)
          end

        "[channels.#{channel_id}]\nenabled = true\n#{token_line}"
      end)
      |> Enum.join("\n\n")

    owner_section =
      case state.toml_entries[:owner_id] do
        nil -> ""
        "" -> ""
        id -> "\n[security]\nenabled = true\nowner_id = \"#{id}\"\n"
      end

    content =
      "[agent]\nmodel = \"#{model}\"\n" <>
        if(channel_sections != "", do: "\n" <> channel_sections <> "\n", else: "\n") <>
        owner_section

    if File.exists?(path) do
      existing = File.read!(path)

      unless String.contains?(existing, "[channels.") do
        File.write!(path, String.trim_trailing(existing) <> "\n\n" <> channel_sections <> "\n")
      end
    else
      File.write!(path, content)
    end
  end

  defp heading(text) do
    "\n#{ANSI.bright()}#{ANSI.cyan()}── #{text} ──#{ANSI.reset()}\n"
  end

  defp prompt(label) do
    IO.gets("#{label}: ") |> to_string() |> String.trim()
  end

  defp prompt_secret(label) do
    IO.gets("#{label}: ") |> to_string() |> String.trim()
  end

  defp confirm?(question) do
    answer = prompt("#{question} [Y/n]") |> normalize("y")
    answer in ["y", "yes", ""]
  end

  defp normalize(input, default) when input in ["", nil], do: default
  defp normalize(input, _default), do: String.downcase(String.trim(input))

  defp run_migrations do
    migrations_path = Path.join(:code.priv_dir(:traitee), "repo/migrations")
    Ecto.Migrator.run(Traitee.Repo, migrations_path, :up, all: true)
  end

  defp puts(text), do: IO.puts(text)
end
