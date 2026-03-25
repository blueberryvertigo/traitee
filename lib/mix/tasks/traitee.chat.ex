defmodule Mix.Tasks.Traitee.Chat do
  @moduledoc """
  Interactive REPL for chatting with the AI assistant.
  Uses the full session pipeline (tools, memory, context engine).

      mix traitee.chat
      mix traitee.chat --session my-session

  Type /help inside the REPL to see available commands.
  """
  use Mix.Task

  alias Traitee.AutoReply.CommandRegistry
  alias Traitee.CLI.Display
  alias Traitee.Session
  alias Traitee.Session.Server, as: SessionServer
  alias Traitee.Tools.TaskTracker

  require Logger

  @progress_timeout 60_000

  @shortdoc "Start an interactive chat REPL"

  @impl true
  def run(args) do
    Application.put_env(:traitee, :skip_channel_polling, true)
    Mix.Task.run("app.start")
    ensure_migrated()

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [session: :string],
        aliases: [s: :session]
      )

    Logger.configure(level: :warning)

    session_id = opts[:session] || default_session_id()
    {:ok, pid} = Session.ensure_started(session_id, :cli)

    IO.puts(Display.chat_banner(session_id))
    loop(session_id, pid, opts)
  end

  defp loop(session_id, pid, opts) do
    maybe_show_delegation_results(pid)

    case IO.gets(Display.user_prompt()) do
      :eof ->
        IO.puts(Display.goodbye())
        Session.terminate(session_id)

      input ->
        input = String.trim(input)

        cond do
          input == "" ->
            loop(session_id, pid, opts)

          String.starts_with?(input, "/") ->
            {session_id, pid} = handle_command(input, session_id, pid, opts)
            loop(session_id, pid, opts)

          true ->
            ref = SessionServer.send_message_streaming(pid, input, :cli)
            mon = Process.monitor(pid)

            case await_streaming_response(ref, mon, session_id) do
              {:ok, response} ->
                Process.demonitor(mon, [:flush])
                IO.write(Display.assistant_prefix())
                IO.puts("#{IO.ANSI.white()}#{response}#{IO.ANSI.reset()}")
                IO.puts("")
                loop(session_id, pid, opts)

              {:error, reason} ->
                Process.demonitor(mon, [:flush])
                IO.puts(Display.error_msg(inspect(reason)))
                IO.puts("")
                loop(session_id, pid, opts)

              :timeout ->
                Process.demonitor(mon, [:flush])
                IO.puts(Display.error_msg("Response timed out (no activity)."))
                IO.puts("")
                loop(session_id, pid, opts)

              {:crashed, reason} ->
                IO.puts(Display.error_msg("Session crashed: #{inspect(reason)}"))
                {:ok, new_pid} = Session.ensure_started(session_id, :cli)
                IO.puts("")
                loop(session_id, new_pid, opts)
            end
        end
    end
  end

  defp handle_command("/quit", session_id, _pid, _opts) do
    Session.terminate(session_id)
    IO.puts(Display.goodbye())
    System.halt(0)
  end

  defp handle_command("/new" <> _, old_session_id, _old_pid, _opts) do
    Session.terminate(old_session_id)
    new_session_id = default_session_id()
    {:ok, new_pid} = Session.ensure_started(new_session_id, :cli)
    IO.puts(Display.system_msg("Conversation reset."))
    {new_session_id, new_pid}
  end

  defp handle_command("/threats" <> _, session_id, pid, _opts) do
    alias Traitee.Security.{Cognitive, SystemAuth, ThreatTracker}

    summary = ThreatTracker.summary(session_id)
    events = ThreatTracker.events(session_id)
    has_threats = events != []

    IO.puts(Display.system_msg(summary))

    if has_threats do
      IO.puts("  #{IO.ANSI.faint()}Recent events:#{IO.ANSI.reset()}")

      events
      |> Enum.take(-5)
      |> Enum.each(fn %{threat: t} ->
        IO.puts(
          "  #{IO.ANSI.faint()}[#{t.severity}] #{t.pattern_name} — #{t.category}#{IO.ANSI.reset()}"
        )
      end)
    end

    state = SessionServer.get_state(pid)
    msg_count = state[:message_count] || 0

    reminders =
      if Cognitive.enabled?() do
        Cognitive.reminders_for(session_id,
          message_count: msg_count,
          has_recent_threats: has_threats
        )
      else
        []
      end

    tagged_reminders = Enum.map(reminders, &SystemAuth.tag_message(&1, session_id))

    if tagged_reminders != [] do
      IO.puts("")

      IO.puts(
        "  #{IO.ANSI.faint()}Injected system messages (#{length(tagged_reminders)}):#{IO.ANSI.reset()}"
      )

      Enum.each(tagged_reminders, fn r ->
        preview = String.slice(r.content, 0, 150)
        IO.puts("  #{IO.ANSI.faint()}#{IO.ANSI.yellow()}→ #{preview}...#{IO.ANSI.reset()}")
      end)
    else
      IO.puts("")

      IO.puts(
        "  #{IO.ANSI.faint()}No security reminders injected at current state.#{IO.ANSI.reset()}"
      )
    end

    {session_id, pid}
  end

  defp handle_command("/help" <> _, session_id, pid, _opts) do
    help = CommandRegistry.help_text()

    IO.puts(
      Display.format_help(
        help <> "\n/threats — Show threat level and recent events\n/quit — Exit the REPL"
      )
    )

    {session_id, pid}
  end

  defp handle_command(input, session_id, pid, _opts) do
    owner_id = Traitee.Config.get([:security, :owner_id]) || session_id

    context = %{
      inbound: %{sender_id: owner_id, channel_type: :cli},
      session_pid: pid
    }

    case CommandRegistry.execute(input, context) do
      {:ok, text} ->
        IO.puts(Display.system_msg(text))

      {:error, :unknown_command} ->
        IO.puts(Display.system_msg("Unknown command: #{input}. Type /help for commands."))

      {:error, reason} ->
        IO.puts(Display.error_msg(inspect(reason)))
    end

    {session_id, pid}
  end

  defp await_streaming_response(ref, mon, session_id) do
    receive do
      {:session_progress, ^ref, _info} ->
        await_streaming_response(ref, mon, session_id)

      {:session_response, ^ref, result} ->
        result

      {:DOWN, ^mon, :process, _pid, reason} ->
        {:crashed, reason}
    after
      @progress_timeout ->
        if has_active_tasks?(session_id) do
          IO.puts(
            "#{IO.ANSI.faint()}#{IO.ANSI.blue()}  ⏳ Tasks in progress, still waiting...#{IO.ANSI.reset()}"
          )

          await_streaming_response(ref, mon, session_id)
        else
          :timeout
        end
    end
  end

  defp has_active_tasks?(session_id) do
    TaskTracker.active_tasks(session_id) != []
  rescue
    _ -> false
  end

  defp maybe_show_delegation_results(pid) do
    case SessionServer.pop_delegation_results(pid) do
      {[], _expected} ->
        :ok

      {results, expected} ->
        threshold = max(ceil(expected / 2), 1)
        total = expected + length(results)

        if length(results) >= threshold do
          IO.puts(
            Display.system_msg(
              "Subagent results received (#{length(results)}/#{total}). " <>
                "Results are in context — ask me about them."
            )
          )

          IO.puts("")
        end
    end
  end

  defp ensure_migrated do
    migrations_path = Path.join(:code.priv_dir(:traitee), "repo/migrations")
    Ecto.Migrator.run(Traitee.Repo, migrations_path, :up, all: true, log: false)
  end

  defp default_session_id do
    case Traitee.Config.get([:security, :owner_id]) do
      nil -> "chat-#{System.os_time(:millisecond)}"
      "" -> "chat-#{System.os_time(:millisecond)}"
      owner_id -> "default:#{owner_id}"
    end
  end
end
