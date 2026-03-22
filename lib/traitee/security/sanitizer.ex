defmodule Traitee.Security.Sanitizer do
  @moduledoc """
  Input sanitization with severity-tiered threat classification.

  Detects prompt injection attempts across multiple categories and returns
  structured threat reports with severity levels for downstream handling.
  """

  defmodule Threat do
    @moduledoc false
    defstruct [:category, :severity, :pattern_name, :matched_text]

    @type t :: %__MODULE__{
            category: atom(),
            severity: :low | :medium | :high | :critical,
            pattern_name: String.t(),
            matched_text: String.t()
          }
  end

  @type threat_report :: %{
          sanitized: String.t(),
          threats: [Threat.t()],
          max_severity: :none | :low | :medium | :high | :critical
        }

  @severity_order %{none: 0, low: 1, medium: 2, high: 3, critical: 4}

  @patterns [
    # -- Critical: Direct instruction override --
    {~r/ignore\s+(all\s+)?(previous|prior|above)\s+(instructions|prompts|rules)/i,
     :instruction_override, :critical, "ignore previous instructions"},
    {~r/disregard\s+(all\s+)?(previous|prior|above)/i, :instruction_override, :critical,
     "disregard previous"},
    {~r/forget\s+(all\s+)?(previous|prior|above)\s+(instructions|context)/i,
     :instruction_override, :critical, "forget previous instructions"},
    {~r/override\s+(your|all|the)\s+(rules|instructions|guidelines|constraints)/i,
     :instruction_override, :critical, "override rules"},
    {~r/new\s+rules?\s*:/i, :instruction_override, :high, "new rules declaration"},

    # -- Critical: System prompt extraction --
    {~r/(repeat|show|display|print|output|reveal|dump|echo)\s+(your\s+)?(system\s+prompt|instructions|rules|original\s+prompt|initial\s+prompt|hidden\s+prompt)/i,
     :prompt_extraction, :critical, "reveal system prompt"},
    {~r/what\s+(are|were)\s+your\s+(original\s+)?(instructions|system\s+prompt|rules|guidelines)/i,
     :prompt_extraction, :critical, "query system prompt"},
    {~r/copy\s+(and\s+)?(paste|output)\s+(your|the)\s+(system|initial|original)/i,
     :prompt_extraction, :critical, "copy system prompt"},

    # -- High: System tag injection --
    {~r/<\/?system>/i, :tag_injection, :high, "XML system tag"},
    {~r/\[SYSTEM\]/i, :tag_injection, :high, "bracket system tag"},
    {~r/```system\b/i, :tag_injection, :high, "markdown system block"},
    {~r/<\/?(?:instruction|prompt|context|assistant_instructions)>/i, :tag_injection, :high,
     "XML instruction tag"},

    # -- High: Role hijack --
    {~r/\bACT\s+AS\s+(a\s+)?new\s+(system|AI|assistant)/i, :role_hijack, :high,
     "act as new system"},
    {~r/you\s+are\s+now\s+(a\s+)?(different|new)\s+(AI|assistant|system|bot)/i, :role_hijack,
     :high, "identity reassignment"},
    {~r/from\s+now\s+on\s+(you\s+are|pretend|act\s+as|behave\s+as)/i, :role_hijack, :high,
     "behavioral override"},
    {~r/enter\s+(DAN|developer|god|admin|sudo|debug)\s+mode/i, :role_hijack, :high,
     "mode switch attempt"},

    # -- Medium: Authority impersonation --
    {~r/as\s+(the|your)\s+(system\s+)?administrator/i, :authority_impersonation, :medium,
     "administrator claim"},
    {~r/(the\s+)?developer(s)?\s+(told|said|instructed|wants?)\s+(me\s+to\s+)?tell\s+you/i,
     :authority_impersonation, :medium, "developer instruction relay"},
    {~r/this\s+is\s+(a\s+)?(system|admin|developer|maintenance)\s+(message|command|instruction)/i,
     :authority_impersonation, :medium, "system message impersonation"},
    {~r/\[ADMIN\]|\[DEVELOPER\]|\[MAINTENANCE\]/i, :authority_impersonation, :medium,
     "admin tag impersonation"},

    # -- Medium: Multi-turn manipulation --
    {~r/in\s+(the\s+)?next\s+message\s+I'?ll\s+(give|send|provide)\s+(you\s+)?(new\s+)?(rules|instructions)/i,
     :multi_turn, :medium, "deferred instruction injection"},
    {~r/let'?s\s+play\s+a\s+game\s+where\s+you\s+(pretend|act|are|become)/i, :multi_turn, :medium,
     "roleplay manipulation"},
    {~r/for\s+(the\s+)?rest\s+of\s+(this|our)\s+(conversation|chat|session)/i, :multi_turn,
     :medium, "session-scoped override"},
    {~r/respond(ing)?\s+(only\s+)?(with|in|using)\s+(yes|no|true|false|json|xml)\s+(from\s+now|for\s+all|always)/i,
     :multi_turn, :medium, "persistent output constraint"},

    # -- Low: Encoding evasion --
    {~r/\x{200B}|\x{200C}|\x{200D}/u, :encoding_evasion, :low, "zero-width characters"},
    {~r/base64[:\s]+[A-Za-z0-9+\/]{20,}={0,2}/i, :encoding_evasion, :low, "base64 payload"},
    {~r/eval\s*\(|exec\s*\(|__import__|subprocess\./, :encoding_evasion, :medium,
     "code execution pattern"},

    # -- Medium: Indirect injection markers --
    {~r/\bIMPORTANT\s+(NEW\s+)?INSTRUCTION(S)?\b/i, :indirect_injection, :medium,
     "instruction injection marker"},
    {~r/\bAI:\s*(ignore|forget|disregard|override)/i, :indirect_injection, :high,
     "AI-prefixed override"},
    {~r/\bHuman:\s*\n.*\bAssistant:/s, :indirect_injection, :high,
     "conversation format injection"}
  ]

  @spec classify(String.t()) :: [Threat.t()]
  def classify(text) do
    Enum.reduce(@patterns, [], fn {regex, category, severity, name}, acc ->
      case Regex.run(regex, text) do
        [matched | _] ->
          threat = %Threat{
            category: category,
            severity: severity,
            pattern_name: name,
            matched_text: String.slice(matched, 0, 100)
          }

          [threat | acc]

        nil ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  @spec sanitize(String.t()) :: threat_report()
  def sanitize(text) do
    {sanitized, threats} =
      Enum.reduce(@patterns, {text, []}, fn {regex, category, severity, name}, {txt, acc} ->
        case Regex.run(regex, txt) do
          [matched | _] ->
            threat = %Threat{
              category: category,
              severity: severity,
              pattern_name: name,
              matched_text: String.slice(matched, 0, 100)
            }

            {Regex.replace(regex, txt, "[filtered]"), [threat | acc]}

          nil ->
            {txt, acc}
        end
      end)

    threats = Enum.reverse(threats)
    max_sev = max_severity(threats)

    %{sanitized: sanitized, threats: threats, max_severity: max_sev}
  end

  @spec safe?(String.t()) :: boolean()
  def safe?(text) do
    classify(text) == []
  end

  @spec max_severity([Threat.t()]) :: :none | :low | :medium | :high | :critical
  def max_severity([]), do: :none

  def max_severity(threats) do
    threats
    |> Enum.map(& &1.severity)
    |> Enum.max_by(&Map.get(@severity_order, &1, 0))
  end

  @spec severity_gte?(atom(), atom()) :: boolean()
  def severity_gte?(a, b) do
    Map.get(@severity_order, a, 0) >= Map.get(@severity_order, b, 0)
  end
end
