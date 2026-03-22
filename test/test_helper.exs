ExUnit.start(exclude: [:integration, :live, :slow])

Ecto.Adapters.SQL.Sandbox.mode(Traitee.Repo, :manual)

Mox.defmock(Traitee.LLM.RouterMock, for: Traitee.LLM.RouterBehaviour)
Mox.defmock(Traitee.Process.ExecutorMock, for: Traitee.Process.ExecutorBehaviour)
