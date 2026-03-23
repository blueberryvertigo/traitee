defmodule Traitee.Tools.Registry do
  @moduledoc """
  Tool registry -- collects all tool modules and provides
  lookup + schema generation for LLM function calling.
  Supports both static (compiled) and dynamic (runtime) tools.
  """

  alias Traitee.Tools.Dynamic

  require Logger

  @table :traitee_dynamic_tools

  @tools [
    Traitee.Tools.Bash,
    Traitee.Tools.File,
    Traitee.Tools.WebSearch,
    Traitee.Tools.Browser,
    Traitee.Tools.Memory,
    Traitee.Tools.Sessions,
    Traitee.Tools.Cron,
    Traitee.Tools.ChannelSend,
    Traitee.Tools.SkillManage,
    Traitee.Tools.WorkspaceEdit,
    Traitee.Tools.DelegateTask
  ]

  @doc "Initialize the dynamic tools ETS table and load persisted tools."
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    load_persisted()
    :ok
  end

  @doc "Returns tool schemas in OpenAI function-calling format."
  def tool_schemas do
    static_schemas =
      @tools
      |> Enum.filter(&tool_enabled?/1)
      |> Enum.map(&Traitee.Tools.Tool.to_schema/1)

    dynamic_schemas =
      list_dynamic()
      |> Enum.filter(& &1.enabled)
      |> Enum.map(&Dynamic.to_schema/1)

    static_schemas ++ dynamic_schemas
  end

  @doc "Executes a tool by name with the given arguments."
  def execute(name, args) do
    case find_tool(name) do
      {:static, module} -> module.execute(args)
      {:dynamic, spec} -> Dynamic.execute(spec, args)
      nil -> {:error, "Unknown tool: #{name}"}
    end
  end

  @doc "Finds a tool (static module or dynamic spec) by name."
  def find_tool(name) do
    case Enum.find(enabled_static(), fn mod -> mod.name() == name end) do
      nil -> find_dynamic(name)
      module -> {:static, module}
    end
  end

  @doc "Register a dynamic tool at runtime."
  @spec register_dynamic(String.t(), map()) :: :ok | {:error, String.t()}
  def register_dynamic(name, spec) when is_binary(name) and is_map(spec) do
    static_names = Enum.map(@tools, & &1.name())

    if name in static_names do
      {:error, "Cannot override built-in tool: #{name}"}
    else
      full_spec =
        Map.merge(
          %{
            name: name,
            description: "",
            parameters_schema: %{"type" => "object", "properties" => %{}},
            enabled: true
          },
          spec
        )

      :ets.insert(@table, {name, full_spec})
      persist()
      Logger.info("Dynamic tool registered: #{name}")
      :ok
    end
  end

  @doc "Unregister a dynamic tool."
  @spec unregister_dynamic(String.t()) :: :ok
  def unregister_dynamic(name) when is_binary(name) do
    :ets.delete(@table, name)
    persist()
    Logger.info("Dynamic tool unregistered: #{name}")
    :ok
  end

  @doc "List all dynamic tool specs."
  @spec list_dynamic() :: [map()]
  def list_dynamic do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table) |> Enum.map(fn {_name, spec} -> spec end)
    else
      []
    end
  end

  # -- Private --

  defp enabled_static do
    Enum.filter(@tools, &tool_enabled?/1)
  end

  defp find_dynamic(name) do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, name) do
        [{^name, %{enabled: true} = spec}] -> {:dynamic, spec}
        _ -> nil
      end
    else
      nil
    end
  end

  defp persist do
    tools = list_dynamic()
    serializable = Enum.map(tools, &serialize_spec/1)
    path = persistence_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(serializable, pretty: true))
  rescue
    e ->
      Logger.warning("Failed to persist dynamic tools: #{Exception.message(e)}")
  end

  defp load_persisted do
    path = persistence_path()

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, tools} when is_list(tools) ->
            Enum.each(tools, fn tool ->
              spec = deserialize_spec(tool)
              :ets.insert(@table, {spec.name, spec})
            end)

            Logger.debug("Loaded #{length(tools)} dynamic tool(s) from disk")

          _ ->
            :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to load dynamic tools: #{inspect(reason)}")
    end
  end

  defp serialize_spec(spec) do
    executor =
      case spec.executor do
        {:bash, template} -> %{"type" => "bash", "template" => template}
        {:script, path} -> %{"type" => "script", "path" => path}
        _ -> %{"type" => "unknown"}
      end

    %{
      "name" => spec.name,
      "description" => spec.description,
      "parameters_schema" => spec.parameters_schema,
      "executor" => executor,
      "enabled" => spec.enabled
    }
  end

  defp deserialize_spec(tool) do
    executor =
      case tool["executor"] do
        %{"type" => "bash", "template" => t} -> {:bash, t}
        %{"type" => "script", "path" => p} -> {:script, p}
        _ -> {:bash, "echo 'unknown executor'"}
      end

    %{
      name: tool["name"],
      description: tool["description"] || "",
      parameters_schema: tool["parameters_schema"] || %{},
      executor: executor,
      enabled: tool["enabled"] != false
    }
  end

  defp persistence_path do
    Path.join(Traitee.data_dir(), "dynamic_tools.json")
  end

  defp tool_enabled?(module) do
    tool_name = module.name()

    config =
      case tool_name do
        "bash" -> Traitee.Config.get([:tools, :bash])
        "file" -> Traitee.Config.get([:tools, :file])
        "web_search" -> Traitee.Config.get([:tools, :web_search])
        "browser" -> Traitee.Config.get([:tools, :browser])
        "cron" -> Traitee.Config.get([:tools, :cron])
        "memory" -> %{enabled: true}
        "sessions" -> %{enabled: true}
        "channel_send" -> %{enabled: true}
        "skill_manage" -> %{enabled: true}
        "workspace_edit" -> %{enabled: true}
        "delegate_task" -> Traitee.Config.get([:tools, :delegate_task]) || %{enabled: true}
        _ -> %{enabled: false}
      end

    config[:enabled] != false
  end
end
