defmodule Traitee.Context.Budget do
  @moduledoc """
  Token budget allocation with dynamic reallocation and usage tracking.

  Allocates token slots to context components in priority order, tracks
  actual usage per slot, and redistributes unused capacity to later slots.
  """

  alias Traitee.LLM.Tokenizer

  defstruct [
    :total_budget,
    :system_prompt_tokens,
    :current_message_tokens,
    :skills_budget,
    :ltm_budget,
    :stm_budget,
    :mtm_budget,
    :tool_budget,
    :reminder_budget,
    :response_budget,
    :safety_margin,
    :remaining,
    :mode,
    usage: %{}
  ]

  @response_fraction 0.15
  @safety_fraction 0.05

  @slot_ratios %{
    skills: {0.05, 1_000},
    ltm: {0.15, 2_000},
    mtm: {0.20, 3_000},
    tool: {0.15, 4_000},
    reminder: {0.02, 300}
  }

  @compact_reduction 0.7

  def allocate(model_string, system_prompt, current_message, opts \\ []) do
    mode = opts[:mode] || :normal
    context_window = Tokenizer.context_window(model_string)
    max_output = Tokenizer.max_output(model_string)

    system_tokens = Tokenizer.count_tokens(system_prompt)
    message_tokens = Tokenizer.count_tokens(current_message)
    tool_schema_tokens = opts[:tool_schema_tokens] || 0

    response_budget = min(max_output, round(context_window * @response_fraction))
    safety_margin = round(context_window * @safety_fraction)

    fixed_cost =
      system_tokens + message_tokens + tool_schema_tokens + response_budget + safety_margin

    available = max(context_window - fixed_cost, 0)

    {skills_budget, ltm_budget, mtm_budget, tool_budget, reminder_budget, stm_budget} =
      distribute_variable(available, mode)

    %__MODULE__{
      total_budget: context_window,
      system_prompt_tokens: system_tokens,
      current_message_tokens: message_tokens,
      skills_budget: skills_budget,
      ltm_budget: ltm_budget,
      stm_budget: stm_budget,
      mtm_budget: mtm_budget,
      tool_budget: tool_budget,
      reminder_budget: reminder_budget,
      response_budget: response_budget,
      safety_margin: safety_margin,
      remaining: available,
      mode: mode,
      usage: %{}
    }
  end

  def record_usage(%__MODULE__{} = budget, slot, tokens_used) when is_atom(slot) do
    %{budget | usage: Map.put(budget.usage, slot, tokens_used)}
  end

  def reallocate(%__MODULE__{} = budget, from_slot, to_slot) do
    allocated = Map.get(budget |> Map.from_struct(), from_slot, 0)
    used = Map.get(budget.usage, from_slot, 0)
    surplus = max(allocated - used, 0)

    if surplus > 0 do
      current_to = Map.get(budget |> Map.from_struct(), to_slot, 0)

      budget
      |> Map.put(from_slot, allocated - surplus)
      |> Map.put(to_slot, current_to + surplus)
    else
      budget
    end
  end

  def fixed_tokens(%__MODULE__{} = budget) do
    budget.system_prompt_tokens + budget.current_message_tokens +
      budget.response_budget + budget.safety_margin
  end

  def variable_budget(%__MODULE__{} = budget) do
    budget.skills_budget + budget.ltm_budget + budget.stm_budget +
      budget.mtm_budget + budget.tool_budget + budget.reminder_budget
  end

  def total_used(%__MODULE__{} = budget) do
    budget.usage |> Map.values() |> Enum.sum()
  end

  def budget_summary(%__MODULE__{} = budget) do
    slots = [
      {"system", budget.system_prompt_tokens, budget.system_prompt_tokens},
      {"message", budget.current_message_tokens, budget.current_message_tokens},
      {"skills", budget.skills_budget, Map.get(budget.usage, :skills, 0)},
      {"ltm", budget.ltm_budget, Map.get(budget.usage, :ltm, 0)},
      {"mtm", budget.mtm_budget, Map.get(budget.usage, :mtm, 0)},
      {"stm", budget.stm_budget, Map.get(budget.usage, :stm, 0)},
      {"tools", budget.tool_budget, Map.get(budget.usage, :tools, 0)},
      {"reminders", budget.reminder_budget, Map.get(budget.usage, :reminders, 0)},
      {"response", budget.response_budget, 0},
      {"safety", budget.safety_margin, 0}
    ]

    lines =
      Enum.map(slots, fn {name, allocated, used} ->
        pct = if allocated > 0, do: round(used / allocated * 100), else: 0

        "  #{String.pad_trailing(name, 10)} #{String.pad_leading(Integer.to_string(used), 6)}/#{String.pad_leading(Integer.to_string(allocated), 6)} (#{pct}%)"
      end)

    total_alloc = budget.total_budget
    total_used = fixed_tokens(budget) + total_used(budget)

    header = "Budget [#{budget.mode}] #{total_used}/#{total_alloc} tokens"
    Enum.join([header | lines], "\n")
  end

  def fit_within(items, max_tokens) do
    {fitted, _remaining} =
      Enum.reduce(items, {[], max_tokens}, fn item, {acc, remaining} ->
        tokens = item_tokens(item)

        if tokens <= remaining do
          {acc ++ [item], remaining - tokens}
        else
          {acc, remaining}
        end
      end)

    fitted
  end

  def fit_recent(items, max_tokens) do
    items
    |> Enum.reverse()
    |> fit_within(max_tokens)
    |> Enum.reverse()
  end

  def truncate_to_budget(text, max_tokens) when is_binary(text) do
    tokens = Tokenizer.count_tokens(text)

    if tokens <= max_tokens do
      {text, tokens}
    else
      chars = round(max_tokens * 4.0 * 0.9)
      truncated = String.slice(text, 0, max(chars, 0)) <> "\n[truncated]"
      {truncated, Tokenizer.count_tokens(truncated)}
    end
  end

  defp distribute_variable(available, mode) do
    scale = if mode == :compact, do: @compact_reduction, else: 1.0

    {skills_budget, ltm_budget, mtm_budget, tool_budget, reminder_budget} =
      @slot_ratios
      |> Enum.reduce({0, 0, 0, 0, 0}, fn
        {:skills, {ratio, cap}}, {_, l, m, t, r} ->
          {min(round(available * ratio * scale), round(cap * scale)), l, m, t, r}

        {:ltm, {ratio, cap}}, {s, _, m, t, r} ->
          {s, min(round(available * ratio * scale), round(cap * scale)), m, t, r}

        {:mtm, {ratio, cap}}, {s, l, _, t, r} ->
          {s, l, min(round(available * ratio * scale), round(cap * scale)), t, r}

        {:tool, {ratio, cap}}, {s, l, m, _, r} ->
          {s, l, m, min(round(available * ratio * scale), round(cap * scale)), r}

        {:reminder, {ratio, cap}}, {s, l, m, t, _} ->
          {s, l, m, t, min(round(available * ratio * scale), round(cap * scale))}
      end)

    stm_budget =
      max(available - skills_budget - ltm_budget - mtm_budget - tool_budget - reminder_budget, 0)

    {
      max(skills_budget, 0),
      max(ltm_budget, 0),
      max(mtm_budget, 0),
      max(tool_budget, 0),
      max(reminder_budget, 0),
      max(stm_budget, 0)
    }
  end

  defp item_tokens(%{token_count: tc}) when is_integer(tc), do: tc
  defp item_tokens(%{content: c}) when is_binary(c), do: Tokenizer.count_tokens(c)
  defp item_tokens(item) when is_map(item), do: Tokenizer.count_tokens(item[:content] || "")
  defp item_tokens(_), do: 0
end
