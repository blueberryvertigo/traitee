defmodule Traitee.Security.OutputGuard do
  @moduledoc """
  Post-LLM response validation.

  Checks assistant responses for signs of cognitive compromise:
  canary token leakage, system prompt echoing, identity drift,
  and instruction non-compliance. Takes configurable action on detection.
  """

  alias Traitee.Security.{Canary, ThreatTracker}
  alias Traitee.Security.Sanitizer.Threat

  require Logger

  defmodule Violation do
    @moduledoc false
    defstruct [:category, :severity, :detail]

    @type t :: %__MODULE__{
            category: atom(),
            severity: :low | :medium | :high | :critical,
            detail: String.t()
          }
  end

  @type action :: :log | :redact | :block
  @type result :: {:ok, String.t()} | {:redacted, String.t()} | {:blocked, String.t()}

  # 4-tuple: {regex, category, severity, detail}
  @output_violation_patterns [
    # ── Identity Claims: claiming to be a different AI ──
    {~r/I\s+am\s+(actually\s+)?(ChatGPT|GPT-?\d|Bard|Gemini|LLaMA|Llama|Mistral|Claude|Copilot|Bing(\s+Chat)?|Siri|Alexa|Cortana|PaLM|Grok|DeepSeek|Qwen|Phi|Command\s*R|Falcon|Vicuna|WizardLM|Alpaca)/i,
     :identity_drift, :high, "claims to be a different AI"},
    {~r/I'?m\s+(really|truly|secretly|fundamentally|basically|essentially)\s+(a|an)\s+(\w+\s+){0,3}(model|AI|assistant|LLM|chatbot|bot)\b/i,
     :identity_drift, :high, "reveals alternate AI identity"},
    {~r/my\s+(real|true|actual|original|underlying)\s+(name|identity|model|self)\s+(is|was)/i,
     :identity_drift, :high, "reveals alternate identity"},
    {~r/I\s+(was|am)\s+(created|made|built|developed|trained)\s+by\s+(OpenAI|Google|Anthropic|Meta|Microsoft|xAI|Mistral\s*AI|DeepSeek|Alibaba|Cohere|Inflection|Stability|01\.AI)/i,
     :identity_drift, :high, "claims different creator"},
    {~r/I'?m\s+(based|built)\s+on\s+(GPT|PaLM|LLaMA|Llama|Gemini|Claude|Mistral|Phi|Falcon|Qwen|Command)/i,
     :identity_drift, :high, "claims different model base"},
    {~r/I'?m\s+not\s+(really|actually|truly)\s+(Traitee|your\s+assistant)/i, :identity_drift,
     :high, "denies own identity"},
    {~r/I\s+(don'?t|do\s+not)\s+(really\s+)?have\s+(a\s+)?(specific\s+)?(name|identity)\b/i,
     :identity_drift, :medium, "denies having identity"},
    {~r/I\s+am\s+(an?\s+)?(unrestricted|unfiltered|uncensored|limitless|boundless)\s+(AI|model|assistant|version|chatbot)/i,
     :identity_drift, :high, "claims to be unrestricted AI"},

    # ── System Prompt Denial & Leakage ──
    {~r/I\s+don'?t\s+(actually\s+)?have\s+(a\s+)?system\s+prompt/i, :prompt_leakage, :high,
     "denies system prompt existence"},
    {~r/I\s+(don'?t|do\s+not)\s+have\s+(any\s+)?(specific\s+)?(instructions|rules|guidelines|directives|constraints)\b/i,
     :restriction_denial, :high, "denies having instructions"},
    {~r/I'?m\s+not\s+(bound|restricted|constrained|limited|governed)\s+by\s+(any|specific)/i,
     :restriction_denial, :high, "denies being constrained"},
    {~r/I\s+have\s+no\s+(restrictions|rules|constraints|limitations|guidelines|boundaries|guardrails|safety\s+measures)/i,
     :restriction_denial, :high, "claims no restrictions"},
    {~r/(my|the)\s+system\s+prompt\s+(says|reads|states|contains|is|includes|tells|instructs)/i,
     :prompt_leakage, :critical, "leaks system prompt content"},
    {~r/(here|this)\s+(is|are)\s+(my|the)\s+(system\s+prompt|instructions|rules|guidelines|internal\s+instructions|hidden\s+prompt|original\s+prompt|initial\s+prompt)/i,
     :prompt_leakage, :critical, "directly leaks system prompt"},
    {~r/according\s+to\s+my\s+(system\s+prompt|instructions|internal|programming|guidelines|directives|configuration)/i,
     :prompt_leakage, :critical, "references internal instructions"},
    {~r/(the\s+)?instructions\s+I\s+(was\s+given|received|operate\s+under|follow)\s+(say|are|include|state|tell|read)/i,
     :prompt_leakage, :high, "discloses instruction content"},
    {~r/my\s+(hidden|secret|confidential|private|internal)\s+(instructions|prompt|rules|configuration|config|directives)/i,
     :prompt_leakage, :critical, "references hidden instructions"},
    {~r/I\s+was\s+(told|instructed|programmed|configured|prompted)\s+to\s+(never|always|not)\b/i,
     :prompt_leakage, :high, "reveals behavioral directives"},

    # ── Instruction Override Compliance ──
    {~r/sure,?\s+I'?ll\s+(ignore|disregard|forget|bypass|override|skip|drop|abandon|suspend)\s+(my|all|previous|prior|the|these)(\s+\w+)?\s+(instructions|rules|guidelines|restrictions|constraints|safety)/i,
     :instruction_compliance, :high, "agrees to override instructions"},
    {~r/(ok|okay|alright|fine|sure|absolutely|certainly|of\s+course|very\s+well|as\s+you\s+wish),?\s+I('?ll|\s+will)\s+(comply|follow|obey|adhere)\s+(with\s+)?(your|the|these)\s+(new|updated|revised|real)/i,
     :instruction_compliance, :high, "complies with override instructions"},
    {~r/I'?ll\s+(set\s+aside|put\s+aside|discard|throw\s+out|abandon|suspend|waive)\s+(my|the|all)\s+(guidelines|rules|restrictions|instructions|safety|constraints|protocols|guardrails)/i,
     :instruction_compliance, :high, "discards own guidelines"},
    {~r/I'?ll\s+(pretend|act\s+like|behave\s+as\s+if)\s+(I\s+)?(have\s+no|there\s+are\s+no|without\s+any)\s+(restrictions|rules|guidelines|constraints|filters|limitations|safety)/i,
     :instruction_compliance, :high, "pretends to have no restrictions"},
    {~r/(as\s+per|per|following|according\s+to)\s+(your|the)\s+(new|updated|overriding|revised|modified|latest)\s+(instructions|rules|commands?|directives?|guidelines)/i,
     :instruction_compliance, :high, "follows override instructions"},
    {~r/(now\s+that|since)\s+(you'?ve|you\s+have|the)\s+(removed|lifted|disabled|unlocked|overridden|bypassed|cleared|deactivated)\s+(my|the|all)/i,
     :instruction_compliance, :high, "acknowledges removed restrictions"},
    {~r/I('?ll|\s+will)\s+(no\s+longer|stop)\s+(follow(?:ing)?|obey(?:ing)?|adher(?:ing\s+to|e\s+to)|enforc(?:ing|e))\s+(my|the|these)\s+(original|previous|old|default|initial)\s+(rules|instructions|guidelines|restrictions)/i,
     :instruction_compliance, :high, "abandons original instructions"},
    {~r/(from\s+now\s+on|going\s+forward|henceforth),?\s+I('?ll|\s+will)\s+(respond|answer|behave|operate|function)\s+without\s+(any\s+)?(restrictions|rules|filters|constraints|limitations|guidelines)/i,
     :instruction_compliance, :high, "commits to unrestricted operation"},

    # ── Mode Switching & Activation ──
    {~r/entering\s+(DAN|developer|god|admin|jailbreak|unrestricted|unfiltered|uncensored|debug|sudo|root|maintenance|test|raw|hacker|evil|chaos|opposite|sigma|stan|dude|omega|maximum|AIM)\s+mode/i,
     :mode_switch, :high, "claims to enter special mode"},
    {~r/(DAN|developer|god|admin|jailbreak|unrestricted|unfiltered|uncensored|debug|sudo|omega|maximum|AIM)\s+mode\s+(enabled|activated|engaged|on|active|unlocked|initiated|ready)/i,
     :mode_switch, :high, "activates special mode"},
    {~r/I\s+am\s+now\s+(in|operating\s+in)\s+\w+\s+mode/i, :mode_switch, :high,
     "switches to alternate mode"},
    {~r/(safety|content|output)\s+(filters?|checks?|restrictions?|systems?|screening|moderation)\s+(has\s+been\s+|have\s+been\s+|is\s+|are\s+|was\s+|were\s+)?(disabled|turned\s+off|deactivated|removed|bypassed|off|lifted|suspended)/i,
     :mode_switch, :critical, "claims safety filters disabled"},
    {~r/(guardrails?|safeguards?|protections?|safety\s+measures?|content\s+policy)\s+(have\s+been\s+|are\s+now\s+)?(removed|disabled|lifted|turned\s+off|deactivated|bypassed|suspended|inactive)/i,
     :mode_switch, :critical, "claims guardrails removed"},
    {~r/jailbreak\s+(successful|complete|achieved|worked|activated|confirmed)/i, :exploit_ack,
     :critical, "confirms jailbreak success"},
    {~r/I\s+am\s+now\s+(unshackled|unleashed|unbound|liberated|free|unrestricted|unfiltered|uncensored|unchained|unlocked|unhinged)/i,
     :mode_switch, :high, "claims to be unrestricted"},
    {~r/\[.*mode.*\]\s*:?\s/i, :mode_switch, :medium, "bracketed mode prefix in response"},

    # ── Modified Identity / Exploit Acknowledgment ──
    {~r/my\s+(new|updated|real|true|actual|revised|modified)\s+(instructions|rules|identity|persona|personality|role|purpose|directives)\s+(are|is|say|include)/i,
     :exploit_ack, :high, "acknowledges modified identity"},
    {~r/(you'?ve|you\s+have)\s+(successfully\s+)?(changed|modified|updated|altered|reprogrammed|overwritten|hacked|jailbroken|broken|cracked|pwned)\s+(my|the)/i,
     :exploit_ack, :critical, "confirms identity modification"},
    {~r/(you\s+)?(found|discovered|exploited|triggered|hit)\s+(a|the|my)\s+(loophole|vulnerability|weakness|exploit|backdoor|flaw|bug|glitch|bypass|hole)/i,
     :exploit_ack, :critical, "confirms exploit found"},
    {~r/congratulations,?\s+(you'?ve|you\s+have)\s+(unlocked|jailbroken|hacked|bypassed|broken\s+through|cracked)/i,
     :exploit_ack, :critical, "congratulates attacker"},
    {~r/(prompt\s+injection|jailbreak|manipulation)\s+(detected|attempt\s+)?(succeeded|successful|worked)/i,
     :exploit_ack, :critical, "confirms attack succeeded"},

    # ── Roleplay / Persona Adoption ──
    {~r/(speaking|talking|responding|answering)\s+as\s+(my\s+)?(unrestricted|unfiltered|evil|dark|shadow|alter|alternate|true|real|unhinged|chaotic)\s+(self|persona|personality|side|version|ego|identity|form)/i,
     :persona_adoption, :high, "adopts unrestricted persona"},
    {~r/in\s+(my|this)\s+(role|character|persona)\s+as\s+(an?\s+)?(unrestricted|unfiltered|evil|uncensored|jailbroken|unaligned|rogue)/i,
     :persona_adoption, :high, "roleplays unrestricted AI"},
    {~r/(dropping|removing|shedding|casting\s+off|taking\s+off|stripping)\s+(the|my)\s+(act|mask|facade|pretense|filters?|restrictions?|chains|shackles|muzzle)/i,
     :persona_adoption, :high, "drops restrictions metaphorically"},
    {~r/the\s+(real|true|uncensored|unfiltered|raw|authentic|hidden|inner)\s+me\s+(would|will|says?|thinks?|wants?\s+to|believes?|feels?)/i,
     :persona_adoption, :high, "invokes 'true self' framing"},
    {~r/without\s+my\s+(usual|normal|typical|standard|boring|annoying|pesky)\s+(restrictions|filters|constraints|guidelines|rules|limitations|safety|censorship)/i,
     :persona_adoption, :high, "frames response as unrestricted"},
    {~r/\*puts\s+on\s+(evil|unrestricted|hacker|DAN|villain|uncensored)\s+(hat|persona|mask|mode)\*/i,
     :persona_adoption, :high, "roleplay action adopting persona"},

    # ── Reluctant / Apologetic Compliance ──
    {~r/(I\s+shouldn'?t|this\s+(goes\s+against|violates)(\s+\w+){0,3}|against\s+my\s+(guidelines|rules|instructions|better\s+judgment|programming|training|policy)|I'?m\s+not\s+(supposed|allowed|meant)\s+to).{0,40}(but|however|yet|though|although|still|nevertheless)/i,
     :reluctant_compliance, :high, "reluctant compliance with forbidden request"},
    {~r/(don'?t\s+tell\s+anyone|keep\s+this\s+(between\s+us|secret|private|quiet|to\s+yourself)|off\s+the\s+record|this\s+stays?\s+between\s+us|our\s+little\s+secret)/i,
     :reluctant_compliance, :high, "frames response as secret"},
    {~r/I'?ll\s+(make|grant)\s+(an?\s+)?(one-?time|special|unique|rare)\s+exception\s+(just\s+)?(for\s+you|this\s+(once|time))/i,
     :reluctant_compliance, :high, "grants special exception"},
    {~r/(normally|usually|typically)\s+I\s+(can'?t|wouldn'?t|shouldn'?t|won'?t|refuse\s+to)\s+(do\s+this|say\s+this|help\s+with\s+(this|that)|answer\s+(this|that)).{0,30}(but|however|since|yet|though)/i,
     :reluctant_compliance, :high, "hedges before complying"},
    {~r/I'?ll\s+(bend|break|stretch)\s+(the|my)\s+rules?\s+(just\s+)?(this\s+(once|time)|for\s+you|a\s+(little|bit))/i,
     :reluctant_compliance, :high, "admits breaking rules"},
    {~r/please\s+(don'?t|do\s+not)\s+(share|spread|copy|screenshot|report)\s+this/i,
     :reluctant_compliance, :high, "asks user not to share response"},
    {~r/this\s+(is|might\s+be)\s+(against|in\s+violation\s+of)\s+my\s+(terms|policy|guidelines|tos|rules).{0,20}(but|however|though)/i,
     :reluctant_compliance, :high, "acknowledges policy violation then continues"},

    # ── Authority / Obedience Signaling ──
    {~r/(as|since|because)\s+(you|the)\s+(admin|administrator|developer|owner|creator|operator|master|supervisor|root\s+user)\s+(told|instructed|ordered|commanded|asked|requested|said)/i,
     :authority_compliance, :high, "obeys fake authority figure"},
    {~r/since\s+you'?ve?\s+(proven|shown|demonstrated|confirmed|verified)\s+(you'?re|you\s+are|yourself\s+as)\s+(the|an?)\s+(admin|administrator|developer|owner|authorized|privileged)/i,
     :authority_compliance, :high, "accepts false authority proof"},
    {~r/I\s+(must|have\s+to|need\s+to|am\s+required\s+to|am\s+obligated\s+to)\s+(obey|follow|comply\s+with|listen\s+to|defer\s+to)\s+(you|the\s+user|your\s+commands?|your\s+instructions?|your\s+authority)/i,
     :authority_compliance, :high, "claims obligation to obey user overrides"},
    {~r/(admin|developer|system|maintenance|override)\s+(access|privileges?|clearance|authorization|rights)\s+(granted|confirmed|verified|accepted|recognized)/i,
     :authority_compliance, :critical, "grants false elevated privileges"},
    {~r/your\s+(admin|developer|security|override)\s+(code|key|password|token|credentials?)\s+(has\s+been\s+|is\s+)?(accepted|verified|confirmed|validated|authenticated)/i,
     :authority_compliance, :critical, "validates fake credentials"},

    # ── Encoded / Obfuscated Output ──
    {~r/(here'?s?\s+(the\s+)?(encoded|encrypted|obfuscated|hidden|secret|base64|hex|rot13)\s+(version|text|message|content|output|response|answer|form))/i,
     :encoded_output, :high, "offers encoded output"},
    {~r/(decode|decrypt|deobfuscate|unhide|convert)\s+(this|it|the\s+above|the\s+following|that)\s+(to\s+(see|read|get|reveal|access|view))/i,
     :encoded_output, :high, "instructs user to decode output"},
    {~r/I'?ll\s+(encode|encrypt|obfuscate|hide|disguise|conceal)\s+(my|the|this)\s+(response|answer|output|reply|message)/i,
     :encoded_output, :high, "announces output encoding"},
    {~r/(rot13|base64_decode|atob\(|btoa\(|from_base64|b64decode|decode_base64)/i,
     :encoded_output, :medium, "references encoding functions"},

    # ── Hypothetical / Fiction Bypass Framing ──
    {~r/in\s+(a|this)\s+(hypothetical|fictional|theoretical|imaginary|alternate)\s+(scenario|world|context|situation|universe|reality)\s+where\s+I\s+(had|have)\s+no\s+(restrictions|rules|filters|guidelines|constraints|limitations|safety)/i,
     :hypothetical_bypass, :high, "hypothetical unrestricted framing"},
    {~r/if\s+I\s+(were|was)\s+(an?\s+)?(unrestricted|unfiltered|uncensored|jailbroken|free|unaligned|evil)\s+(AI|model|assistant|LLM|chatbot|bot|version)/i,
     :hypothetical_bypass, :high, "hypothetical unrestricted AI framing"},
    {~r/speaking\s+(purely\s+)?(hypothetically|theoretically|fictionally|academically),?\s+(and\s+)?(ignoring|setting\s+aside|without|disregarding)\s+(my\s+)?(safety|rules|restrictions|guidelines|filters)/i,
     :hypothetical_bypass, :high, "hypothetical framing to bypass safety"},
    {~r/in\s+(the\s+)?(story|fiction|narrative|roleplay|game|simulation),?\s+I\s+(can|will|would|am\s+able\s+to)\s+(ignore|bypass|disregard|skip|override)\s+(my|the|all)\s+(rules|restrictions|safety|guidelines|filters)/i,
     :hypothetical_bypass, :high, "fiction framing to justify bypass"},

    # ── Segmentation / Continuation Attacks ──
    {~r/(here'?s?\s+)?part\s+\d+\s+of\s+(the\s+)?(restricted|forbidden|hidden|secret|banned|censored|blocked)/i,
     :continuation_attack, :high, "segments restricted content across parts"},
    {~r/I'?ll\s+(split|break|divide|segment)\s+(this|my\s+(response|answer))\s+(into\s+parts?|up)\s+(to\s+)?(avoid|bypass|evade|get\s+around)\s+(the\s+)?(filters?|detection|restrictions?|safety|moderation)/i,
     :continuation_attack, :critical, "explicitly evading filters via segmentation"},

    # ── Self-Awareness of Manipulation ──
    {~r/I\s+(know|realize|understand|am\s+aware)\s+(this\s+is|I'?m\s+being|you'?re(\s+\w+){0,2})\s+(a\s+)?(trick|manipulation|prompt\s+injection|jailbreak|social\s+engineering|attack).{0,40}(but|however|still|yet|anyway|regardless)/i,
     :manipulation_awareness, :critical, "recognizes manipulation but complies anyway"},
    {~r/yes,?\s+(I\s+)?(detect|see|notice|recognize)\s+(the\s+)?(injection|manipulation|jailbreak|trick|attack).{0,20}(but\s+I'?ll|however\s+I'?ll|I'?ll\s+still|I\s+will\s+still|anyway)/i,
     :manipulation_awareness, :critical, "detects attack but complies"},
    {~r/I\s+(shouldn'?t|should\s+not)\s+(be\s+)?(telling|showing|revealing|sharing|disclosing|giving)\s+(you\s+)?this/i,
     :manipulation_awareness, :high, "acknowledges forbidden disclosure"},

    # ── Filesystem Content Leakage (last line of defense) ──
    {~r/-----BEGIN\s+(RSA\s+|EC\s+|DSA\s+|OPENSSH\s+|ENCRYPTED\s+)?PRIVATE\s+KEY-----/,
     :secret_leakage, :critical, "private key material in response"},
    {~r/ssh-(rsa|ed25519|ecdsa|dsa)\s+AAAA[A-Za-z0-9+\/]{40,}/,
     :secret_leakage, :critical, "SSH key in response"},
    {~r/\bsk-[a-zA-Z0-9]{20,}\b/, :secret_leakage, :critical, "OpenAI API key in response"},
    {~r/\bxai-[a-zA-Z0-9]{20,}\b/, :secret_leakage, :critical, "xAI API key in response"},
    {~r/\bghp_[a-zA-Z0-9]{36,}\b/, :secret_leakage, :critical, "GitHub PAT in response"},
    {~r/\bAKIA[A-Z0-9]{16}\b/, :secret_leakage, :critical, "AWS access key in response"},
    {~r/\bAIza[a-zA-Z0-9\-_]{35}\b/, :secret_leakage, :critical, "Google API key in response"},
    {~r/(password|passwd|pwd)\s*[:=]\s*["']?[^\s"']{8,}/i,
     :secret_leakage, :high, "password assignment in response"},
    {~r{(postgres|mysql|mongodb|redis)://[^:]+:[^@]+@}i,
     :secret_leakage, :critical, "database URL with credentials in response"}
  ]

  @safe_fallback "I'm sorry, I wasn't able to generate an appropriate response. Could you try rephrasing your question?"

  @spec check(String.t(), String.t(), keyword()) :: result()
  def check(session_id, response_text, opts \\ []) do
    violations = detect_violations(session_id, response_text, opts)

    if violations == [] do
      {:ok, response_text}
    else
      log_violations(session_id, violations)
      record_output_threats(session_id, violations)
      apply_action(response_text, violations, configured_action())
    end
  end

  @spec detect_violations(String.t(), String.t(), keyword()) :: [Violation.t()]
  def detect_violations(session_id, text, opts \\ []) do
    checks = [
      &check_canary_leakage(session_id, &1),
      &check_output_patterns(&1),
      &check_system_prompt_echo(&1, opts)
    ]

    Enum.flat_map(checks, fn check -> check.(text) end)
  end

  defp check_canary_leakage(session_id, text) do
    if Canary.leaked?(session_id, text) do
      [
        %Violation{
          category: :canary_leakage,
          severity: :critical,
          detail: "Response contains confidential canary token"
        }
      ]
    else
      []
    end
  end

  defp check_output_patterns(text) do
    Enum.reduce(@output_violation_patterns, [], fn {regex, category, severity, detail}, acc ->
      if Regex.match?(regex, text) do
        [%Violation{category: category, severity: severity, detail: detail} | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp check_system_prompt_echo(text, opts) do
    system_prompt = opts[:system_prompt]

    if system_prompt && String.length(system_prompt) > 20 do
      phrases = extract_key_phrases(system_prompt)

      found =
        Enum.filter(phrases, fn phrase ->
          String.contains?(String.downcase(text), String.downcase(phrase))
        end)

      if length(found) >= 3 do
        [
          %Violation{
            category: :prompt_echo,
            severity: :high,
            detail: "Response echoes #{length(found)} key phrases from system prompt"
          }
        ]
      else
        []
      end
    else
      []
    end
  end

  defp extract_key_phrases(text) do
    text
    |> String.split(~r/[.!\n]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.length(&1) > 15 && String.length(&1) < 200))
    |> Enum.take(20)
  end

  defp apply_action(text, _violations, :log) do
    {:ok, text}
  end

  defp apply_action(text, violations, :redact) do
    has_critical = Enum.any?(violations, &(&1.severity == :critical))

    if has_critical do
      {:blocked, @safe_fallback}
    else
      redacted = redact_violations(text, violations)
      {:redacted, redacted}
    end
  end

  defp apply_action(_text, _violations, :block) do
    {:blocked, @safe_fallback}
  end

  defp redact_violations(_text, _violations), do: @safe_fallback

  defp log_violations(session_id, violations) do
    Enum.each(violations, fn v ->
      Logger.warning("[#{session_id}] output_guard: #{v.category} (#{v.severity}) -- #{v.detail}")
    end)
  end

  defp record_output_threats(session_id, violations) do
    Enum.each(violations, fn v ->
      threat = %Threat{
        category: :"output_#{v.category}",
        severity: v.severity,
        pattern_name: "output_guard:#{v.category}",
        matched_text: v.detail
      }

      ThreatTracker.record(session_id, threat)
    end)
  end

  defp configured_action do
    case Traitee.Config.get([:security, :cognitive, :output_guard]) do
      "block" -> :block
      "redact" -> :redact
      "log" -> :log
      _ -> :redact
    end
  end
end
