defmodule Traitee.Session.Lifecycle do
  @moduledoc "Session lifecycle state machine and per-session configuration."

  defstruct [
    :session_id,
    :channel,
    status: :initializing,
    created_at: nil,
    last_activity: nil,
    thinking_level: :off,
    verbose_level: :off,
    model_override: nil,
    send_policy: :normal,
    group_activation: :mention,
    message_count: 0,
    total_tokens: 0,
    metadata: %{}
  ]

  @type status :: :initializing | :active | :idle | :expired | :terminated

  @type t :: %__MODULE__{
          session_id: String.t(),
          channel: atom(),
          status: status(),
          created_at: DateTime.t() | nil,
          last_activity: DateTime.t() | nil,
          thinking_level: :off | :minimal | :low | :medium | :high,
          verbose_level: :off | :on,
          model_override: String.t() | nil,
          send_policy: atom(),
          group_activation: :mention | :always,
          message_count: non_neg_integer(),
          total_tokens: non_neg_integer(),
          metadata: map()
        }

  @idle_threshold_ms 30 * 60 * 1000
  @expire_threshold_ms 24 * 60 * 60 * 1000

  @spec new(String.t(), atom()) :: t()
  def new(session_id, channel) do
    now = DateTime.utc_now()

    %__MODULE__{
      session_id: session_id,
      channel: channel,
      status: :initializing,
      created_at: now,
      last_activity: now
    }
  end

  @spec transition(t(), atom()) :: {:ok, t()} | {:error, String.t()}
  def transition(%__MODULE__{status: _any} = lc, :terminate) do
    {:ok, %{lc | status: :terminated, last_activity: DateTime.utc_now()}}
  end

  def transition(%__MODULE__{status: :terminated}, event) do
    {:error, "cannot transition from :terminated via #{inspect(event)}"}
  end

  def transition(%__MODULE__{status: :initializing} = lc, :message_received) do
    {:ok, touch(%{lc | status: :active, message_count: lc.message_count + 1})}
  end

  def transition(%__MODULE__{status: :active} = lc, :message_received) do
    {:ok, touch(%{lc | message_count: lc.message_count + 1})}
  end

  def transition(%__MODULE__{status: :idle} = lc, :message_received) do
    {:ok, touch(%{lc | status: :active, message_count: lc.message_count + 1})}
  end

  def transition(%__MODULE__{status: :active} = lc, :response_sent) do
    {:ok, touch(lc)}
  end

  def transition(%__MODULE__{status: :active} = lc, :idle_timeout) do
    {:ok, %{lc | status: :idle}}
  end

  def transition(%__MODULE__{status: :idle} = lc, :expire) do
    {:ok, %{lc | status: :expired}}
  end

  def transition(%__MODULE__{} = lc, :reset) do
    now = DateTime.utc_now()
    {:ok, %{lc | status: :initializing, message_count: 0, total_tokens: 0, last_activity: now}}
  end

  def transition(%__MODULE__{status: status}, event) do
    {:error, "invalid transition from #{inspect(status)} via #{inspect(event)}"}
  end

  @spec set_thinking_level(t(), :off | :minimal | :low | :medium | :high) :: t()
  def set_thinking_level(%__MODULE__{} = lc, level)
      when level in [:off, :minimal, :low, :medium, :high] do
    %{lc | thinking_level: level}
  end

  @spec set_model(t(), String.t() | nil) :: t()
  def set_model(%__MODULE__{} = lc, model) do
    %{lc | model_override: model}
  end

  @spec set_verbose(t(), :off | :on) :: t()
  def set_verbose(%__MODULE__{} = lc, level) when level in [:off, :on] do
    %{lc | verbose_level: level}
  end

  @spec set_group_activation(t(), :mention | :always) :: t()
  def set_group_activation(%__MODULE__{} = lc, mode) when mode in [:mention, :always] do
    %{lc | group_activation: mode}
  end

  @spec idle?(t()) :: boolean()
  def idle?(%__MODULE__{last_activity: nil}), do: false

  def idle?(%__MODULE__{last_activity: last}) do
    DateTime.diff(DateTime.utc_now(), last, :millisecond) > @idle_threshold_ms
  end

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{status: :expired}), do: true
  def expired?(%__MODULE__{last_activity: nil}), do: false

  def expired?(%__MODULE__{last_activity: last}) do
    DateTime.diff(DateTime.utc_now(), last, :millisecond) > @expire_threshold_ms
  end

  defp touch(%__MODULE__{} = lc) do
    %{lc | last_activity: DateTime.utc_now()}
  end
end
