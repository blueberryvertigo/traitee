defmodule Traitee.Cognition.Interest do
  @moduledoc """
  Pure functional module for interest extraction, scoring, and project ideation.

  Keeps LLM-dependent extraction separate from deterministic scoring and ranking.
  """

  alias Traitee.LLM.Router

  require Logger

  @extraction_prompt """
  Analyze this conversation turn and extract structured signals about the user. Return JSON only.

  {
    "interests": [{"topic": "...", "enthusiasm": 0.0-1.0, "depth": "shallow|moderate|deep"}],
    "expertise_signals": [{"domain": "...", "level": "novice|intermediate|expert", "evidence": "..."}],
    "desires": ["explicit wish or need expressed by the user..."],
    "active_projects": ["project or task the user is currently working on..."],
    "style_notes": {"formality": "casual|neutral|formal", "detail_preference": "concise|moderate|detailed"}
  }

  Only include fields where you have clear evidence. Omit empty arrays. Be precise.
  """

  @doc "Extract interest signals from a conversation turn via a lightweight LLM call."
  def extract(user_message, context_messages \\ []) do
    context_text =
      context_messages
      |> Enum.take(-5)
      |> Enum.map_join("\n", fn m -> "#{m[:role]}: #{m[:content]}" end)

    prompt =
      @extraction_prompt <>
        "\n\nRecent context:\n#{context_text}\n\nLatest user message:\n#{user_message}"

    request = %{
      messages: [%{role: "user", content: prompt}],
      system: "You are a precise signal extractor. Return valid JSON only, no explanation."
    }

    case Router.complete(request) do
      {:ok, %{content: content}} -> parse_extraction(content)
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Compute a composite interest score from signal dimensions.

  Score = frequency * 0.3 + recency * 0.3 + depth * 0.2 + enthusiasm * 0.2
  """
  def score(%{} = interest) do
    freq = normalize(interest[:frequency] || 1, 20)
    recency = recency_score(interest[:last_seen])
    depth = depth_to_float(interest[:depth] || "shallow")
    enthusiasm = interest[:enthusiasm] || 0.5

    freq * 0.3 + recency * 0.3 + depth * 0.2 + enthusiasm * 0.2
  end

  @doc "Identify interests with rising scores (higher recent frequency than historical average)."
  def trending(interests) when is_list(interests) do
    interests
    |> Enum.filter(fn i ->
      recency_score(i[:last_seen]) > 0.5 and (i[:frequency] || 1) > 2
    end)
    |> Enum.sort_by(&score/1, :desc)
  end

  @doc "Generate research questions from a list of interests."
  def suggest_research(interests) when is_list(interests) do
    interests
    |> Enum.sort_by(&score/1, :desc)
    |> Enum.take(5)
    |> Enum.map(fn i ->
      %{
        topic: i[:topic] || i.topic,
        query: "latest developments in #{i[:topic] || i.topic}",
        priority: score(i)
      }
    end)
  end

  @doc "Generate project ideas from interests, expertise, and desires via LLM."
  def suggest_projects(user_profile) do
    interests = user_profile[:interests] || []
    expertise = user_profile[:expertise] || []
    desires = user_profile[:desires] || []
    existing_tools = user_profile[:existing_tools] || []

    prompt = """
    Given this user profile, propose 3 concrete projects to build for them.
    Think creatively. Each project should be genuinely useful and buildable.

    User interests (ranked by importance): #{format_topics(interests)}
    User expertise: #{format_expertise(expertise)}
    Explicit desires: #{Enum.join(desires, "; ")}
    Existing tools/skills: #{Enum.join(existing_tools, ", ")}

    For each project, return JSON:
    [
      {
        "name": "short-name",
        "description": "What it does and why it's valuable",
        "type": "tool|skill|code|research",
        "complexity": "simple|moderate|complex",
        "interest_source": "which interest this serves"
      }
    ]

    Be creative and specific. Don't propose generic things.
    """

    request = %{
      messages: [%{role: "user", content: prompt}],
      system: "You are a creative product designer. Return valid JSON array only."
    }

    case Router.complete(request) do
      {:ok, %{content: content}} -> parse_projects(content)
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Merge new extraction signals into an existing interest map."
  def merge_signals(existing, new_signals) do
    new_interests = new_signals["interests"] || []

    Enum.reduce(new_interests, existing, fn signal, acc ->
      topic = signal["topic"]
      enthusiasm = signal["enthusiasm"] || 0.5
      depth = signal["depth"] || "shallow"

      case Map.get(acc, topic) do
        nil ->
          Map.put(acc, topic, %{
            topic: topic,
            enthusiasm: enthusiasm,
            depth: depth,
            frequency: 1,
            first_seen: DateTime.utc_now(),
            last_seen: DateTime.utc_now(),
            trend: :rising
          })

        prev ->
          updated = %{
            prev
            | enthusiasm: max(prev.enthusiasm, enthusiasm),
              depth: max_depth(prev.depth, depth),
              frequency: prev.frequency + 1,
              last_seen: DateTime.utc_now(),
              trend: compute_trend(prev)
          }

          Map.put(acc, topic, updated)
      end
    end)
  end

  # -- Private --

  defp parse_extraction(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```json\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> Jason.decode()
    |> case do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:ok, %{}}
    end
  end

  defp parse_projects(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```json\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> Jason.decode()
    |> case do
      {:ok, projects} when is_list(projects) -> {:ok, projects}
      {:ok, _} -> {:ok, []}
      {:error, _} -> {:ok, []}
    end
  end

  defp normalize(value, max), do: min(value / max, 1.0)

  defp recency_score(nil), do: 0.0

  defp recency_score(last_seen) do
    hours = DateTime.diff(DateTime.utc_now(), last_seen, :hour)
    :math.pow(0.5, hours / 168.0)
  end

  defp depth_to_float("deep"), do: 1.0
  defp depth_to_float("moderate"), do: 0.6
  defp depth_to_float(_), do: 0.3

  defp max_depth(a, b) do
    [a, b]
    |> Enum.map(&depth_to_float/1)
    |> Enum.max()
    |> case do
      v when v >= 1.0 -> "deep"
      v when v >= 0.6 -> "moderate"
      _ -> "shallow"
    end
  end

  defp compute_trend(%{frequency: f}) when f > 5, do: :stable
  defp compute_trend(%{frequency: f}) when f > 2, do: :rising
  defp compute_trend(_), do: :rising

  defp format_topics(interests) do
    interests
    |> Enum.sort_by(fn {_k, v} -> score(v) end, :desc)
    |> Enum.take(10)
    |> Enum.map_join(", ", fn
      {_k, v} -> "#{v.topic} (#{Float.round(score(v), 2)})"
      v when is_map(v) -> "#{v[:topic]} (#{Float.round(score(v), 2)})"
    end)
  end

  defp format_expertise(expertise) do
    expertise
    |> Enum.map_join(", ", fn e -> "#{e[:domain]}: #{e[:level]}" end)
  end
end
