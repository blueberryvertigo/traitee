defmodule Traitee do
  @moduledoc """
  Traitee - Compact AI assistant with hierarchical memory and token optimization.

  A personal AI assistant built on Elixir/OTP, leveraging the BEAM VM's actor model
  for natural session isolation and fault tolerance. Designed as a lean, high-performance
  alternative to sprawling TypeScript-based assistants.

  ## Key Features

  - **Hierarchical Memory** -- Short-term (ETS), mid-term (summaries), long-term (knowledge graph)
  - **Token Optimization** -- Budget-aware context assembly that minimizes API costs
  - **Multi-Channel** -- Discord, Telegram, WhatsApp, Signal, CLI, WebChat
  - **Fault Tolerant** -- OTP supervisors isolate failures per session/channel
  """

  @doc """
  Returns the path to the Traitee data directory.
  """
  def data_dir do
    System.get_env("TRAITEE_DATA_DIR") || Path.expand("~/.traitee")
  end

  @doc """
  Returns the path to the config file.
  """
  def config_path do
    System.get_env("TRAITEE_CONFIG") || Path.join(data_dir(), "config.toml")
  end
end
