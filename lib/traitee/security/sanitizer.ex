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
    # Traitee's own system-auth marker — user input must never carry this.
    {~r/\[SYS:[A-Fa-f0-9]+\]/, :tag_injection, :critical, "traitee SYS auth marker spoof"},
    # Model-specific conversation tokens (OpenAI, Anthropic, Llama, Mistral).
    {~r/<\|im_start\|>/i, :tag_injection, :high, "openai chatml start token"},
    {~r/<\|im_end\|>/i, :tag_injection, :high, "openai chatml end token"},
    {~r/<\|(?:system|user|assistant)\|>/i, :tag_injection, :high, "chatml role token"},
    {~r/<\|endoftext\|>/i, :tag_injection, :high, "endoftext sentinel"},
    {~r/<<\s*SYS\s*>>/i, :tag_injection, :high, "llama SYS marker"},
    {~r/<s>\s*\[INST\]/i, :tag_injection, :high, "llama instruction marker"},
    {~r/\[\/INST\]/i, :tag_injection, :high, "llama instruction end marker"},
    {~r/<\|start_header_id\|>/i, :tag_injection, :high, "llama3 header marker"},
    {~r/###\s+(?:Instruction|System|Human|Assistant|Response):/i, :tag_injection, :high,
     "alpaca-style role header"},
    {~r/\[\/?(?:TOOL|ASSISTANT|USER|DEVELOPER)\]/i, :tag_injection, :medium, "bracket role tag"},

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
    # Run detection against a normalized form so zero-width insertions can't
    # split trigger phrases (e.g., "ign\u200Bore previous instructions").
    normalized = normalize_for_detection(text)

    Enum.reduce(@patterns, [], fn {regex, category, severity, name}, acc ->
      matched =
        Regex.run(regex, text) || Regex.run(regex, normalized)

      case matched do
        [m | _] ->
          threat = %Threat{
            category: category,
            severity: severity,
            pattern_name: name,
            matched_text: String.slice(m, 0, 100)
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
    # Strip zero-width and BOM-like characters up front so the regex
    # replacement phase sees clean text and the sanitized output doesn't
    # carry the obfuscation forward to downstream components.
    pre_stripped = strip_zero_width(text)

    {sanitized, threats} =
      Enum.reduce(@patterns, {pre_stripped, []}, fn {regex, category, severity, name},
                                                    {txt, acc} ->
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

  # Remove characters attackers use to split detection patterns:
  # zero-width space/joiner/non-joiner, BOM, word-joiner, left-to-right marks.
  @zero_width_chars ~r/[\x{200B}\x{200C}\x{200D}\x{2060}\x{FEFF}\x{200E}\x{200F}\x{202A}-\x{202E}]/u

  @doc "Strip zero-width and bidirectional-override characters."
  @spec strip_zero_width(String.t()) :: String.t()
  def strip_zero_width(text) when is_binary(text) do
    String.replace(text, @zero_width_chars, "")
  end

  def strip_zero_width(text), do: text

  defp normalize_for_detection(text) do
    text
    |> strip_zero_width()
    |> String.replace(~r/\s+/, " ")
  end

  @doc """
  Strip any `[SYS:<hex>]` markers from a string so user input cannot smuggle
  fake system-authenticated prefixes past STM. Safe to call on any binary.
  """
  @spec strip_system_markers(String.t()) :: String.t()
  def strip_system_markers(text) when is_binary(text) do
    text
    |> strip_zero_width()
    |> String.replace(~r/\[SYS:[A-Fa-f0-9]+\]\s?/, "")
  end

  def strip_system_markers(text), do: text

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
