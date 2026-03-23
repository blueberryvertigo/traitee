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

  require Logger

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

    session_id = opts[:session] || default_session_id()
    {:ok, pid} = Session.ensure_started(session_id, :cli)

    IO.puts(Display.chat_banner(session_id))
    loop(session_id, pid, opts)
  end

  defp loop(session_id, pid, opts) do
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
            IO.write(Display.assistant_prefix())

            case SessionServer.send_message(pid, input, :cli) do
              {:ok, response} ->
                IO.puts(response)

              {:error, reason} ->
                IO.puts(Display.error_msg(inspect(reason)))
            end

            IO.puts("")
            loop(session_id, pid, opts)
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

  defp handle_command("/help" <> _, session_id, pid, _opts) do
    help = CommandRegistry.help_text()
    IO.puts(Display.format_help(help <> "\n/quit — Exit the REPL"))
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
