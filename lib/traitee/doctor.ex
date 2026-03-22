defmodule Traitee.Doctor do
  @moduledoc "System diagnostics and health checks."

  import Ecto.Query

  @critical_checks [:database, :llm_provider]

  @spec run_all() :: [map()]
  def run_all do
    [
      check_elixir_version(),
      check_database(),
      check_llm_provider(),
      check_memory_system(),
      check_channels(),
      check_workspace(),
      check_disk_space(),
      check_config(),
      check_sessions(),
      check_security()
    ]
  end

  @spec healthy?() :: boolean()
  def healthy? do
    run_all()
    |> Enum.filter(fn %{check: name} -> name in @critical_checks end)
    |> Enum.all?(fn %{status: s} -> s == :ok end)
  end

  @spec format_report([map()]) :: String.t()
  def format_report(results) do
    lines =
      Enum.map(results, fn %{check: name, status: status, message: msg} ->
        icon = status_icon(status)
        "  #{icon} #{name}: #{msg}"
      end)

    header = "\n  Traitee Doctor\n  ═══════════════════════"
    summary = summarize(results)

    Enum.join([header | lines] ++ ["", "  #{summary}", ""], "\n")
  end

  # -- Checks --

  defp check_elixir_version do
    version = System.version()

    status =
      case Version.compare(version, "1.17.0") do
        :lt -> :error
        _ -> :ok
      end

    result(:elixir_version, status, "Elixir #{version}")
  end

  defp check_database do
    case Traitee.Repo.query("SELECT 1") do
      {:ok, _} -> result(:database, :ok, "SQLite connected")
      {:error, reason} -> result(:database, :error, "SQLite error: #{inspect(reason)}")
    end
  rescue
    e -> result(:database, :error, "SQLite error: #{Exception.message(e)}")
  end

  defp check_llm_provider do
    config = Traitee.Config.all()
    agent = Map.get(config, :agent, %{})

    if agent[:model] do
      result(:llm_provider, :ok, "Model configured: #{agent[:model]}")
    else
      result(:llm_provider, :error, "No LLM model configured")
    end
  end

  defp check_memory_system do
    vector_count = Traitee.Memory.Vector.count()

    ets_tables =
      :ets.all()
      |> Enum.filter(fn t -> is_atom(t) and String.starts_with?(to_string(t), "traitee") end)

    result(
      :memory_system,
      :ok,
      "#{length(ets_tables)} ETS tables, #{vector_count} vectors indexed"
    )
  rescue
    _ -> result(:memory_system, :warning, "Could not inspect memory system")
  end

  defp check_channels do
    config = Traitee.Config.all()
    channels = Map.get(config, :channels, %{})

    enabled =
      channels
      |> Enum.filter(fn {_name, opts} -> opts[:enabled] end)
      |> Enum.map(fn {name, opts} ->
        has_token = opts[:token] != nil or name == :signal
        {name, has_token}
      end)

    case enabled do
      [] ->
        result(:channels, :warning, "No channels enabled")

      list ->
        missing = Enum.reject(list, fn {_, ok} -> ok end) |> Enum.map(fn {n, _} -> n end)

        if missing == [] do
          names = Enum.map_join(list, ", ", fn {n, _} -> n end)
          result(:channels, :ok, "Enabled: #{names}")
        else
          result(:channels, :warning, "Missing tokens for: #{Enum.join(missing, ", ")}")
        end
    end
  end

  defp check_workspace do
    dir = Traitee.data_dir()

    if File.dir?(dir) do
      result(:workspace, :ok, "Data dir exists: #{dir}")
    else
      result(:workspace, :error, "Data dir missing: #{dir}")
    end
  end

  defp check_disk_space do
    dir = Traitee.data_dir()

    case :os.type() do
      {:win32, _} ->
        result(:disk_space, :ok, "Disk check skipped on Windows")

      _ ->
        case System.cmd("df", ["-m", dir], stderr_to_stdout: true) do
          {output, 0} -> parse_disk_output(output, dir)
          _ -> result(:disk_space, :ok, "Could not check disk space")
        end
    end
  end

  defp parse_disk_output(output, dir) do
    lines = String.split(output, "\n", trim: true)

    if length(lines) >= 2 do
      parts = lines |> List.last() |> String.split(~r/\s+/, trim: true)
      avail = parts |> Enum.at(3, "0") |> String.to_integer()

      if avail < 100 do
        result(:disk_space, :warning, "Only #{avail}MB free in #{dir}")
      else
        result(:disk_space, :ok, "#{avail}MB free")
      end
    else
      result(:disk_space, :ok, "Could not parse disk info")
    end
  end

  defp check_config do
    config = Traitee.Config.all()

    warnings =
      []
      |> then(fn w ->
        if config[:agent][:system_prompt] == nil, do: ["no system prompt" | w], else: w
      end)
      |> then(fn w ->
        if config[:tools][:web_search][:enabled] && !config[:tools][:web_search][:api_key],
          do: ["web_search enabled but no API key" | w],
          else: w
      end)

    if warnings == [] do
      result(:config, :ok, "Config valid")
    else
      result(:config, :warning, Enum.join(warnings, "; "))
    end
  end

  defp check_sessions do
    active = Traitee.Session.list_active()
    count = length(active)

    db_active =
      Traitee.Memory.Schema.Session
      |> where([s], s.status == "active")
      |> Traitee.Repo.aggregate(:count, :id)

    orphaned = max(db_active - count, 0)

    msg = "#{count} active process(es), #{db_active} in DB"
    msg = if orphaned > 0, do: msg <> ", #{orphaned} potentially orphaned", else: msg
    status = if orphaned > 0, do: :warning, else: :ok

    result(:sessions, status, msg)
  rescue
    _ -> result(:sessions, :warning, "Could not inspect sessions")
  end

  defp check_security do
    warnings = []

    warnings =
      try do
        approved = Traitee.Security.Pairing.list_approved()
        if approved == [], do: ["no approved senders" | warnings], else: warnings
      rescue
        _ -> ["pairing not running" | warnings]
      end

    if warnings == [] do
      result(:security, :ok, "Pairing active with approved senders")
    else
      result(:security, :warning, Enum.join(warnings, "; "))
    end
  end

  # -- Helpers --

  defp result(check, status, message) do
    %{check: check, status: status, message: message}
  end

  defp status_icon(:ok), do: "[OK]"
  defp status_icon(:warning), do: "[WARN]"
  defp status_icon(:error), do: "[ERR]"

  defp summarize(results) do
    counts = Enum.frequencies_by(results, & &1.status)
    ok = Map.get(counts, :ok, 0)
    warn = Map.get(counts, :warning, 0)
    err = Map.get(counts, :error, 0)

    if err > 0 do
      "#{ok} passed, #{warn} warnings, #{err} errors — issues found"
    else
      "#{ok} passed, #{warn} warnings — system healthy"
    end
  end
end
