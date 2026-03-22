defmodule Mix.Tasks.Traitee.Security do
  @moduledoc """
  Filesystem security posture audit.

  Inspects the current security configuration and reports on:
  - Sandbox mode status
  - Filesystem allow/deny rules
  - Default access policy
  - Docker isolation status
  - Exec approval gates
  - Audit trail summary
  - Detected security gaps

  ## Usage

      mix traitee.security              # Full posture audit
      mix traitee.security --audit      # Show recent audit trail
      mix traitee.security --gaps       # Show only security gaps
      mix traitee.security --rules      # Show all active rules
      mix traitee.security --test PATH  # Test a path against current policy
  """
  use Mix.Task

  alias Traitee.Security.{Audit, ExecGate, Filesystem, Sandbox}

  @shortdoc "Audit filesystem security posture"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _} =
      OptionParser.parse(args,
        switches: [audit: :boolean, gaps: :boolean, rules: :boolean, test: :string],
        aliases: [a: :audit, g: :gaps, r: :rules, t: :test]
      )

    cond do
      opts[:audit] ->
        print_audit_trail()

      opts[:gaps] ->
        print_gaps()

      opts[:rules] ->
        print_rules()

      opts[:test] ->
        test_path(opts[:test])

      rest != [] ->
        test_path(List.first(rest))

      true ->
        print_full_posture()
    end
  end

  defp print_full_posture do
    posture = Sandbox.posture()

    IO.puts("""

      Traitee Filesystem Security Audit
      ══════════════════════════════════════

      Sandbox Mode
      ────────────────────────
      Enabled:          #{bool_icon(posture.sandbox_mode)}
      Default policy:   #{posture.default_policy}
      Working dir:      #{posture.working_dir}

      Filesystem Rules
      ────────────────────────
      Allow rules:      #{posture.allow_rules_count}
      Deny rules:       #{posture.deny_rules_count}
      Hardcoded deny:   #{posture.hardcoded_deny_count} path patterns
      Command deny:     #{posture.hardcoded_command_deny_count} hardcoded + #{posture.command_deny_count} configured

      Docker Isolation
      ────────────────────────
      Enabled:          #{bool_icon(posture.docker.enabled)}
      Available:        #{bool_icon(posture.docker.available)}
      Image:            #{posture.docker.image}
      Network:          #{posture.docker.network}
      Memory limit:     #{posture.docker.memory}
      CPU limit:        #{posture.docker.cpus}
      Status:           #{posture.docker.status}

      Exec Approval Gates
      ────────────────────────
      Enabled:          #{bool_icon(posture.exec_gate_enabled)}
      Active rules:     #{length(posture.exec_gate_rules)}
    #{format_exec_rules(posture.exec_gate_rules)}
      Audit Trail
      ────────────────────────
      Total events:     #{posture.audit.total_events}
      Deny decisions:   #{posture.audit.decisions[:deny] || 0}
      Allow decisions:  #{posture.audit.decisions[:allow] || 0}
      Denial rate:      #{posture.audit.denial_rate}

      Security Gaps
      ────────────────────────
    #{format_gaps(posture.gaps)}
    """)
  end

  defp print_audit_trail do
    IO.puts(Audit.format_report())
  end

  defp print_gaps do
    posture = Filesystem.posture_summary()

    IO.puts("""

      Security Gaps
      ══════════════════════════════════════
    #{format_gaps(posture.gaps)}
    """)
  end

  defp print_rules do
    posture = Filesystem.posture_summary()

    IO.puts("""

      Filesystem Rules
      ══════════════════════════════════════

      Allow Rules:
    #{format_path_rules(posture.allow_rules, "allow")}

      Deny Rules:
    #{format_path_rules(posture.deny_rules, "deny")}

      Hardcoded Deny Patterns:
    #{format_list(Filesystem.hardcoded_deny_patterns())}

      Exec Gate Rules:
    #{format_exec_rules(ExecGate.active_rules())}
    """)
  end

  defp test_path(path) do
    expanded = Path.expand(path)

    read_result = Filesystem.check_path(expanded, operation: :read, tool: :audit_test)
    write_result = Filesystem.check_path(expanded, operation: :write, tool: :audit_test)
    exec_result = Filesystem.check_path(expanded, operation: :exec, tool: :audit_test)

    IO.puts("""

      Path Policy Test: #{expanded}
      ══════════════════════════════════════
      Read:    #{format_result(read_result)}
      Write:   #{format_result(write_result)}
      Exec:    #{format_result(exec_result)}
    """)
  end

  defp bool_icon(true), do: "[ON]  ✓"
  defp bool_icon(false), do: "[OFF]"
  defp bool_icon(_), do: "[?]"

  defp format_result(:ok), do: "[ALLOW]"
  defp format_result({:error, reason}), do: "[DENY]  #{reason}"

  defp format_gaps([]), do: "    (none — excellent security posture)"

  defp format_gaps(gaps) do
    gaps
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {gap, i} -> "    #{i}. #{gap}" end)
  end

  defp format_path_rules([], _type), do: "    (none configured)"

  defp format_path_rules(rules, _type) do
    Enum.map_join(rules, "\n", fn rule ->
      perms = (rule[:permissions] || [:read]) |> Enum.join(", ")
      "    #{rule.pattern}  [#{perms}]"
    end)
  end

  defp format_exec_rules([]), do: "    (none configured — using defaults)"

  defp format_exec_rules(rules) do
    Enum.map_join(rules, "\n", fn rule ->
      action = String.upcase(to_string(rule.action))
      "    [#{action}] #{rule.pattern} — #{rule.description}"
    end)
  end

  defp format_list(items) do
    Enum.map_join(items, "\n", fn item -> "    #{item}" end)
  end
end
