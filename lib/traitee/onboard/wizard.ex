defmodule Traitee.Onboard.Wizard do
  @moduledoc "Interactive onboarding wizard for first-time setup."

  alias IO.ANSI
  alias Traitee.Secrets.CredentialStore

  @providers %{
    "1" => {:openai, "OpenAI", "OPENAI_API_KEY"},
    "2" => {:anthropic, "Anthropic", "ANTHROPIC_API_KEY"},
    "3" => {:ollama, "Ollama (local)", nil}
  }

  @default_models %{
    openai: "openai/gpt-4o",
    anthropic: "anthropic/claude-sonnet-4",
    ollama: "ollama/llama3"
  }

  @fallback_models %{
    openai: "anthropic/claude-sonnet-4",
    anthropic: "openai/gpt-4o",
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

  def run do
    welcome()
    |> step_llm_provider()
    |> step_embeddings()
    |> step_agent_identity()
    |> step_channels()
    |> step_owner_identity()
    |> step_cognitive_security()
    |> step_tools()
    |> step_gateway()
    |> step_workspace()
    |> step_test_connection()
    |> step_daemon()
    |> summary()
  rescue
    _ ->
      puts(
        "\n#{ANSI.yellow()}Setup interrupted. Run `mix traitee.onboard` to try again.#{ANSI.reset()}"
      )
  end

  # -- Steps --

  defp welcome do
    puts("""
    #{ANSI.cyan()}#{ANSI.bright()}
    ╔══════════════════════════════════════╗
    ║        Welcome to Traitee! 🤖       ║
    ╚══════════════════════════════════════╝
    #{ANSI.reset()}
    Traitee is a personal AI assistant that connects to your
    favorite messaging platforms with persistent memory.

    Let's get you set up. Press Enter to accept defaults shown in [brackets].
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
      gateway_port: 4000,
      secret_key_base: nil
    }
  end

  defp step_llm_provider(state) do
    puts(heading(state, "LLM Provider"))
    puts("Which LLM provider do you want to use?\n")

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

    puts("#{ANSI.green()}✓ #{provider_name} configured#{ANSI.reset()}\n")
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
    puts("Give your assistant a name and personality.\n")

    name = prompt_text("  Bot name [Traitee]", "Traitee")

    default_prompt =
      "You are #{name}, a personal AI assistant. Be concise, helpful, and personable."

    puts("\n  System prompt defines your assistant's personality.")
    puts("  Default: #{ANSI.faint()}#{default_prompt}#{ANSI.reset()}")
    custom_prompt = prompt_text("  Custom system prompt (or Enter for default)", "")

    system_prompt = if custom_prompt == "", do: default_prompt, else: custom_prompt

    puts("#{ANSI.green()}✓ Agent: #{name}#{ANSI.reset()}\n")
    advance(%{state | bot_name: name, system_prompt: system_prompt})
  end

  defp step_channels(state) do
    puts(heading(state, "Messaging Channels"))
    puts("Which channels do you want to enable? (comma-separated)\n")

    for {key, {_id, name}} <- Enum.sort(@channels) do
      puts("  #{key}) #{name}")
    end

    puts("  0) None (CLI + WebChat only)")

    input = prompt("\nYour choices [0]") |> normalize("0")

    if input == "0" do
      puts("#{ANSI.green()}✓ CLI + WebChat only#{ANSI.reset()}\n")
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
      puts("\n#{ANSI.green()}✓ Channels: #{configured}#{ANSI.reset()}\n")
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
    Your owner ID identifies you as the admin. It gates commands like
    /pairing, /doctor, and /cron. It's also used as your default session key.
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
    Traitee includes an 8-layer security pipeline. The LLM-as-judge is the
    most powerful layer — it classifies every message for prompt injection,
    manipulation, and jailbreak attempts in any language or encoding.

    This uses xAI's Grok (fast, non-reasoning). Cost: ~$0.0001/message.
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
    Traitee can use tools during conversations. Select which to enable:

      1) bash        — Run shell commands
      2) file        — Read/write/search files
      3) web_search  — Search the web (requires API key)
      4) browser     — Browser automation via Playwright (requires Node.js)
      5) cron        — Schedule recurring tasks
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

    puts("\n#{ANSI.green()}✓ Tools: #{enabled}#{ANSI.reset()}\n")
    advance(state)
  end

  defp step_gateway(state) do
    puts(heading(state, "Gateway"))
    puts("The gateway exposes the HTTP API, webhooks, and WebChat.\n")

    port_s = prompt("  Port [4000]") |> normalize("4000")
    port = parse_int(port_s, 4000)

    puts("")

    secret =
      if confirm?("Generate a SECRET_KEY_BASE for Phoenix? (required for production)") do
        key = :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false) |> binary_part(0, 64)
        puts("#{ANSI.green()}✓ Generated SECRET_KEY_BASE#{ANSI.reset()}")
        puts("  #{ANSI.faint()}#{key}#{ANSI.reset()}")
        puts("  Set this as the SECRET_KEY_BASE environment variable in production.\n")
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
      puts("  Sending...")

      case Traitee.LLM.Router.complete(%{
             messages: [%{role: "user", content: "Say hello in one sentence."}]
           }) do
        {:ok, resp} ->
          puts("#{ANSI.green()}✓ LLM responded: #{resp.content}#{ANSI.reset()}\n")

        {:error, reason} ->
          puts("#{ANSI.red()}✗ Connection failed: #{inspect(reason)}#{ANSI.reset()}")
          puts("  Fix later in ~/.traitee/config.toml\n")
      end
    end

    advance(state)
  end

  defp step_daemon(state) do
    puts(heading(state, "Background Service"))
    platform = Traitee.Daemon.Service.platform()
    platform_name = platform |> to_string() |> String.capitalize()

    if confirm?("Install Traitee as a #{platform_name} background service?") do
      case Traitee.Daemon.Service.install() do
        :ok ->
          puts("#{ANSI.green()}✓ Service installed#{ANSI.reset()}\n")

        {:error, reason} ->
          puts("#{ANSI.red()}✗ Failed: #{inspect(reason)}#{ANSI.reset()}")
          puts("  Install manually later: mix traitee.daemon install\n")
      end
    end

    state
  end

  defp summary(state) do
    puts("""

    #{ANSI.bright()}#{ANSI.cyan()}╔══════════════════════════════════════╗
    ║          Setup Complete! ✓          ║
    ╚══════════════════════════════════════╝#{ANSI.reset()}

    #{ANSI.bright()}Configuration summary:#{ANSI.reset()}
      Model:      #{state.model}#{fallback_line(state)}
      Agent:      #{state.bot_name}
      Channels:   #{if state.channels == [], do: "CLI only", else: Enum.join(state.channels, ", ")}
      Owner:      #{state.owner_id || "(not set)"}
      Security:   #{if state.judge_enabled, do: "LLM judge + full pipeline", else: "Regex + pipeline (no judge)"}
      Gateway:    http://127.0.0.1:#{state.gateway_port}

    #{ANSI.bright()}What's next:#{ANSI.reset()}
      #{ANSI.cyan()}mix traitee.chat#{ANSI.reset()}         Start a CLI chat session
      #{ANSI.cyan()}mix traitee.serve#{ANSI.reset()}        Start the gateway server
      #{ANSI.cyan()}mix traitee.daemon start#{ANSI.reset()} Run as background service
      #{ANSI.cyan()}mix traitee.doctor#{ANSI.reset()}       Check system health

    Config: #{Traitee.config_path()}
    Data:   #{Traitee.data_dir()}
    """)

    state
  end

  defp fallback_line(%{fallback_model: nil}), do: ""
  defp fallback_line(%{fallback_model: fb}), do: "\n      Fallback:   #{fb}"

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

    all_lines = lines ++ channel_id_lines ++ cognitive_lines
    Enum.join(all_lines, "\n")
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
    "\n#{ANSI.bright()}#{ANSI.cyan()}── Step #{state.step}: #{text} ──#{ANSI.reset()}\n"
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
    #{ANSI.yellow()}#{ANSI.bright()}⚠  Security judge skipped#{ANSI.reset()}
    #{ANSI.yellow()}Without the LLM judge, Traitee relies on regex pattern matching only.
    Attacks using other languages, encodings, or novel techniques won't be caught
    at the input layer. Other layers (canary, output guard) still active.

    Enable later: #{ANSI.cyan()}mix traitee.onboard#{ANSI.reset()}#{ANSI.yellow()}
    Or manually: #{ANSI.cyan()}CredentialStore.store(:xai, "api_key", "xai-...")#{ANSI.reset()}
    """
  end

  defp run_migrations do
    migrations_path = Path.join(:code.priv_dir(:traitee), "repo/migrations")
    Ecto.Migrator.run(Traitee.Repo, migrations_path, :up, all: true)
  end

  defp puts(text), do: IO.puts(text)
end
