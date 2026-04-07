defmodule Traitee.CLI.Display do
  @moduledoc "Terminal display utilities for the CLI interface."

  alias IO.ANSI

  @panel_width 55

  @tool_categories [
    {"core", ~w(bash file)},
    {"web", ~w(web_search browser)},
    {"memory", ~w(memory sessions)},
    {"comms", ~w(channel_send)},
    {"schedule", ~w(cron)},
    {"agent", ~w(skill_manage workspace_edit delegate_task task_tracker)},
    {"cognition", ~w(cognition)}
  ]

  # -- Banners --

  def chat_banner(session_id) do
    config = safe_config()
    model = get_in(config, [:agent, :model]) || "not configured"
    tools = gather_tools()
    skills = gather_skills()

    [
      "",
      logo(),
      tagline(),
      "",
      tools_section(tools),
      "",
      skills_section(skills),
      counts_line(tools, skills),
      "",
      cognition_section(),
      "",
      session_section(session_id, model),
      warnings(config),
      "",
      "  Welcome to Traitee! Type your message or /help for commands.",
      ""
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def serve_banner(config) do
    model = get_in(config, [:agent, :model]) || "not configured"
    port = get_port()
    channels = format_channels(config)
    tools = gather_tools()
    skills = gather_skills()

    [
      "",
      logo(),
      tagline(),
      "",
      server_section(port),
      "",
      channels_section(channels),
      "",
      model_section(model),
      counts_line(tools, skills),
      "",
      "  Gateway running. Press Ctrl+C to stop.",
      ""
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # -- Prompts & Message Formatting --

  def user_prompt, do: "#{ANSI.cyan()}#{ANSI.bright()}› #{ANSI.reset()}"

  def assistant_prefix, do: "#{ANSI.magenta()}◆ #{ANSI.reset()}"

  def system_msg(text), do: "#{ANSI.yellow()}▸ #{ANSI.reset()}#{text}"

  def error_msg(text), do: "#{ANSI.red()}✘ #{ANSI.reset()}#{text}"

  def goodbye, do: "\n#{ANSI.faint()}Goodbye!#{ANSI.reset()}"

  # -- Tool Call Summaries --

  @max_summary_len 40

  @doc "Returns a display label for a tool call: name + short summary of what it does."
  def tool_summary(name, args) when is_map(args) do
    case summarize_tool(name, args) do
      nil -> name
      summary -> "#{name} — #{summary}"
    end
  end

  def tool_summary(name, _args), do: name

  defp summarize_tool("bash", %{"command" => cmd}) when is_binary(cmd),
    do: trunc_text(String.replace(cmd, "\n", " "))

  defp summarize_tool("file", %{"operation" => op, "path" => path}) when is_binary(path),
    do: "#{op} #{Path.basename(path)}"

  defp summarize_tool("web_search", %{"query" => q}) when is_binary(q),
    do: trunc_text(q)

  defp summarize_tool("browser", %{"action" => action, "url" => url}) when is_binary(url),
    do: "#{action} #{trunc_text(URI.parse(url).host || url)}"

  defp summarize_tool("browser", %{"action" => action}), do: action

  defp summarize_tool("memory", %{"action" => "remember", "entity" => e}) when is_binary(e),
    do: "remember #{e}"

  defp summarize_tool("memory", %{"action" => "recall", "query" => q}) when is_binary(q),
    do: "recall #{trunc_text(q)}"

  defp summarize_tool("memory", %{"action" => a}), do: a

  defp summarize_tool("sessions", %{"action" => a, "session_id" => sid}) when is_binary(sid),
    do: "#{a} #{sid}"

  defp summarize_tool("sessions", %{"action" => a}), do: a

  defp summarize_tool("cron", %{"action" => a, "name" => n}) when is_binary(n), do: "#{a} #{n}"
  defp summarize_tool("cron", %{"action" => a}), do: a

  defp summarize_tool("channel_send", %{"channel" => ch}) when is_binary(ch), do: ch

  defp summarize_tool("skill_manage", %{"action" => a, "name" => n}) when is_binary(n),
    do: "#{a} #{n}"

  defp summarize_tool("skill_manage", %{"action" => a}), do: a

  defp summarize_tool("workspace_edit", %{"action" => a, "file" => f}) when is_binary(f),
    do: "#{a} #{f}"

  defp summarize_tool("delegate_task", %{"action" => "status"}), do: "status"

  defp summarize_tool("delegate_task", %{"tasks" => tasks}) when is_list(tasks) do
    tags = Enum.map_join(tasks, ", ", &((&1["tag"] || "task") |> to_string()))
    trunc_text(tags)
  end

  defp summarize_tool("task_tracker", %{"action" => a, "id" => id}) when is_binary(id),
    do: "#{a} #{id}"

  defp summarize_tool("task_tracker", %{"action" => a}), do: a

  defp summarize_tool("cognition", %{"action" => "enqueue_curiosity", "topic" => t})
       when is_binary(t),
       do: "research #{trunc_text(t)}"

  defp summarize_tool("cognition", %{"action" => a}), do: a

  defp summarize_tool(_name, _args), do: nil

  defp trunc_text(text) do
    if String.length(text) > @max_summary_len,
      do: String.slice(text, 0, @max_summary_len) <> "…",
      else: text
  end

  # -- Help Formatting --

  def format_help(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &format_help_line/1)
  end

  # -- Doctor Report Formatting --

  def format_doctor_report(results) do
    lines =
      Enum.map(results, fn %{check: name, status: status, message: msg} ->
        icon = status_icon(status)
        "  #{icon} #{c(ANSI.bright(), to_string(name))}: #{msg}"
      end)

    header = "\n  #{c(ANSI.cyan() <> ANSI.bright(), "Traitee Doctor")}"
    divider = "  #{c(ANSI.faint(), String.duplicate("═", 23))}"
    summary = format_summary(results)

    Enum.join([header, divider | lines] ++ ["", "  #{summary}", ""], "\n")
  end

  def status_icon(:ok), do: c(ANSI.green(), "✓")
  def status_icon(:warning), do: c(ANSI.yellow(), "⚠")
  def status_icon(:error), do: c(ANSI.red(), "✘")

  # -- Private: Logo --

  def logo do
    gradient = [
      ANSI.light_cyan(),
      ANSI.light_cyan(),
      ANSI.cyan(),
      ANSI.cyan(),
      ANSI.blue(),
      ANSI.blue()
    ]

    lines = logo_lines()

    Enum.zip(gradient, lines)
    |> Enum.map_join("\n", fn {color, line} -> "#{color}#{line}#{ANSI.reset()}" end)
  end

  defp logo_lines do
    [
      " ████████╗██████╗  █████╗ ██╗████████╗███████╗███████╗",
      " ╚══██╔══╝██╔══██╗██╔══██╗██║╚══██╔══╝██╔════╝██╔════╝",
      "    ██║   ██████╔╝███████║██║   ██║   █████╗  █████╗  ",
      "    ██║   ██╔══██╗██╔══██║██║   ██║   ██╔══╝  ██╔══╝  ",
      "    ██║   ██║  ██║██║  ██║██║   ██║   ███████╗███████╗",
      "    ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚══════╝"
    ]
  end

  defp tagline do
    v = version()
    c(ANSI.faint(), "          Compact AI Operating System · v#{v}")
  end

  # -- Private: Sections --

  defp tools_section(tools) do
    tool_set = MapSet.new(tools)

    lines =
      @tool_categories
      |> Enum.map(fn {cat, names} ->
        enabled = Enum.filter(names, &MapSet.member?(tool_set, &1))
        if enabled != [], do: tool_category_line(cat, enabled)
      end)
      |> Enum.reject(&is_nil/1)

    known = @tool_categories |> Enum.flat_map(fn {_, names} -> names end) |> MapSet.new()
    dynamic = Enum.reject(tools, &MapSet.member?(known, &1))
    lines = if dynamic != [], do: lines ++ [tool_category_line("dynamic", dynamic)], else: lines

    content =
      if lines == [],
        do: "    #{c(ANSI.faint(), "(none)")}",
        else: Enum.join(lines, "\n")

    [section_header("Available Tools"), content]
  end

  defp skills_section(skills) do
    content =
      if skills == [] do
        "    #{c(ANSI.faint(), "(none)")}"
      else
        "    " <> Enum.map_join(skills, ", ", &c(ANSI.magenta(), &1))
      end

    [section_header("Available Skills"), content]
  end

  defp session_section(session_id, model) do
    [
      section_header("Session"),
      "    #{c(ANSI.bright(), "Model")}:    #{model}",
      "    #{c(ANSI.bright(), "Session")}:  #{session_id}",
      "    #{c(ANSI.bright(), "Channel")}:  cli"
    ]
  end

  defp server_section(port) do
    [
      section_header("Server"),
      "    #{c(ANSI.bright(), "Port")}:     #{port}",
      "    #{c(ANSI.bright(), "WebChat")}:  http://localhost:#{port}/ws",
      "    #{c(ANSI.bright(), "API")}:      http://localhost:#{port}/api",
      "    #{c(ANSI.bright(), "Health")}:   http://localhost:#{port}/api/health"
    ]
  end

  defp channels_section(channels) do
    [section_header("Channels"), "    #{channels}"]
  end

  defp model_section(model) do
    [section_header("Model"), "    #{model}"]
  end

  defp counts_line(tools, skills) do
    tc = length(tools)
    sc = length(skills)
    ["", c(ANSI.faint(), "  #{tc} tools · #{sc} skills · /help for commands")]
  end

  defp cognition_section do
    enabled = Traitee.Config.get([:cognition, :enabled]) != false

    if enabled do
      autonomy = Traitee.Config.get([:cognition, :autonomy_level]) || "build"
      dream_interval = Traitee.Config.get([:cognition, :dream_interval_minutes]) || 120

      modules =
        ["dream", "workshop", "qc", "metacognition", "user_model"]
        |> Enum.map_join(", ", &c(ANSI.magenta(), &1))

      [
        section_header("Cognition"),
        "    #{c(ANSI.bright(), "Modules")}:   #{modules}",
        "    #{c(ANSI.bright(), "Autonomy")}:  #{autonomy}",
        "    #{c(ANSI.bright(), "Dream")}:     every #{dream_interval}m when idle"
      ]
    else
      [
        section_header("Cognition"),
        "    #{c(ANSI.faint(), "(disabled)")}"
      ]
    end
  rescue
    _ ->
      [
        section_header("Cognition"),
        "    #{c(ANSI.faint(), "(not loaded)")}"
      ]
  end

  # -- Private: Formatting Helpers --

  defp section_header(title) do
    dash_count = max(@panel_width - 6 - String.length(title), 3)

    "  " <>
      c(ANSI.faint(), "──") <>
      " " <>
      c(ANSI.yellow() <> ANSI.bright(), title) <>
      " " <>
      c(ANSI.faint(), String.duplicate("─", dash_count))
  end

  defp tool_category_line(category, tools) do
    padded = String.pad_trailing(category, 10)
    tool_list = Enum.join(tools, ", ")
    "    #{c(ANSI.green(), padded)} #{tool_list}"
  end

  defp format_help_line("Commands:" <> _) do
    "\n" <> section_header("Commands")
  end

  defp format_help_line(line) do
    case Regex.run(~r{^(/\S+)\s+—\s+(.*)$}, line) do
      [_, cmd, desc] ->
        padded = String.pad_trailing(cmd, 12)
        "    #{c(ANSI.cyan(), padded)} #{c(ANSI.faint(), desc)}"

      _ ->
        if String.trim(line) == "", do: "", else: "    #{line}"
    end
  end

  defp c(color, text), do: "#{color}#{text}#{ANSI.reset()}"

  # -- Private: Data Gathering --

  defp version do
    case Application.spec(:traitee, :vsn) do
      nil -> "0.1.0"
      vsn -> to_string(vsn)
    end
  end

  defp warnings(config) do
    issues = []

    issues =
      if get_in(config, [:agent, :model]) == nil,
        do: ["No LLM model configured — run 'mix traitee.onboard'" | issues],
        else: issues

    issues =
      if get_in(config, [:tools, :web_search, :enabled]) &&
           !get_in(config, [:tools, :web_search, :api_key]),
         do: ["Web search enabled but missing API key" | issues],
         else: issues

    if issues == [] do
      nil
    else
      header = "\n  #{c(ANSI.yellow(), "⚠ Warnings:")}"
      lines = Enum.map(issues, &"    • #{&1}")
      Enum.join([header | lines], "\n")
    end
  end

  defp format_summary(results) do
    counts = Enum.frequencies_by(results, & &1.status)
    ok = Map.get(counts, :ok, 0)
    warn = Map.get(counts, :warning, 0)
    err = Map.get(counts, :error, 0)

    if err > 0,
      do: c(ANSI.red(), "#{ok} passed, #{warn} warnings, #{err} errors"),
      else: c(ANSI.green(), "#{ok} passed, #{warn} warnings — system healthy")
  end

  defp gather_tools do
    Traitee.Tools.Registry.tool_schemas()
    |> Enum.map(fn
      %{"function" => %{"name" => name}} -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  defp gather_skills do
    Traitee.Skills.Loader.scan()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  defp safe_config do
    Traitee.Config.all()
  rescue
    _ -> %{}
  end

  defp get_port do
    endpoint_config = Application.get_env(:traitee, TraiteeWeb.Endpoint, [])
    get_in(endpoint_config, [:http, :port]) || 4000
  end

  defp format_channels(config) do
    channels = Map.get(config, :channels, %{})

    enabled =
      channels
      |> Enum.filter(fn {_name, opts} -> opts[:enabled] end)
      |> Enum.map(fn {name, _} -> to_string(name) end)
      |> Enum.sort()

    case enabled do
      [] -> c(ANSI.faint(), "none")
      list -> Enum.join(list, ", ")
    end
  end
end
