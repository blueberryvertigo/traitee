defmodule Traitee.Cron.Parser do
  @moduledoc "Cron expression parser (5-field: minute hour day month weekday)."

  defstruct [
    :minute,
    :hour,
    :day,
    :month,
    :weekday,
    day_restricted?: false,
    weekday_restricted?: false
  ]

  @type t :: %__MODULE__{
          minute: [non_neg_integer()],
          hour: [non_neg_integer()],
          day: [non_neg_integer()],
          month: [non_neg_integer()],
          weekday: [non_neg_integer()],
          day_restricted?: boolean(),
          weekday_restricted?: boolean()
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
        expr = struct(__MODULE__, parsed)

        # Standard cron: when BOTH day-of-month and day-of-week are
        # restricted (neither expands to the full range), they combine
        # with OR; otherwise with AND. Record restriction at parse time.
        {:ok,
         %{
           expr
           | day_restricted?: expr.day != Enum.to_list(@ranges.day),
             weekday_restricted?: expr.weekday != Enum.to_list(@ranges.weekday)
         }}
      end
    end
  end

  @spec next_occurrence(t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, :unsatisfiable}
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
      dt.month in expr.month and
      day_matches?(expr, dt)
  end

  defp day_matches?(expr, dt) do
    dom = dt.day in expr.day
    dow = weekday_to_cron(Date.day_of_week(dt)) in expr.weekday

    if expr.day_restricted? and expr.weekday_restricted? do
      dom or dow
    else
      dom and dow
    end
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

  defp advance(_dt, _expr, iterations) when iterations > 525_960 do
    {:error, :unsatisfiable}
  end

  defp advance(dt, expr, iterations) do
    cond do
      dt.month not in expr.month ->
        dt |> next_month() |> advance(expr, iterations + 1)

      not day_matches?(expr, dt) ->
        dt |> next_day() |> advance(expr, iterations + 1)

      dt.hour not in expr.hour ->
        dt |> next_hour() |> advance(expr, iterations + 1)

      dt.minute not in expr.minute ->
        dt |> next_minute() |> advance(expr, iterations + 1)

      true ->
        {:ok, dt}
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
