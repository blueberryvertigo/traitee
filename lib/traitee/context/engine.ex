defmodule Traitee.Context.Engine do
  @moduledoc """
  Context assembly engine with workspace prompts, hybrid search,
  query expansion, skill injection, and token-aware progressive disclosure.
  """

  alias Traitee.Context.{Budget, Continuity}
  alias Traitee.LLM.{Router, Tokenizer}
  alias Traitee.Memory.{HybridSearch, MTM, QueryExpansion, STM, Vector}
  alias Traitee.Security.{Canary, Cognitive}
  alias Traitee.Skills.Loader, as: Skills
  alias Traitee.Workspace

  require Logger

  def assemble(session_id, stm_state, current_message, opts \\ []) do
    model = opts[:model] || Traitee.Config.get([:agent, :model]) || "openai/gpt-4o"
    system_prompt = build_system_prompt(Keyword.put(opts, :session_id, session_id))
    tool_defs = opts[:tools]

    tool_schema_tokens =
      if tool_defs do
        tool_defs |> Enum.map(&Tokenizer.count_tool/1) |> Enum.sum()
      else
        0
      end

    budget =
      Budget.allocate(model, system_prompt, current_message,
        tool_schema_tokens: tool_schema_tokens,
        mode: opts[:budget_mode] || :normal
      )

    {skills_section, budget} = assemble_skills_summary(budget)
    {tasks_section, budget} = assemble_active_tasks(session_id, budget)
    {ltm_msgs, budget} = assemble_ltm(session_id, stm_state, current_message, budget)
    {mtm_msgs, budget} = assemble_mtm(session_id, current_message, budget)

    budget = Budget.reallocate(budget, :ltm_budget, :stm_budget)
    budget = Budget.reallocate(budget, :mtm_budget, :stm_budget)

    {stm_msgs, budget} = assemble_stm(stm_state, budget)

    tool_results = opts[:tool_results] || []
    {tool_msgs, budget} = assemble_tool_results(tool_results, budget)

    {reminder_msgs, budget} = assemble_reminders(session_id, budget, opts)

    sections = %{
      ltm: ltm_msgs,
      mtm: mtm_msgs,
      stm: stm_msgs,
      tools: tool_msgs,
      reminders: reminder_msgs
    }

    channel = opts[:channel]

    messages =
      build_message_list(
        system_prompt,
        skills_section,
        tasks_section,
        sections,
        current_message,
        channel
      )

    log_budget_summary(budget)
    {messages, budget}
  end

  def assemble_simple(messages, opts \\ []) do
    system_prompt = build_system_prompt(opts)

    if system_prompt != "" do
      [%{role: "system", content: system_prompt} | messages]
    else
      messages
    end
  end

  def assemble_with_skills(session_id, stm_state, current_message, triggered_skills, opts \\ []) do
    {messages, budget} = assemble(session_id, stm_state, current_message, opts)

    {skill_msgs, budget} =
      load_triggered_skills(triggered_skills, budget)

    insert_idx = find_system_end(messages)
    messages = List.insert_at(messages, insert_idx, skill_msgs) |> List.flatten()

    log_budget_summary(budget)
    {messages, budget}
  end

  # -- System Prompt --

  @channel_awareness """
  You operate across multiple channels (CLI, Telegram, Discord, etc.) within a single unified session. \
  User messages are prefixed with [via <channel>] to indicate their source. \
  When asked about messages on a specific channel, refer to these tags in the conversation history. \
  You can send messages to other channels using the channel_send tool.\
  """

  defp build_system_prompt(opts) do
    workspace_prompt = Workspace.system_prompt()
    config_prompt = opts[:system_prompt] || Traitee.Config.get([:agent, :system_prompt]) || ""

    base =
      case workspace_prompt do
        nil -> config_prompt
        wp -> wp <> "\n\n" <> config_prompt
      end
      |> String.trim()
      |> append_channel_awareness()

    session_id = opts[:session_id]

    canary_enabled = Traitee.Config.get([:security, :cognitive, :canary_enabled]) != false

    if session_id && Cognitive.enabled?() && canary_enabled do
      canary_section = Canary.system_prompt_section(session_id)
      base <> "\n\n" <> canary_section
    else
      base
    end
  end

  defp append_channel_awareness(base) do
    if Traitee.Config.get([:security, :owner_id]) do
      base <> "\n\n" <> @channel_awareness
    else
      base
    end
  end

  # -- Skills (Tier 1 metadata) --

  defp assemble_skills_summary(budget) do
    summary = Skills.skill_context_summary()

    if summary == "" do
      {nil, Budget.record_usage(budget, :skills, 0)}
    else
      {text, tokens} =
        Budget.truncate_to_budget(
          "[Available Skills]\n#{summary}",
          budget.skills_budget
        )

      {text, Budget.record_usage(budget, :skills, tokens)}
    end
  end

  # -- Skills (Tier 2 full content) --

  defp load_triggered_skills([], budget), do: {[], budget}

  defp load_triggered_skills(skill_names, budget) do
    remaining = budget.skills_budget - Map.get(budget.usage, :skills, 0)

    {msgs, used} =
      Enum.reduce_while(skill_names, {[], 0}, fn name, {acc, used} ->
        case Skills.load_skill(name) do
          {:ok, content} ->
            tokens = Tokenizer.count_tokens(content)

            if used + tokens <= remaining do
              msg = %{role: "system", content: "[Skill: #{name}]\n#{content}"}
              {:cont, {acc ++ [msg], used + tokens}}
            else
              {truncated, t} = Budget.truncate_to_budget(content, remaining - used)
              msg = %{role: "system", content: "[Skill: #{name}]\n#{truncated}"}
              {:halt, {acc ++ [msg], used + t}}
            end

          {:error, _} ->
            {:cont, {acc, used}}
        end
      end)

    prev = Map.get(budget.usage, :skills, 0)
    {msgs, Budget.record_usage(budget, :skills, prev + used)}
  end

  # -- Active Tasks --

  defp assemble_active_tasks(session_id, budget) do
    tasks = Traitee.Tools.TaskTracker.active_tasks(session_id)

    if tasks == [] do
      {nil, budget}
    else
      lines =
        Enum.map(tasks, fn t -> "- [#{t.status}] #{t.id}: #{t.content}" end)

      raw = "[Active Tasks]\n#{Enum.join(lines, "\n")}"
      tokens = Tokenizer.count_tokens(raw)
      {raw, %{budget | system_prompt_tokens: budget.system_prompt_tokens + tokens}}
    end
  end

  # -- LTM with hybrid search + query expansion --

  defp assemble_ltm(session_id, stm_state, current_message, budget) when budget.ltm_budget > 0 do
    recent_msgs = STM.get_recent(stm_state, 5)
    topic = Continuity.detect_topic_shift(current_message, recent_msgs)

    queries = QueryExpansion.expand(current_message)

    search_opts =
      case topic do
        :new_topic -> [limit: 8, diversity: 0.4, min_score: 0.15]
        :related -> [limit: 6, diversity: 0.3, min_score: 0.2]
        :same_topic -> [limit: 4, diversity: 0.2, min_score: 0.3]
      end

    results =
      queries
      |> Enum.flat_map(fn q -> HybridSearch.search(q, session_id, search_opts) end)
      |> deduplicate_results()
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(search_opts[:limit])

    context_text = format_search_results(results)

    if context_text == "" do
      {[], Budget.record_usage(budget, :ltm, 0)}
    else
      {text, tokens} =
        Budget.truncate_to_budget(
          "[Memory Context]\n#{context_text}",
          budget.ltm_budget
        )

      msgs = [%{role: "system", content: text}]
      {msgs, Budget.record_usage(budget, :ltm, tokens)}
    end
  end

  defp assemble_ltm(_sid, _stm, _msg, budget) do
    {[], Budget.record_usage(budget, :ltm, 0)}
  end

  # -- MTM --

  defp assemble_mtm(session_id, current_message, budget) when budget.mtm_budget > 0 do
    recent_summaries = MTM.get_recent(session_id, 3)

    semantic_summaries =
      case Router.embed([current_message]) do
        {:ok, [query_emb]} ->
          Vector.search(query_emb, 3, source_type: :summary, min_score: 0.3)
          |> Enum.map(fn {:summary, sid, _score} ->
            Traitee.Repo.get(Traitee.Memory.Schema.Summary, sid)
          end)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    all_summaries =
      (recent_summaries ++ semantic_summaries)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.inserted_at)

    if all_summaries == [] do
      {[], Budget.record_usage(budget, :mtm, 0)}
    else
      text = Enum.map_join(all_summaries, "\n---\n", & &1.content)

      {text, tokens} =
        Budget.truncate_to_budget(
          "[Conversation History Summary]\n#{text}",
          budget.mtm_budget
        )

      msgs = [%{role: "system", content: text}]
      {msgs, Budget.record_usage(budget, :mtm, tokens)}
    end
  end

  defp assemble_mtm(_sid, _msg, budget) do
    {[], Budget.record_usage(budget, :mtm, 0)}
  end

  # -- STM --

  defp assemble_stm(stm_state, budget) do
    messages = STM.get_messages(stm_state)

    formatted =
      Enum.map(messages, fn msg ->
        content = tag_channel(msg.role, msg.content, msg.channel)
        %{role: msg.role, content: content, token_count: msg.token_count}
      end)

    fitted = Budget.fit_recent(formatted, budget.stm_budget)
    tokens = fitted |> Enum.map(& &1.token_count) |> Enum.sum()
    {fitted, Budget.record_usage(budget, :stm, tokens)}
  end

  defp tag_channel("user", content, channel)
       when not is_nil(channel) and channel != "" do
    "[via #{channel}] #{content}"
  end

  defp tag_channel(_role, content, _channel), do: content

  # -- Tool results --

  defp assemble_tool_results([], budget), do: {[], Budget.record_usage(budget, :tools, 0)}

  defp assemble_tool_results(results, budget) do
    fitted = Budget.fit_within(results, budget.tool_budget)
    tokens = fitted |> Enum.map(&Tokenizer.count_tokens(&1[:content] || "")) |> Enum.sum()
    {fitted, Budget.record_usage(budget, :tools, tokens)}
  end

  # -- Reminders --

  defp assemble_reminders(session_id, budget, opts) do
    if Cognitive.enabled?() do
      reminder_msgs =
        Cognitive.reminders_for(session_id,
          message_count: opts[:message_count] || 0,
          has_recent_threats: opts[:has_recent_threats] || false
        )

      if reminder_msgs == [] do
        {[], Budget.record_usage(budget, :reminders, 0)}
      else
        text = Enum.map_join(reminder_msgs, "\n", & &1.content)
        tokens = Tokenizer.count_tokens(text)
        capped = min(tokens, budget.reminder_budget)

        if capped < tokens do
          first = List.first(reminder_msgs)

          {[first],
           Budget.record_usage(budget, :reminders, Tokenizer.count_tokens(first.content))}
        else
          {reminder_msgs, Budget.record_usage(budget, :reminders, tokens)}
        end
      end
    else
      {[], Budget.record_usage(budget, :reminders, 0)}
    end
  end

  # -- Message list assembly --

  defp build_message_list(system_prompt, skills_section, tasks_section, sections, current_msg, channel) do
    messages = []

    sys_content =
      [system_prompt, skills_section, tasks_section]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    messages =
      if sys_content == "" do
        messages
      else
        messages ++ [%{role: "system", content: sys_content}]
      end

    messages =
      messages ++
        sections.ltm ++ sections.mtm ++ sections.stm ++ sections.tools ++ sections.reminders

    tagged_msg = tag_channel("user", current_msg, channel)
    messages ++ [%{role: "user", content: tagged_msg}]
  end

  # -- Search helpers --

  defp deduplicate_results(results) do
    results
    |> Enum.uniq_by(fn r -> {r.source, r.id} end)
  end

  defp format_search_results(results) do
    {entities, non_entities} = Enum.split_with(results, &(&1.source == :entity))
    {facts, summaries} = Enum.split_with(non_entities, &(&1.source == :fact))

    parts = []

    parts =
      if entities != [] do
        text =
          entities
          |> Enum.take(3)
          |> Enum.map_join("\n", fn r -> "- #{r.content}" end)

        parts ++ ["Entities:\n#{text}"]
      else
        parts
      end

    parts =
      if facts != [] do
        text =
          facts
          |> Enum.take(5)
          |> Enum.map(fn r -> resolve_content(r) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join("\n", fn c -> "- #{c}" end)

        parts ++ ["Facts:\n#{text}"]
      else
        parts
      end

    parts =
      if summaries != [] do
        text =
          summaries
          |> Enum.take(3)
          |> Enum.map(fn r -> resolve_content(r) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n---\n")

        parts ++ ["Past context:\n#{text}"]
      else
        parts
      end

    Enum.join(parts, "\n\n")
  end

  defp resolve_content(%{content: c}) when is_binary(c) and c != "", do: c

  defp resolve_content(%{source: :fact, id: id}) do
    case Traitee.Repo.get(Traitee.Memory.Schema.Fact, id) do
      nil -> nil
      fact -> fact.content
    end
  end

  defp resolve_content(%{source: :summary, id: id}) do
    case Traitee.Repo.get(Traitee.Memory.Schema.Summary, id) do
      nil -> nil
      s -> s.content
    end
  end

  defp resolve_content(_), do: nil

  defp find_system_end(messages) do
    idx =
      Enum.find_index(messages, fn msg ->
        msg.role != "system"
      end)

    idx || length(messages)
  end

  defp log_budget_summary(budget) do
    Logger.debug(fn -> Budget.budget_summary(budget) end)
  end
end
