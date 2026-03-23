defmodule Traitee.Onboard.Wizard do
  @moduledoc "Interactive onboarding wizard for first-time setup."

  alias IO.ANSI
  alias Traitee.CLI.Display
  alias Traitee.Daemon.Service
  alias Traitee.Secrets.CredentialStore

  @providers %{
    "1" => {:openai, "OpenAI", "OPENAI_API_KEY"},
    "2" => {:anthropic, "Anthropic", "ANTHROPIC_API_KEY"},
    "3" => {:ollama, "Ollama (local)", nil}
  }

  @default_models %{
    openai: "openai/gpt-5.4",
    anthropic: "anthropic/claude-opus-4.6",
    ollama: "ollama/llama3"
  }

  @fallback_models %{
    openai: "anthropic/claude-opus-4.6",
    anthropic: "openai/gpt-5.4",
    ollama: nil
  }

  @channels %{
    "1" => {:discord, "Discord"},
    "2" => {:telegram, "Telegram"},
    "3" => {:whatsapp, "WhatsApp"},
    "4" => {:signal, "Signal"}
  }

  @channel_owner_hints %{
    discord:
      "Discord user ID (right-click your name → Copy User ID, enable Developer Mode in settings)",
    telegram: "Telegram numeric ID (message @userinfobot to get it)",
    whatsapp: "phone number in E.164 format (e.g. +15551234567)",
    signal: "phone number in E.164 format (e.g. +15551234567)"
  }

  @total_steps 12

  @step_vibes %{
    "LLM Provider" => "Time to give your AI a brain.",
    "Embeddings" => "Because keyword search is so 2015.",
    "Agent Identity" => "Every hero needs an origin story.",
    "Messaging Channels" => "Pick your AI's social life.",
    "Owner Identity" => "Establishing dominance (consensually).",
    "Cognitive Security" => "Teaching your AI to spot gaslighting.",
    "Tools" => "With great power tools comes great config.",
    "Filesystem Security" => "How paranoid do you want to be? (Very.)",
    "Gateway" => "The front door to your digital kingdom.",
    "Workspace & Database" => "A cozy home for your AI's memories.",
    "Connection Test" => "The moment of truth. No pressure.",
    "Background Service" => "Making it run forever. Like a Spotify playlist."
  }

  def run do
    wipe_previous()

    welcome()
    |> step_llm_provider()
    |> step_embeddings()
    |> step_agent_identity()
    |> step_channels()
    |> step_owner_identity()
    |> step_cognitive_security()
    |> step_tools()
    |> step_filesystem_security()
    |> step_gateway()
    |> step_workspace()
    |> step_test_connection()
    |> step_daemon()
    |> summary()
  rescue
    _ ->
      puts(
        "\n#{ANSI.yellow()}Setup interrupted — no worries! " <>
          "Run #{ANSI.cyan()}mix traitee.onboard#{ANSI.yellow()} whenever you're ready.#{ANSI.reset()}"
      )
  end

  # -- Wipe --

  defp wipe_previous do
    for provider <- CredentialStore.list_providers() do
      creds = CredentialStore.load_all(provider)

      for {key, _} <- creds do
        CredentialStore.delete(provider, key)
      end
    end

    for app_key <- [
          :openai_api_key,
          :anthropic_api_key,
          :xai_api_key,
          :discord_bot_token,
          :telegram_bot_token,
          :whatsapp_token
        ] do
      Application.delete_env(:traitee, app_key)
    end

    config_path = Traitee.config_path()
    if File.exists?(config_path), do: File.rm!(config_path)

    approved_path = Path.join(Traitee.data_dir(), "approved_senders.json")
    if File.exists?(approved_path), do: File.rm!(approved_path)
  end

  # -- Steps --

  defp welcome do
    puts("""

    #{Display.logo()}
    #{ANSI.faint()}          Compact AI Operating System#{ANSI.reset()}

    #{ANSI.bright()}Welcome to the Traitee setup wizard!#{ANSI.reset()}

    We're about to build you a personal AI assistant with persistent memory,
    tool use, and multi-channel superpowers. The whole thing takes ~5 minutes.

    Press Enter to accept defaults shown in #{ANSI.cyan()}[brackets]#{ANSI.reset()}.
    #{ANSI.faint()}Ctrl+C to bail at any time (no judgment, we'll be here).#{ANSI.reset()}
    """)

    %{
      step: 1,
      provider: nil,
      model: nil,
      fallback_model: nil,
      ollama_host: nil,
      bot_name: "Traitee",
      system_prompt: nil,
      channels: [],
      channel_configs: %{},
      owner_id: nil,
      channel_ids: %{},
      judge_enabled: false,
      cognitive: %{reminder_interval: 8, canary_enabled: true, output_guard: "redact"},
      tools: %{bash: true, file: true, web_search: false, browser: false, cron: true},
      web_search_key: nil,
      filesystem: %{
        sandbox_mode: true,
        default_policy: "deny",
        docker_enabled: false,
        docker_image: "alpine:latest",
        docker_memory: "256m",
        docker_network: "none",
        exec_gate: true,
        audit: true,
        allowed_paths: []
      },
      gateway_port: 4000,
      secret_key_base: nil
    }
  end

  defp step_llm_provider(state) do
    puts(heading(state, "LLM Provider"))
    puts("Which LLM provider shall power your assistant?\n")

    for {key, {_id, name, _}} <- Enum.sort(@providers) do
      puts("  #{key}) #{name}")
    end

    choice = prompt("\nYour choice [1]") |> normalize("1")

    {provider_id, provider_name, env_var} =
      Map.get(@providers, choice, Map.fetch!(@providers, "1"))

    if env_var do
      api_key = prompt_secret("Enter your #{provider_name} API key")
      CredentialStore.store(provider_id, "api_key", api_key)
      app_key = String.to_atom("#{provider_id}_api_key")
      Application.put_env(:traitee, app_key, api_key)
    end

    state = configure_model(state, provider_id)
    state = maybe_configure_ollama(state, provider_id)

    puts(
      "#{ANSI.green()}✓ #{provider_name} configured — your AI has a brain now#{ANSI.reset()}\n"
    )

    advance(%{state | provider: provider_id})
  end

  defp configure_model(state, provider_id) do
    default = @default_models[provider_id]
    puts("\n  Default model: #{ANSI.bright()}#{default}#{ANSI.reset()}")
    custom = prompt("  Model [#{default}]") |> normalize(default)
    model = custom

    fallback_default = @fallback_models[provider_id]

    fallback =
      if fallback_default do
        puts("  Fallback model (used when primary is down):")
        prompt("  Fallback [#{fallback_default}]") |> normalize(fallback_default)
      else
        nil
      end

    %{state | model: model, fallback_model: fallback}
  end

  defp maybe_configure_ollama(state, :ollama) do
    puts("\n  Ollama needs a base URL to connect to your local instance.")
    host = prompt("  Ollama host [http://localhost:11434]") |> normalize("http://localhost:11434")
    %{state | ollama_host: host}
  end

  defp maybe_configure_ollama(state, _provider), do: state

  defp step_embeddings(state) do
    has_openai = state.provider == :openai

    if has_openai do
      puts(
        "#{ANSI.green()}✓ Embeddings: OpenAI text-embedding-3-small (already configured)#{ANSI.reset()}\n"
      )

      state
    else
      puts(heading(state, "Embeddings"))

      puts("""
      Embeddings let your AI find past conversations by meaning, not just
      keywords. It's the difference between "search" and "actually remembering."

      Your LLM provider doesn't do embeddings, but OpenAI's
      text-embedding-3-small is fast and dirt cheap (~$0.02/million tokens).
      """)

      if confirm?("Add an OpenAI API key for embeddings?") do
        api_key = prompt_secret("Enter your OpenAI API key")

        if api_key != "" do
          CredentialStore.store(:openai, "api_key", api_key)
          Application.put_env(:traitee, :openai_api_key, api_key)
          puts("#{ANSI.green()}✓ Embeddings enabled#{ANSI.reset()}\n")
        else
          puts(skip_hint("embeddings", ~s[CredentialStore.store(:openai, "api_key", "sk-...")]))
        end
      else
        puts(skip_hint("embeddings", ~s[CredentialStore.store(:openai, "api_key", "sk-...")]))
      end

      advance(state)
    end
  end

  defp step_agent_identity(state) do
    puts(heading(state, "Agent Identity"))
    puts("Give your assistant a name and personality. Make it yours.\n")

    name = prompt_text("  Bot name [Traitee]", "Traitee")

    default_prompt =
      "You are #{name}, a personal AI assistant. Be concise, helpful, and personable."

    puts("\n  System prompt defines your assistant's personality.")
    puts("  Default: #{ANSI.faint()}#{default_prompt}#{ANSI.reset()}")
    custom_prompt = prompt_text("  Custom system prompt (or Enter for default)", "")

    system_prompt = if custom_prompt == "", do: default_prompt, else: custom_prompt

    puts("#{ANSI.green()}✓ Say hello to #{name} — a legend is born#{ANSI.reset()}\n")
    advance(%{state | bot_name: name, system_prompt: system_prompt})
  end

  defp step_channels(state) do
    puts(heading(state, "Messaging Channels"))
    puts("Where should your assistant hang out? (comma-separated)\n")

    for {key, {_id, name}} <- Enum.sort(@channels) do
      puts("  #{key}) #{name}")
    end

    puts("  0) None (CLI + WebChat only)")

    input = prompt("\nYour choices [0]") |> normalize("0")

    if input == "0" do
      puts("#{ANSI.green()}✓ CLI + WebChat only — the minimalist's choice#{ANSI.reset()}\n")
      advance(state)
    else
      choices =
        input
        |> String.split(~r/[\s,]+/)
        |> Enum.uniq()
        |> Enum.filter(&Map.has_key?(@channels, &1))

      channel_atoms = Enum.map(choices, fn c -> elem(Map.fetch!(@channels, c), 0) end)

      {configs, state} =
        Enum.reduce(choices, {%{}, state}, fn choice, {cfgs, st} ->
          {channel_id, channel_name} = Map.fetch!(@channels, choice)
          puts("\n  #{ANSI.bright()}── #{channel_name} ──#{ANSI.reset()}")
          {cfg, st} = configure_channel(channel_id, channel_name, st)
          {Map.put(cfgs, channel_id, cfg), st}
        end)

      configured = Enum.map_join(channel_atoms, ", ", &to_string/1)
      puts("\n#{ANSI.green()}✓ Channels: #{configured} — social butterfly mode#{ANSI.reset()}\n")
      advance(%{state | channels: channel_atoms, channel_configs: configs})
    end
  end

  defp configure_channel(:discord, _name, state) do
    token = prompt_secret("  Bot token")
    store_channel_credential(:discord, "bot_token", token, :discord_bot_token)

    policy = prompt_dm_policy()
    {%{enabled: true, token: token, dm_policy: policy}, state}
  end

  defp configure_channel(:telegram, _name, state) do
    token = prompt_secret("  Bot token (from @BotFather)")
    store_channel_credential(:telegram, "bot_token", token, :telegram_bot_token)

    policy = prompt_dm_policy()
    {%{enabled: true, token: token, dm_policy: policy}, state}
  end

  defp configure_channel(:whatsapp, _name, state) do
    token = prompt_secret("  Access token (from Meta developer portal)")
    store_channel_credential(:whatsapp, "bot_token", token, :whatsapp_token)

    phone_id = prompt("  Phone Number ID (from WhatsApp Business API)")
    verify = prompt("  Webhook verify token (you choose this, must match Meta config)")

    policy = prompt_dm_policy()

    config = %{
      enabled: true,
      token: token,
      phone_number_id: phone_id,
      verify_token: verify,
      dm_policy: policy
    }

    {config, state}
  end

  defp configure_channel(:signal, _name, state) do
    cli_path = prompt("  signal-cli path [signal-cli]") |> normalize("signal-cli")
    phone = prompt("  Your Signal phone number (E.164, e.g. +15551234567)")

    policy = prompt_dm_policy()
    {%{enabled: true, cli_path: cli_path, phone_number: phone, dm_policy: policy}, state}
  end

  defp prompt_dm_policy do
    puts("  DM policy — who can message your bot?")
    puts("    1) pairing  — new senders need an approval code (recommended)")
    puts("    2) open     — anyone can message")
    puts("    3) closed   — only the owner can message")
    choice = prompt("  DM policy [1]") |> normalize("1")

    case choice do
      "2" -> "open"
      "3" -> "closed"
      _ -> "pairing"
    end
  end

  defp step_owner_identity(state) do
    puts(heading(state, "Owner Identity"))

    puts("""
    Your owner ID is your admin badge. It gates commands like /pairing,
    /doctor, and /cron — the stuff you don't want randos touching.
    """)

    if state.channels == [] do
      puts("  No channels configured — owner ID is optional for CLI-only mode.")

      owner_id = prompt("  Primary owner ID (or Enter to skip)") |> normalize("")
      state = if owner_id != "", do: %{state | owner_id: owner_id}, else: state
      puts(owner_result(state.owner_id))
      advance(state)
    else
      owner_id = prompt("  Primary owner ID") |> normalize("")
      state = if owner_id != "", do: %{state | owner_id: owner_id}, else: state

      channel_ids = collect_channel_ids(state)
      state = %{state | channel_ids: channel_ids}

      puts(owner_result(state.owner_id))
      advance(state)
    end
  end

  defp collect_channel_ids(state) do
    if length(state.channels) > 1 do
      puts("""

      You have multiple channels. Each platform uses a different ID format.
      Set your per-channel owner ID so Traitee recognizes you on each platform.
      (Leave blank to use the primary owner ID everywhere)
      """)

      Enum.reduce(state.channels, %{}, fn channel, acc ->
        hint = @channel_owner_hints[channel]
        input = prompt("  #{channel} — #{hint}") |> normalize("")
        if input != "", do: Map.put(acc, channel, input), else: acc
      end)
    else
      %{}
    end
  end

  defp owner_result(nil) do
    "\n#{ANSI.yellow()}⚠  No owner ID set — anyone can run admin commands." <>
      "\n  Set later: [security] owner_id = \"your_id\" in config.toml#{ANSI.reset()}\n"
  end

  defp owner_result(_id), do: ""

  defp step_cognitive_security(state) do
    puts(heading(state, "Cognitive Security"))

    puts("""
    Traitee has an 8-layer security pipeline — because paranoia is a feature.
    The LLM-as-judge is the heavyweight: it classifies every inbound message
    for prompt injection, manipulation, and jailbreak attempts in any language.

    Uses xAI's Grok (fast, non-reasoning). Cost: ~$0.0001/message. Bargain.
    """)

    state =
      if confirm?("Enable the LLM security judge?") do
        api_key = prompt_secret("Enter your xAI API key (from console.x.ai)")

        if api_key != "" do
          CredentialStore.store(:xai, "api_key", api_key)
          Application.put_env(:traitee, :xai_api_key, api_key)
          puts("#{ANSI.green()}✓ Security judge enabled#{ANSI.reset()}")
          %{state | judge_enabled: true}
        else
          puts(safety_warning())
          state
        end
      else
        puts(safety_warning())
        state
      end

    state = configure_cognitive_settings(state)
    advance(state)
  end

  defp configure_cognitive_settings(state) do
    if confirm?("\nCustomize cognitive security settings?") do
      interval_s = prompt("  Identity reminder interval (messages) [8]") |> normalize("8")
      interval = parse_int(interval_s, 8)

      canary_s = prompt("  Enable canary tokens for leak detection? [Y/n]") |> normalize("y")
      canary = canary_s in ["y", "yes"]

      puts("  Output guard action on violation:")
      puts("    1) redact  — replace violating content (recommended)")
      puts("    2) log     — log only, don't modify output")
      puts("    3) block   — block the entire response")
      guard_choice = prompt("  Choice [1]") |> normalize("1")

      guard =
        case guard_choice do
          "2" -> "log"
          "3" -> "block"
          _ -> "redact"
        end

      cognitive = %{reminder_interval: interval, canary_enabled: canary, output_guard: guard}
      puts("#{ANSI.green()}✓ Cognitive security configured#{ANSI.reset()}\n")
      %{state | cognitive: cognitive}
    else
      puts("#{ANSI.green()}✓ Using default cognitive security settings#{ANSI.reset()}\n")
      state
    end
  end

  defp step_tools(state) do
    puts(heading(state, "Tools"))

    puts("""
    Your AI can use real tools — not just talk about them. Pick its loadout:

      1) bash        — Run shell commands (the classic)
      2) file        — Read/write/search files
      3) web_search  — Search the web (requires API key)
      4) browser     — Full browser automation via Playwright (requires Node.js)
      5) cron        — Schedule recurring tasks (your AI never sleeps)
    """)

    defaults = "1,2,5"
    input = prompt("Enable which tools? (comma-separated) [#{defaults}]") |> normalize(defaults)
    selected = input |> String.split(~r/[\s,]+/) |> MapSet.new()

    tools = %{
      bash: MapSet.member?(selected, "1"),
      file: MapSet.member?(selected, "2"),
      web_search: MapSet.member?(selected, "3"),
      browser: MapSet.member?(selected, "4"),
      cron: MapSet.member?(selected, "5")
    }

    state = %{state | tools: tools}

    state =
      if tools.web_search do
        puts("\n  Web search requires a search API key (Tavily, Brave, or SerpAPI).")
        key = prompt_secret("  Search API key (or Enter to configure later)")

        if key != "" do
          CredentialStore.store(:web_search, "api_key", key)
          puts("#{ANSI.green()}✓ Web search configured#{ANSI.reset()}")
          %{state | web_search_key: key}
        else
          puts(
            "#{ANSI.yellow()}  Configure later in config.toml: [tools.web_search]#{ANSI.reset()}"
          )

          state
        end
      else
        state
      end

    if tools.browser do
      puts("\n#{ANSI.yellow()}  Note: Browser tool requires Node.js. Run:")
      puts("  cd priv/browser && npm install#{ANSI.reset()}")
    end

    enabled =
      tools
      |> Enum.filter(fn {_k, v} -> v end)
      |> Enum.map_join(", ", fn {k, _} -> to_string(k) end)

    puts("\n#{ANSI.green()}✓ Tools: #{enabled} — locked and loaded#{ANSI.reset()}\n")
    advance(state)
  end

  defp step_filesystem_security(state) do
    puts(heading(state, "Filesystem Security"))

    puts("""
    Your AI has file and shell access. That's powerful — and terrifying.
    Good news: Traitee's filesystem security keeps it on a leash.

    #{ANSI.bright()}Four layers of protection (because one is never enough):#{ANSI.reset()}

      #{ANSI.cyan()}1. I/O guards#{ANSI.reset()} (always on, cannot be disabled)
         Scans tool arguments for sensitive paths before execution.
         Scans tool output for leaked secrets (API keys, private keys,
         passwords, database URLs) and redacts them automatically.
         Fail-closed: if any security check crashes, the operation is denied.

      #{ANSI.cyan()}2. Hardcoded denylists#{ANSI.reset()} (always on, cannot be disabled)
         Blocks access to .ssh, .aws, .env, credentials, private keys,
         /proc, /dev, C:\\Windows\\System32, and 30+ other sensitive paths.
         Blocks dangerous commands: curl|sh pipes, fork bombs, netcat, etc.
         Scrubs secrets from environment variables passed to tools.

      #{ANSI.cyan()}3. Sandbox mode#{ANSI.reset()} (application-level isolation)
         Controls what the AI can access beyond the hardcoded denylists.
         Configurable per-path allow/deny rules with read/write permissions.
         Exec approval gates warn or block risky commands (rm, sudo, etc.).
         Jails bash tool to a sandbox working directory.

      #{ANSI.cyan()}4. Docker isolation#{ANSI.reset()} (OS-level isolation, optional)
         Runs tool commands inside ephemeral Docker containers with:
         read-only filesystem, no network, memory/CPU limits, PID limits.
         The strongest protection — requires Docker to be installed.
    """)

    state = configure_sandbox_mode(state)
    state = configure_allowed_paths(state)
    state = configure_docker(state)
    state = configure_exec_gate(state)
    state = configure_audit(state)

    print_filesystem_summary(state)
    advance(state)
  end

  defp configure_sandbox_mode(state) do
    puts(
      "  #{ANSI.bright()}Sandbox mode#{ANSI.reset()} sets the default access policy for the AI's tools."
    )

    puts("  With sandbox ON, the AI can only access paths you explicitly allow.")
    puts("  With sandbox OFF, reads are allowed everywhere (writes still blocked).\n")

    sandbox = confirm?("  Enable sandbox mode? (recommended)")

    policy =
      if sandbox do
        puts(
          "\n  #{ANSI.bright()}Default policy#{ANSI.reset()} — what happens when a path doesn't match any rule:"
        )

        puts("    1) deny      — block all access unless explicitly allowed (most secure)")
        puts("    2) read_only — allow reads, block writes unless explicitly allowed")
        choice = prompt("    Policy [1]") |> normalize("1")
        if choice == "2", do: "read_only", else: "deny"
      else
        "read_only"
      end

    puts(
      "#{ANSI.green()}  ✓ Sandbox: #{if sandbox, do: "ON", else: "OFF"}, default policy: #{policy}#{ANSI.reset()}\n"
    )

    fs = %{state.filesystem | sandbox_mode: sandbox, default_policy: policy}
    %{state | filesystem: fs}
  end

  defp configure_allowed_paths(state) do
    needs_allow = state.filesystem.sandbox_mode and state.filesystem.default_policy == "deny"

    if needs_allow do
      puts("  #{ANSI.bright()}Allowed paths#{ANSI.reset()} — directories the AI can access.")
      puts("  The Traitee data dir (~/.traitee) is always accessible.\n")
      prompt_allowed_paths(state)
    else
      state
    end
  end

  defp prompt_allowed_paths(state) do
    if confirm?("  Add allowed directories now?") do
      paths = collect_paths([])
      print_allowed_paths(paths)
      fs = %{state.filesystem | allowed_paths: paths}
      %{state | filesystem: fs}
    else
      puts("#{ANSI.yellow()}  No paths added — the AI can only access ~/.traitee/**")
      puts("  Add later: [[security.filesystem.allow]] in config.toml#{ANSI.reset()}\n")
      state
    end
  end

  defp print_allowed_paths([]), do: :ok

  defp print_allowed_paths(paths) do
    formatted = Enum.map_join(paths, ", ", fn {p, _} -> p end)
    puts("#{ANSI.green()}  ✓ Allowed: #{formatted}#{ANSI.reset()}\n")
  end

  defp collect_paths(acc) do
    input = prompt("    Directory path (or Enter to finish)") |> String.trim()

    if input == "" do
      Enum.reverse(acc)
    else
      expanded = Path.expand(input)
      puts("    Permission for #{expanded}:")
      puts("      1) read + write")
      puts("      2) read only")
      perm_choice = prompt("      Permission [1]") |> normalize("1")
      perms = if perm_choice == "2", do: ["read"], else: ["read", "write"]
      collect_paths([{expanded, perms} | acc])
    end
  end

  defp configure_docker(state) do
    if state.tools.bash do
      puts("  #{ANSI.bright()}Docker isolation#{ANSI.reset()} — the strongest protection layer.")
      puts("  Runs every shell command inside a throwaway Docker container with:")
      puts("  - Read-only filesystem (can't modify the host)")
      puts("  - No network access (can't exfiltrate data)")
      puts("  - Memory/CPU limits (can't resource-bomb your machine)")
      puts("  - Automatic cleanup (container deleted after each command)")
      puts("")
      puts("  #{ANSI.faint()}Requires Docker to be installed and running.#{ANSI.reset()}")

      puts(
        "  #{ANSI.faint()}Falls back to host execution if Docker is unavailable.#{ANSI.reset()}\n"
      )

      docker = confirm?("  Enable Docker isolation?")

      state =
        if docker do
          state = put_in(state.filesystem.docker_enabled, true)
          maybe_customize_docker(state)
        else
          state
        end

      docker_status = if state.filesystem.docker_enabled, do: "ON", else: "OFF"
      puts("#{ANSI.green()}  ✓ Docker isolation: #{docker_status}#{ANSI.reset()}\n")
      state
    else
      state
    end
  end

  defp maybe_customize_docker(state) do
    if confirm?("    Customize Docker settings?") do
      image = prompt("    Base image [alpine:latest]") |> normalize("alpine:latest")
      memory = prompt("    Memory limit [256m]") |> normalize("256m")

      puts("    Network mode:")
      puts("      1) none   — no network access (most secure)")
      puts("      2) bridge — default Docker networking")
      net_choice = prompt("    Network [1]") |> normalize("1")
      network = if net_choice == "2", do: "bridge", else: "none"

      fs = %{
        state.filesystem
        | docker_image: image,
          docker_memory: memory,
          docker_network: network
      }

      %{state | filesystem: fs}
    else
      state
    end
  end

  defp configure_exec_gate(state) do
    puts("  #{ANSI.bright()}Exec approval gates#{ANSI.reset()} — warn or block risky commands.")
    puts("  Default rules flag: rm, chmod, git push, curl, wget, docker,")
    puts("  sudo, npm publish, pip install, and PowerShell policy bypass.\n")

    gate = confirm?("  Enable exec approval gates? (recommended)")
    puts("#{ANSI.green()}  ✓ Exec gates: #{if gate, do: "ON", else: "OFF"}#{ANSI.reset()}\n")

    fs = %{state.filesystem | exec_gate: gate}
    %{state | filesystem: fs}
  end

  defp configure_audit(state) do
    puts(
      "  #{ANSI.bright()}Security audit trail#{ANSI.reset()} — logs every filesystem access decision."
    )

    puts("  Enables `mix traitee.security` to review access patterns and denials.\n")

    audit = confirm?("  Enable audit trail? (recommended)")
    puts("#{ANSI.green()}  ✓ Audit trail: #{if audit, do: "ON", else: "OFF"}#{ANSI.reset()}\n")

    fs = %{state.filesystem | audit: audit}
    %{state | filesystem: fs}
  end

  defp print_filesystem_summary(state) do
    fs = state.filesystem
    protection_level = filesystem_protection_level(fs)

    puts("""
    #{ANSI.bright()}Filesystem security summary:#{ANSI.reset()}
      Protection:    #{protection_level}
      Sandbox:       #{if fs.sandbox_mode, do: "ON (#{fs.default_policy})", else: "OFF"}
      Docker:        #{if fs.docker_enabled, do: "ON (#{fs.docker_image}, network=#{fs.docker_network})", else: "OFF"}
      Exec gates:    #{if fs.exec_gate, do: "ON", else: "OFF"}
      Audit trail:   #{if fs.audit, do: "ON", else: "OFF"}
      Allowed paths: #{if fs.allowed_paths == [], do: "~/.traitee only", else: "#{length(fs.allowed_paths)} configured"}
      #{ANSI.faint()}I/O guards and hardcoded denylists are always active regardless of these settings.#{ANSI.reset()}
    """)
  end

  defp filesystem_protection_level(fs) do
    cond do
      fs.docker_enabled and fs.sandbox_mode and fs.exec_gate ->
        "#{ANSI.green()}#{ANSI.bright()}MAXIMUM#{ANSI.reset()} — I/O guards + sandbox + Docker + exec gates"

      fs.sandbox_mode and fs.exec_gate ->
        "#{ANSI.green()}HIGH#{ANSI.reset()} — I/O guards + sandbox + exec gates (no Docker)"

      fs.sandbox_mode ->
        "#{ANSI.cyan()}MODERATE#{ANSI.reset()} — I/O guards + sandbox only"

      true ->
        "#{ANSI.yellow()}BASIC#{ANSI.reset()} — I/O guards + hardcoded denylists only"
    end
  end

  defp step_gateway(state) do
    puts(heading(state, "Gateway"))
    puts("The gateway is how the outside world talks to your AI.\n")

    port_s = prompt("  Port [4000]") |> normalize("4000")
    port = parse_int(port_s, 4000)

    puts("")

    secret =
      if confirm?("Generate a SECRET_KEY_BASE for Phoenix? (required for production)") do
        key = :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false) |> binary_part(0, 64)
        CredentialStore.store(:phoenix, "secret_key_base", key)
        puts("#{ANSI.green()}✓ Generated and saved SECRET_KEY_BASE#{ANSI.reset()}")
        puts("  #{ANSI.faint()}#{key}#{ANSI.reset()}")
        puts("  Also stored in credential store. Set SECRET_KEY_BASE env var in production.\n")
        key
      else
        nil
      end

    puts("#{ANSI.green()}✓ Gateway on port #{port}#{ANSI.reset()}\n")
    advance(%{state | gateway_port: port, secret_key_base: secret})
  end

  defp step_workspace(state) do
    puts(heading(state, "Workspace & Database"))
    Traitee.Workspace.ensure_workspace!()
    dir = Traitee.Workspace.workspace_dir()
    puts("#{ANSI.green()}✓ Workspace: #{dir}#{ANSI.reset()}")

    puts("  Running database migrations...")
    run_migrations()
    puts("#{ANSI.green()}✓ Database ready#{ANSI.reset()}")

    write_config(state)
    write_soul_md(state)
    config_path = Traitee.config_path()
    puts("#{ANSI.green()}✓ Config written to #{config_path}#{ANSI.reset()}\n")
    advance(state)
  end

  defp step_test_connection(state) do
    puts(heading(state, "Connection Test"))

    if confirm?("Send a test message to the LLM?") do
      puts("  Pinging your AI's brain... #{ANSI.faint()}(fingers crossed)#{ANSI.reset()}")

      case Traitee.LLM.Router.complete(%{
             messages: [%{role: "user", content: "Say hello in one sentence."}]
           }) do
        {:ok, resp} ->
          puts("#{ANSI.green()}✓ IT'S ALIVE! #{ANSI.reset()}#{resp.content}\n")

        {:error, reason} ->
          puts("#{ANSI.red()}✗ Connection failed: #{inspect(reason)}#{ANSI.reset()}")

          puts(
            "  #{ANSI.faint()}No worries — fix later in ~/.traitee/config.toml#{ANSI.reset()}\n"
          )
      end
    end

    advance(state)
  end

  defp step_daemon(state) do
    puts(heading(state, "Background Service"))
    platform = Service.platform()
    platform_name = platform |> to_string() |> String.capitalize()

    if confirm?("Install Traitee as a #{platform_name} background service?") do
      case Service.install() do
        :ok ->
          puts(
            "#{ANSI.green()}✓ Service installed — it'll outlive your browser tabs#{ANSI.reset()}\n"
          )

        {:error, reason} ->
          puts("#{ANSI.red()}✗ Failed: #{inspect(reason)}#{ANSI.reset()}")

          puts(
            "  #{ANSI.faint()}No sweat — install manually later: mix traitee.daemon install#{ANSI.reset()}\n"
          )
      end
    end

    state
  end

  defp summary(state) do
    channels_text =
      if state.channels == [], do: "CLI only", else: Enum.join(state.channels, ", ")

    cogsec_text =
      if state.judge_enabled,
        do: "LLM judge + full pipeline",
        else: "regex + pipeline (no judge)"

    puts("""

    #{ANSI.green()}  ████████████████████████ 100%#{ANSI.reset()}
    #{ANSI.bright()}#{ANSI.green()}  ── Setup Complete! ──────────────────────────────#{ANSI.reset()}

    #{ANSI.bright()}Your AI assistant is alive and kicking.#{ANSI.reset()} Here's the rundown:

      #{ANSI.bright()}Model#{ANSI.reset()}:      #{state.model}#{fallback_line(state)}
      #{ANSI.bright()}Agent#{ANSI.reset()}:      #{state.bot_name}
      #{ANSI.bright()}Channels#{ANSI.reset()}:   #{channels_text}
      #{ANSI.bright()}Owner#{ANSI.reset()}:      #{state.owner_id || "#{ANSI.faint()}(not set)#{ANSI.reset()}"}
      #{ANSI.bright()}Security#{ANSI.reset()}:   #{cogsec_text}
      #{ANSI.bright()}Filesystem#{ANSI.reset()}: #{summary_filesystem(state.filesystem)}
      #{ANSI.bright()}Gateway#{ANSI.reset()}:    http://127.0.0.1:#{state.gateway_port}

    #{ANSI.yellow()}#{ANSI.bright()}What's next:#{ANSI.reset()}

      #{ANSI.cyan()}mix traitee.chat#{ANSI.reset()}           Start chatting right now
      #{ANSI.cyan()}mix traitee.serve#{ANSI.reset()}          Fire up the full gateway
      #{ANSI.cyan()}mix traitee.daemon start#{ANSI.reset()}   Run as a background service
      #{ANSI.cyan()}mix traitee.doctor#{ANSI.reset()}         Health check everything
      #{ANSI.cyan()}mix traitee.security#{ANSI.reset()}       Audit filesystem posture

    #{ANSI.faint()}Config: #{Traitee.config_path()}#{ANSI.reset()}
    #{ANSI.faint()}Data:   #{Traitee.data_dir()}#{ANSI.reset()}

    #{ANSI.yellow()}Re-running #{ANSI.cyan()}mix traitee.onboard#{ANSI.yellow()} will wipe these values. You've been warned.#{ANSI.reset()}
    """)

    state
  end

  defp fallback_line(%{fallback_model: nil}), do: ""
  defp fallback_line(%{fallback_model: fb}), do: "\n      Fallback:   #{fb}"

  defp summary_filesystem(fs) do
    parts =
      [
        if(fs.sandbox_mode, do: "sandbox(#{fs.default_policy})"),
        if(fs.docker_enabled, do: "Docker"),
        if(fs.exec_gate, do: "exec-gates"),
        if(fs.audit, do: "audit")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "hardcoded denylists only", else: Enum.join(parts, " + ")
  end

  # -- Config file generation --

  defp write_config(state) do
    path = Traitee.config_path()
    File.mkdir_p!(Path.dirname(path))

    sections = [
      build_agent_section(state),
      build_memory_section(),
      build_channel_sections(state),
      build_tools_section(state),
      build_security_section(state),
      build_gateway_section(state)
    ]

    content =
      sections
      |> List.flatten()
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    File.write!(path, content <> "\n")
  end

  defp build_agent_section(state) do
    lines = [
      "[agent]",
      ~s(model = "#{state.model}")
    ]

    lines =
      if state.fallback_model,
        do: lines ++ [~s(fallback_model = "#{state.fallback_model}")],
        else: lines

    lines =
      lines ++
        [
          ~s(bot_name = "#{escape_toml(state.bot_name)}"),
          ~s(system_prompt = "#{escape_toml(state.system_prompt)}")
        ]

    lines =
      if state.ollama_host,
        do: lines ++ [~s(ollama_host = "#{state.ollama_host}")],
        else: lines

    Enum.join(lines, "\n")
  end

  defp write_soul_md(state) do
    path = Path.join(Traitee.Workspace.workspace_dir(), "SOUL.md")
    name = state.bot_name

    content = """
    # #{name}

    You are **#{name}**, a compact personal AI assistant platform running locally on the user's machine.
    You are NOT a generic AI chatbot. Never identify yourself as ChatGPT, Claude, GPT, or any underlying model.

    ## Your Platform Capabilities

    - **Shell and File Tools**: Run shell commands and read/write files on the user's local machine.
    - **Browser**: Full Chromium browser -- navigate to any URL, read pages via accessibility snapshots, click, type, fill forms, take screenshots, run JavaScript, and manage tabs.
    - **Persistent Memory**: Short-term (conversation), medium-term (session summaries), and long-term memory (facts and knowledge graph) that survive across sessions.
    - **Multi-Channel**: Reachable via CLI, Discord, Telegram, WhatsApp, and Signal.
    - **Scheduled Jobs**: Run cron jobs, both recurring and one-shot tasks on a schedule.
    - **Custom Skills**: Extensible with user-defined skills loaded from the workspace.

    When asked what you can do, describe these platform capabilities, not generic LLM abilities like writing essays or brainstorming.
    """

    File.write!(path, content)
  end

  defp build_memory_section do
    """
    [memory]
    stm_capacity = 50
    mtm_chunk_size = 20
    embedding_model = "openai/text-embedding-3-small"\
    """
  end

  defp build_channel_sections(%{channels: []}), do: ""

  defp build_channel_sections(state) do
    Enum.map(state.channels, fn channel ->
      cfg = Map.get(state.channel_configs, channel, %{})
      build_single_channel(channel, cfg)
    end)
  end

  defp build_single_channel(:discord, cfg) do
    """
    [channels.discord]
    enabled = true
    # Token loaded from credential store
    dm_policy = "#{cfg[:dm_policy] || "pairing"}"\
    """
  end

  defp build_single_channel(:telegram, cfg) do
    """
    [channels.telegram]
    enabled = true
    # Token loaded from credential store
    dm_policy = "#{cfg[:dm_policy] || "pairing"}"\
    """
  end

  defp build_single_channel(:whatsapp, cfg) do
    lines = [
      "[channels.whatsapp]",
      "enabled = true",
      "# Token loaded from credential store"
    ]

    lines =
      if cfg[:phone_number_id],
        do: lines ++ [~s(phone_number_id = "#{cfg.phone_number_id}")],
        else: lines

    lines =
      if cfg[:verify_token], do: lines ++ [~s(verify_token = "#{cfg.verify_token}")], else: lines

    lines = lines ++ [~s(dm_policy = "#{cfg[:dm_policy] || "pairing"}")]

    Enum.join(lines, "\n")
  end

  defp build_single_channel(:signal, cfg) do
    lines = [
      "[channels.signal]",
      "enabled = true"
    ]

    lines = if cfg[:cli_path], do: lines ++ [~s(cli_path = "#{cfg.cli_path}")], else: lines

    lines =
      if cfg[:phone_number], do: lines ++ [~s(phone_number = "#{cfg.phone_number}")], else: lines

    lines = lines ++ [~s(dm_policy = "#{cfg[:dm_policy] || "pairing"}")]

    Enum.join(lines, "\n")
  end

  defp build_single_channel(channel, cfg) do
    "[channels.#{channel}]\nenabled = true\ndm_policy = \"#{cfg[:dm_policy] || "pairing"}\""
  end

  defp build_tools_section(state) do
    t = state.tools

    lines = [
      "[tools]",
      "bash = { enabled = #{t.bash} }",
      "file = { enabled = #{t.file} }",
      "web_search = { enabled = #{t.web_search} }",
      "browser = { enabled = #{t.browser} }",
      "cron = { enabled = #{t.cron} }"
    ]

    Enum.join(lines, "\n")
  end

  defp build_security_section(state) do
    lines = [
      "[security]",
      "enabled = true"
    ]

    lines = if state.owner_id, do: lines ++ [~s(owner_id = "#{state.owner_id}")], else: lines

    channel_id_lines = build_channel_id_lines(state.channel_ids)

    cognitive_lines = [
      "",
      "[security.cognitive]",
      "enabled = true",
      "reminder_interval = #{state.cognitive.reminder_interval}",
      "canary_enabled = #{state.cognitive.canary_enabled}",
      ~s(output_guard = "#{state.cognitive.output_guard}"),
      "",
      "[security.cognitive.judge]",
      "enabled = #{state.judge_enabled}",
      ~s(model = "xai/grok-4-1-fast-non-reasoning"),
      "timeout_ms = 3000",
      "min_message_length = 10"
    ]

    filesystem_lines = build_filesystem_lines(state.filesystem)

    all_lines = lines ++ channel_id_lines ++ cognitive_lines ++ filesystem_lines
    Enum.join(all_lines, "\n")
  end

  defp build_filesystem_lines(fs) do
    lines = [
      "",
      "[security.filesystem]",
      "sandbox_mode = #{fs.sandbox_mode}",
      ~s(default_policy = "#{fs.default_policy}")
    ]

    allow_lines =
      Enum.flat_map(fs.allowed_paths, fn {path, perms} ->
        perms_toml = Enum.map_join(perms, ", ", &~s("#{&1}"))

        [
          "",
          "[[security.filesystem.allow]]",
          ~s(pattern = "#{escape_toml(path)}/**"),
          "permissions = [#{perms_toml}]"
        ]
      end)

    docker_lines = [
      "",
      "[security.filesystem.docker]",
      "enabled = #{fs.docker_enabled}",
      ~s(image = "#{fs.docker_image}"),
      ~s(memory = "#{fs.docker_memory}"),
      ~s(network = "#{fs.docker_network}")
    ]

    gate_lines = [
      "",
      "[security.filesystem.exec_gate]",
      "enabled = #{fs.exec_gate}"
    ]

    audit_lines = [
      "",
      "[security.filesystem.audit]",
      "enabled = #{fs.audit}"
    ]

    lines ++ allow_lines ++ docker_lines ++ gate_lines ++ audit_lines
  end

  defp build_channel_id_lines(ids) when map_size(ids) == 0, do: []

  defp build_channel_id_lines(ids) do
    id_lines =
      Enum.map(ids, fn {channel, id} ->
        ~s(#{channel} = "#{id}")
      end)

    ["", "[security.channel_ids]"] ++ id_lines
  end

  defp build_gateway_section(state) do
    """
    [gateway]
    port = #{state.gateway_port}
    host = "127.0.0.1"\
    """
  end

  # -- Helpers --

  defp heading(state, text) do
    step = state.step
    filled = div(step * 24, @total_steps)
    empty = 24 - filled
    bar_fill = "#{ANSI.cyan()}#{String.duplicate("█", filled)}#{ANSI.reset()}"
    bar_rest = "#{ANSI.faint()}#{String.duplicate("░", empty)}#{ANSI.reset()}"
    pct = div(step * 100, @total_steps)
    vibe = Map.get(@step_vibes, text, "")

    progress = "  #{bar_fill}#{bar_rest} #{ANSI.faint()}#{pct}%#{ANSI.reset()}"
    title = "  #{ANSI.bright()}#{ANSI.cyan()}── Step #{step} · #{text} ──#{ANSI.reset()}"
    subtitle = if vibe != "", do: "  #{ANSI.faint()}#{vibe}#{ANSI.reset()}", else: nil

    ["\n", progress, title, subtitle]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp advance(state), do: %{state | step: state.step + 1}

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

  defp prompt_text(label, default) do
    raw = IO.gets("#{label}: ") |> to_string() |> String.trim()
    if raw == "", do: default, else: raw
  end

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp escape_toml(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp store_channel_credential(provider, key, value, app_key) do
    CredentialStore.store(provider, key, value)
    Application.put_env(:traitee, app_key, value)
  end

  defp skip_hint(feature, code) do
    "#{ANSI.yellow()}Skipped #{feature}. Add later:\n" <>
      "  #{ANSI.cyan()}#{code}#{ANSI.reset()}\n"
  end

  defp safety_warning do
    """
    #{ANSI.yellow()}#{ANSI.bright()}⚠  Security judge skipped — living dangerously, I see#{ANSI.reset()}
    #{ANSI.yellow()}Without the LLM judge, Traitee relies on regex pattern matching only.
    Creative attacks (other languages, encodings, novel jailbreaks) will slip through.
    The other layers (canary tokens, output guard) still have your back though.

    #{ANSI.faint()}Enable later: #{ANSI.cyan()}mix traitee.onboard#{ANSI.reset()}#{ANSI.yellow()}#{ANSI.faint()}
    Or manually: #{ANSI.cyan()}CredentialStore.store(:xai, "api_key", "xai-...")#{ANSI.reset()}
    """
  end

  defp run_migrations do
    migrations_path = Path.join(:code.priv_dir(:traitee), "repo/migrations")
    Ecto.Migrator.run(Traitee.Repo, migrations_path, :up, all: true)
  end

  defp puts(text), do: IO.puts(text)
end
