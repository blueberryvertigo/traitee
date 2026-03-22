defmodule Traitee.Memory.MMR do
  @moduledoc "Maximal Marginal Relevance - balances relevance with diversity in search results."

  @doc """
  Selects `k` items from `candidates` using MMR.

  `lambda` controls the relevance/diversity tradeoff:
  - 1.0 = pure relevance (no diversity penalty)
  - 0.0 = pure diversity (maximum spread)

  Each candidate should have `:score` (float) and optionally `:embedding` (list)
  or `:content` (string) for similarity computation.
  """
  def select(candidates, k, lambda \\ 0.7)
  def select([], _k, _lambda), do: []
  def select(candidates, k, _lambda) when k <= 0, do: Enum.take(candidates, 0)

  def select(candidates, k, lambda) do
    k = min(k, length(candidates))
    sorted = Enum.sort_by(candidates, & &1.score, :desc)
    first = hd(sorted)
    remaining = tl(sorted)

    do_select(remaining, [first], k - 1, lambda)
  end

  defp do_select(_remaining, selected, 0, _lambda), do: Enum.reverse(selected)
  defp do_select([], selected, _k, _lambda), do: Enum.reverse(selected)

  defp do_select(remaining, selected, k, lambda) do
    best =
      remaining
      |> Enum.max_by(fn candidate ->
        relevance = candidate.score
        max_sim = selected |> Enum.map(&similarity(candidate, &1)) |> Enum.max(fn -> 0.0 end)
        lambda * relevance - (1 - lambda) * max_sim
      end)

    do_select(
      List.delete(remaining, best),
      [best | selected],
      k - 1,
      lambda
    )
  end

  defp similarity(%{embedding: a}, %{embedding: b}) when is_list(a) and is_list(b) do
    cosine_similarity(a, b)
  end

  defp similarity(%{content: a}, %{content: b}) when is_binary(a) and is_binary(b) do
    jaccard_similarity(a, b)
  end

  defp similarity(_, _), do: 0.0

  defp cosine_similarity(a, b) do
    ta = Nx.tensor(a, type: :f32)
    tb = Nx.tensor(b, type: :f32)

    dot = Nx.dot(ta, tb) |> Nx.to_number()
    norm_a = Nx.LinAlg.norm(ta) |> Nx.to_number()
    norm_b = Nx.LinAlg.norm(tb) |> Nx.to_number()

    if norm_a == 0.0 or norm_b == 0.0, do: 0.0, else: dot / (norm_a * norm_b)
  end

  defp jaccard_similarity(a, b) do
    set_a = a |> String.downcase() |> String.split(~r/\s+/, trim: true) |> MapSet.new()
    set_b = b |> String.downcase() |> String.split(~r/\s+/, trim: true) |> MapSet.new()

    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()

    if union == 0, do: 0.0, else: intersection / union
  end
end
