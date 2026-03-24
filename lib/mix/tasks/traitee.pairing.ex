defmodule Mix.Tasks.Traitee.Pairing do
  @moduledoc """
  Manage sender pairing from the command line.

      mix traitee.pairing list
      mix traitee.pairing add <channel> <sender_id>
      mix traitee.pairing remove <channel> <sender_id>
      mix traitee.pairing approve <code>

  Channel is one of: telegram, discord, whatsapp, signal, webchat
  """
  use Mix.Task

  @shortdoc "Manage sender pairing (add/remove/list/approve)"
  @approved_file "approved_senders.json"
  @pending_file "pending_pairings.json"
  @valid_channels ~w(telegram discord whatsapp signal webchat)

  @impl true
  def run(args) do
    case args do
      ["add", channel, sender_id] when channel in @valid_channels ->
        run_add(channel, sender_id)

      ["add", _channel, _sender_id] ->
        IO.puts("Unknown channel. Valid channels: #{Enum.join(@valid_channels, ", ")}")

      ["remove", channel, sender_id] when channel in @valid_channels ->
        run_remove(channel, sender_id)

      ["approve", code] ->
        run_approve(code)

      ["list"] ->
        run_list()

      _ ->
        print_usage()
    end
  end

  defp run_add(channel, sender_id) do
    key = "#{channel}:#{sender_id}"
    approved = load_approved()
    updated = Enum.uniq([key | approved])
    save_approved(updated)
    IO.puts("Approved #{sender_id} on #{channel}")
    IO.puts("Restart the bot for changes to take effect.")
  end

  defp run_remove(channel, sender_id) do
    key = "#{channel}:#{sender_id}"
    approved = load_approved()
    updated = List.delete(approved, key)
    save_approved(updated)
    IO.puts("Removed #{sender_id} from #{channel}")
    IO.puts("Restart the bot for changes to take effect.")
  end

  defp run_approve(code) do
    pending = load_pending()

    case Map.pop(pending, code) do
      {nil, _} ->
        IO.puts("No pending pairing found for code: #{code}")

      {entry, remaining} ->
        key = entry["key"]
        approved = load_approved()
        updated = Enum.uniq([key | approved])
        save_approved(updated)
        save_pending(remaining)
        IO.puts("Approved #{entry["sender_id"]} on #{entry["channel"]}")
        IO.puts("Restart the bot for changes to take effect.")
    end
  end

  defp run_list do
    approved = load_approved()
    IO.puts("Approved senders (#{length(approved)}):")

    if approved == [] do
      IO.puts("  (none)")
    else
      Enum.each(approved, fn key ->
        case String.split(key, ":", parts: 2) do
          [channel, id] -> IO.puts("  #{id} [#{channel}]")
          _ -> IO.puts("  #{key}")
        end
      end)
    end

    pending = load_pending()

    if pending != %{} do
      IO.puts("\nPending codes (#{map_size(pending)}):")

      Enum.each(pending, fn {code, entry} ->
        IO.puts("  #{code} — #{entry["sender_id"]} [#{entry["channel"]}]")
      end)
    end
  end

  defp print_usage do
    IO.puts("""
    Usage:
      mix traitee.pairing list                          - Show approved & pending senders
      mix traitee.pairing add <channel> <sender_id>     - Approve a sender
      mix traitee.pairing remove <channel> <sender_id>  - Revoke a sender
      mix traitee.pairing approve <code>                - Approve a pairing code

    Channels: #{Enum.join(@valid_channels, ", ")}

    Example:
      mix traitee.pairing add telegram 7886908010
      mix traitee.pairing approve ffm27w
    """)
  end

  defp data_dir do
    System.get_env("TRAITEE_DATA_DIR") || Path.expand("~/.traitee")
  end

  defp approved_path, do: Path.join(data_dir(), @approved_file)
  defp pending_path, do: Path.join(data_dir(), @pending_file)

  defp load_approved do
    case File.read(approved_path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  defp save_approved(list) do
    path = approved_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(list))
  end

  defp load_pending do
    case File.read(pending_path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp save_pending(map) do
    path = pending_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map))
  end
end
