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
      collect_output(port, timeout, max_output)
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
      System.cmd("taskkill", ["/PID", to_string(os_pid), "/T", "/F"], stderr_to_stdout: true)
    else
      System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
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

  defp collect_output(port, timeout, max_output) do
    collect_output(port, timeout, max_output, [], 0, System.monotonic_time(:millisecond))
  end

  defp collect_output(port, timeout, max_output, acc, size, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    remaining = max(timeout - elapsed, 0)

    receive do
      {^port, {:data, data}} ->
        new_size = size + byte_size(data)

        if new_size > max_output do
          try do
            Port.close(port)
          rescue
            _ -> :ok
          end

          output = IO.iodata_to_binary(Enum.reverse([data | acc]))
          truncated = binary_part(output, 0, min(byte_size(output), max_output))

          {:ok,
           %{
             stdout: truncated <> "\n... (truncated)",
             stderr: "",
             exit_code: 1
           }}
        else
          collect_output(port, timeout, max_output, [data | acc], new_size, start_time)
        end

      {^port, {:exit_status, code}} ->
        output = IO.iodata_to_binary(Enum.reverse(acc))
        {:ok, %{stdout: output, stderr: "", exit_code: code}}
    after
      remaining ->
        try do
          Port.close(port)
        rescue
          _ -> :ok
        end

        {:error, :timeout}
    end
  end
end
