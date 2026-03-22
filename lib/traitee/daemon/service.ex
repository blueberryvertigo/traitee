defmodule Traitee.Daemon.Service do
  @moduledoc "Cross-platform daemon management for running Traitee as a background service."

  alias Traitee.Daemon.Windows

  require Logger

  @spec install(keyword()) :: :ok | {:error, term()}
  def install(opts \\ []) do
    case platform() do
      :windows -> Windows.install(opts)
      :linux -> install_systemd(opts)
      :macos -> install_launchd(opts)
    end
  end

  @spec uninstall() :: :ok | {:error, term()}
  def uninstall do
    case platform() do
      :windows -> Windows.uninstall()
      :linux -> uninstall_systemd()
      :macos -> uninstall_launchd()
    end
  end

  @spec start() :: :ok | {:error, term()}
  def start do
    case platform() do
      :windows -> Windows.start()
      :linux -> systemctl("start")
      :macos -> launchctl(["load", launchd_plist_path()])
    end
  end

  @spec stop() :: :ok | {:error, term()}
  def stop do
    case platform() do
      :windows -> Windows.stop()
      :linux -> systemctl("stop")
      :macos -> launchctl(["unload", launchd_plist_path()])
    end
  end

  @spec status() :: :running | :stopped | :not_installed
  def status do
    case platform() do
      :windows -> Windows.status()
      :linux -> systemd_status()
      :macos -> launchd_status()
    end
  end

  @spec platform() :: :windows | :linux | :macos
  def platform do
    case :os.type() do
      {:win32, _} -> :windows
      {:unix, :darwin} -> :macos
      {:unix, _} -> :linux
    end
  end

  # -- Linux (systemd) --

  defp systemd_unit_dir, do: Path.expand("~/.config/systemd/user")
  defp systemd_unit_path, do: Path.join(systemd_unit_dir(), "traitee.service")

  defp install_systemd(_opts) do
    elixir = System.find_executable("elixir") || "elixir"
    project_dir = File.cwd!()

    unit = """
    [Unit]
    Description=Traitee Gateway
    After=network.target

    [Service]
    Type=simple
    WorkingDirectory=#{project_dir}
    ExecStart=#{elixir} -S mix traitee.serve
    Restart=on-failure
    RestartSec=5

    [Install]
    WantedBy=default.target
    """

    File.mkdir_p!(systemd_unit_dir())
    File.write!(systemd_unit_path(), unit)
    systemctl("daemon-reload")
    systemctl("enable")
  end

  defp uninstall_systemd do
    systemctl("stop")
    systemctl("disable")
    File.rm(systemd_unit_path())
    systemctl("daemon-reload")
  end

  defp systemctl(action) do
    case System.cmd("systemctl", ["--user", action, "traitee"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp systemd_status do
    case System.cmd("systemctl", ["--user", "is-active", "traitee"], stderr_to_stdout: true) do
      {"active\n", 0} -> :running
      {"inactive\n", _} -> :stopped
      _ -> :not_installed
    end
  end

  # -- macOS (launchd) --

  defp launchd_plist_path, do: Path.expand("~/Library/LaunchAgents/com.traitee.gateway.plist")

  defp install_launchd(_opts) do
    elixir = System.find_executable("elixir") || "elixir"
    project_dir = File.cwd!()

    plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>com.traitee.gateway</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{elixir}</string>
        <string>-S</string>
        <string>mix</string>
        <string>traitee.serve</string>
      </array>
      <key>WorkingDirectory</key>
      <string>#{project_dir}</string>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>StandardOutPath</key>
      <string>#{Traitee.data_dir()}/traitee.log</string>
      <key>StandardErrorPath</key>
      <string>#{Traitee.data_dir()}/traitee.err</string>
    </dict>
    </plist>
    """

    File.write!(launchd_plist_path(), plist)
    launchctl(["load", launchd_plist_path()])
  end

  defp uninstall_launchd do
    launchctl(["unload", launchd_plist_path()])
    File.rm(launchd_plist_path())
    :ok
  end

  defp launchctl(args) do
    case System.cmd("launchctl", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp launchd_status do
    case System.cmd("launchctl", ["list", "com.traitee.gateway"], stderr_to_stdout: true) do
      {out, 0} -> if out =~ ~r/PID\s*=\s*\d+/, do: :running, else: :stopped
      _ -> :not_installed
    end
  end
end
