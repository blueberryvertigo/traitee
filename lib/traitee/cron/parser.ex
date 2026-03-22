defmodule Traitee.Cron.Parser do
  @moduledoc "Cron expression parser (5-field: minute hour day month weekday)."

  defstruct [:minute, :hour, :day, :month, :weekday]

  @type t :: %__MODULE__{
          minute: [non_neg_integer()],
          hour: [non_neg_integer()],
          day: [non_neg_integer()],
          month: [non_neg_integer()],
          weekday: [non_neg_integer()]
        }

  @ranges %{
    minute: 0..59,
    hour: 0..23,
    day: 1..31,
    month: 1..12,
    weekday: 0..6
  }

  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(expression) do
    parts = String.split(String.trim(expression))

    if length(parts) != 5 do
      {:error, "expected 5 fields, got #{length(parts)}"}
    else
      fields = [:minute, :hour, :day, :month, :weekday]

      with {:ok, parsed} <- parse_fields(Enum.zip(fields, parts)) do
        {:ok, struct(__MODULE__, parsed)}
      end
    end
  end

  @spec next_occurrence(t(), DateTime.t()) :: DateTime.t()
  def next_occurrence(%__MODULE__{} = expr, %DateTime{} = from) do
    from
    |> DateTime.add(60, :second)
    |> Map.put(:second, 0)
    |> Map.put(:microsecond, {0, 0})
    |> advance(expr, 0)
  end

  @spec matches?(t(), DateTime.t()) :: boolean()
  def matches?(%__MODULE__{} = expr, %DateTime{} = dt) do
    dt.minute in expr.minute and
      dt.hour in expr.hour and
      dt.day in expr.day and
      dt.month in expr.month and
      weekday_to_cron(Date.day_of_week(dt)) in expr.weekday
  end

  # -- Private --

  defp parse_fields(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {field, token}, {:ok, acc} ->
      case parse_field(token, @ranges[field]) do
        {:ok, values} -> {:cont, {:ok, Map.put(acc, field, values)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_field("*", range), do: {:ok, Enum.to_list(range)}

  defp parse_field("*/" <> step_str, range) do
    with {step, ""} when step > 0 <- Integer.parse(step_str) do
      values = range |> Enum.to_list() |> Enum.take_every(step)
      {:ok, values}
    else
      _ -> {:error, "invalid step: */#{step_str}"}
    end
  end

  defp parse_field(token, range) do
    parts = String.split(token, ",")

    result =
      Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
        case parse_range_or_value(part, range) do
          {:ok, values} -> {:cont, {:ok, acc ++ values}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, values} -> {:ok, Enum.uniq(values) |> Enum.sort()}
      err -> err
    end
  end

  defp parse_range_or_value(part, range) do
    case String.split(part, "-") do
      [low_str, high_str] ->
        with {low, ""} <- Integer.parse(low_str),
             {high, ""} <- Integer.parse(high_str),
             true <- Enum.member?(range, low) and Enum.member?(range, high) and low <= high do
          {:ok, Enum.to_list(low..high)}
        else
          _ -> {:error, "invalid range: #{part}"}
        end

      [val_str] ->
        case Integer.parse(val_str) do
          {val, ""} ->
            if Enum.member?(range, val),
              do: {:ok, [val]},
              else: {:error, "invalid value: #{val_str}"}

          _ ->
            {:error, "invalid value: #{val_str}"}
        end

      _ ->
        {:error, "invalid expression: #{part}"}
    end
  end

  defp advance(dt, _expr, iterations) when iterations > 525_960 do
    raise "could not find next occurrence within a year from #{DateTime.to_iso8601(dt)}"
  end

  defp advance(dt, expr, iterations) do
    cond do
      dt.month not in expr.month ->
        dt |> next_month() |> advance(expr, iterations + 1)

      dt.day not in expr.day ->
        dt |> next_day() |> advance(expr, iterations + 1)

      weekday_to_cron(Date.day_of_week(dt)) not in expr.weekday ->
        dt |> next_day() |> advance(expr, iterations + 1)

      dt.hour not in expr.hour ->
        dt |> next_hour() |> advance(expr, iterations + 1)

      dt.minute not in expr.minute ->
        dt |> next_minute() |> advance(expr, iterations + 1)

      true ->
        dt
    end
  end

  defp next_month(dt) do
    dt
    |> Map.put(:day, 1)
    |> Map.put(:hour, 0)
    |> Map.put(:minute, 0)
    |> DateTime.add(31 * 86_400, :second)
    |> then(fn shifted -> %{shifted | day: 1, hour: 0, minute: 0, second: 0} end)
  end

  defp next_day(dt) do
    dt
    |> Map.put(:hour, 0)
    |> Map.put(:minute, 0)
    |> DateTime.add(86_400, :second)
    |> then(fn shifted -> %{shifted | hour: 0, minute: 0, second: 0} end)
  end

  defp next_hour(dt) do
    dt
    |> Map.put(:minute, 0)
    |> DateTime.add(3600, :second)
    |> then(fn shifted -> %{shifted | minute: 0, second: 0} end)
  end

  defp next_minute(dt) do
    DateTime.add(dt, 60, :second)
  end

  defp weekday_to_cron(1), do: 1
  defp weekday_to_cron(2), do: 2
  defp weekday_to_cron(3), do: 3
  defp weekday_to_cron(4), do: 4
  defp weekday_to_cron(5), do: 5
  defp weekday_to_cron(6), do: 6
  defp weekday_to_cron(7), do: 0
end
