defmodule Traitee.Process.Executor do
  @moduledoc "Process execution with Windows support, timeouts, and output capture."

  @default_timeout 30_000
  @default_max_output 100_000

  @spec run(String.t(), keyword()) ::
          {:ok, %{stdout: String.t(), stderr: String.t(), exit_code: non_neg_integer()}}
          | {:error, term()}
  def run(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    max_output = Keyword.get(opts, :max_output_bytes, @default_max_output)
    working_dir = Keyword.get(opts, :working_dir)
    env = Keyword.get(opts, :env, [])

    {shell, args} = shell_command(command)

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, {:args, args}] ++
        if(env != [], do: [{:env, env}], else: []) ++
        if(working_dir, do: [{:cd, String.to_charlist(working_dir)}], else: [])

    try do
      port = Port.open({:spawn_executable, shell}, port_opts)

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      collect_output(port, os_pid, timeout, max_output)
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @spec run_async(String.t(), keyword()) :: {:ok, pid()}
  def run_async(command, opts \\ []) do
    caller = self()

    pid =
      spawn(fn ->
        result = run(command, opts)
        send(caller, {:process_result, self(), result})
      end)

    {:ok, pid}
  end

  @spec kill(port() | pid()) :: :ok
  def kill(port) when is_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    :ok
  end

  def kill(pid) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  @spec kill_tree(non_neg_integer()) :: :ok
  def kill_tree(os_pid) when is_integer(os_pid) do
    if windows?() do
      safe_cmd("taskkill", ["/PID", to_string(os_pid), "/T", "/F"])
    else
      unix_kill_tree(os_pid)
    end

    :ok
  rescue
    _ -> :ok
  end

  # The spawned shell is usually NOT a process-group leader, so a group
  # kill alone can be a no-op. Kill direct children first (pgrep -P),
  # then the pid itself, then try the group as a best-effort sweep.
  # `--` stops /bin/kill from parsing "-<pid>" as an option flag.
  defp unix_kill_tree(os_pid) do
    pid_str = to_string(os_pid)

    case safe_cmd("pgrep", ["-P", pid_str]) do
      {out, 0} ->
        out
        |> String.split(~r/\s+/, trim: true)
        |> Enum.each(fn child -> safe_cmd("kill", ["-9", "--", child]) end)

      _ ->
        :ok
    end

    safe_cmd("kill", ["-9", "--", pid_str])
    safe_cmd("kill", ["-9", "--", "-#{pid_str}"])
    :ok
  end

  defp safe_cmd(cmd, args) do
    System.cmd(cmd, args, stderr_to_stdout: true)
  rescue
    _ -> {"", 1}
  end

  @spec windows?() :: boolean()
  def windows? do
    case :os.type() do
      {:win32, _} -> true
      _ -> false
    end
  end

  @spec shell() :: String.t()
  def shell do
    if windows?(), do: "cmd.exe", else: "/bin/sh"
  end

  defp shell_command(command) do
    if windows?() do
      cmd = System.find_executable("cmd.exe") || "cmd.exe"
      {String.to_charlist(cmd), ["/c", command]}
    else
      sh = System.find_executable("sh") || "/bin/sh"
      {String.to_charlist(sh), ["-c", command]}
    end
  end

  defp collect_output(port, os_pid, timeout, max_output) do
    ctx = %{
      port: port,
      os_pid: os_pid,
      timeout: timeout,
      max_output: max_output,
      start_time: System.monotonic_time(:millisecond)
    }

    collect_loop(ctx, [], 0)
  end

  defp collect_loop(ctx, acc, size) do
    %{port: port, max_output: max_output} = ctx
    elapsed = System.monotonic_time(:millisecond) - ctx.start_time
    remaining = max(ctx.timeout - elapsed, 0)

    receive do
      {^port, {:data, data}} ->
        new_size = size + byte_size(data)

        if new_size > max_output do
          terminate_port(port, ctx.os_pid)

          output = IO.iodata_to_binary(Enum.reverse([data | acc]))
          truncated = truncate_utf8(output, max_output)

          {:ok,
           %{
             stdout: truncated <> "\n... [truncated: max output exceeded; process killed]",
             stderr: "",
             exit_code: 1
           }}
        else
          collect_loop(ctx, [data | acc], new_size)
        end

      {^port, {:exit_status, code}} ->
        output = IO.iodata_to_binary(Enum.reverse(acc))
        {:ok, %{stdout: output, stderr: "", exit_code: code}}
    after
      remaining ->
        terminate_port(port, ctx.os_pid)
        {:error, :timeout}
    end
  end

  # Kill the whole OS process tree (Port.close alone leaves the spawned
  # shell and its descendants running as zombies), close the port, and
  # flush any residual port messages so they can't leak into the caller's
  # mailbox.
  defp terminate_port(port, os_pid) do
    if os_pid, do: kill_tree(os_pid)

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    flush_port_messages(port)
  end

  defp flush_port_messages(port) do
    receive do
      {^port, _} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end

  # Slice to at most `max` bytes without splitting a UTF-8 codepoint:
  # back the cut point up while the byte at the boundary is a
  # continuation byte (0b10xxxxxx). Capped at 3 steps (max sequence is
  # 4 bytes) so invalid binary data can't trigger a long walk.
  defp truncate_utf8(binary, max) when byte_size(binary) <= max, do: binary

  defp truncate_utf8(binary, max) do
    binary_part(binary, 0, utf8_safe_cut(binary, max, 0))
  end

  defp utf8_safe_cut(_binary, len, _steps) when len <= 0, do: 0

  defp utf8_safe_cut(binary, len, steps) when steps < 3 do
    byte = :binary.at(binary, len)

    if byte >= 0x80 and byte <= 0xBF do
      utf8_safe_cut(binary, len - 1, steps + 1)
    else
      len
    end
  end

  defp utf8_safe_cut(_binary, len, _steps), do: len
end
