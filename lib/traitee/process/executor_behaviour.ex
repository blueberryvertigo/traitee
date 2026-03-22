defmodule Traitee.Process.ExecutorBehaviour do
  @moduledoc "Behaviour for process execution, enabling Mox-based testing."

  @callback run(command :: String.t(), opts :: keyword()) ::
              {:ok, %{stdout: String.t(), exit_code: integer()}} | {:error, term()}
  @callback run_async(command :: String.t(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}
end
