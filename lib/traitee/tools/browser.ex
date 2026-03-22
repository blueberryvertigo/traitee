defmodule Traitee.Tools.Browser do
  @moduledoc """
  Full browser automation tool powered by Playwright via the Browser.Bridge.
  Supports navigation, accessibility snapshots, clicking, typing, screenshots,
  JS evaluation, and tab management.
  """

  @behaviour Traitee.Tools.Tool

  alias Traitee.Browser.Bridge

  @impl true
  def name, do: "browser"

  @impl true
  def description do
    """
    Control a real browser (Chromium). You can navigate to URLs, read page content \
    via accessibility snapshots, click elements, type text, fill forms, take screenshots, \
    run JavaScript, and manage tabs. Use 'navigate' then 'snapshot' to read a page. \
    Use 'click' and 'type' to interact with elements shown in the snapshot.\
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => [
            "navigate",
            "snapshot",
            "click",
            "type",
            "fill",
            "screenshot",
            "evaluate",
            "get_text",
            "press_key",
            "list_tabs",
            "new_tab",
            "close_tab"
          ],
          "description" => "Browser action to perform"
        },
        "url" => %{
          "type" => "string",
          "description" => "URL to navigate to (for navigate/new_tab)"
        },
        "selector" => %{
          "type" => "string",
          "description" => "CSS selector for targeting elements (for click/type/fill/get_text)"
        },
        "text" => %{
          "type" => "string",
          "description" => "Text to type, or visible text to click on"
        },
        "value" => %{
          "type" => "string",
          "description" => "Value for fill action"
        },
        "expression" => %{
          "type" => "string",
          "description" => "JavaScript expression to evaluate"
        },
        "key" => %{
          "type" => "string",
          "description" => "Key to press (Enter, Tab, Escape, etc.)"
        },
        "pageId" => %{
          "type" => "integer",
          "description" => "Target page/tab ID (optional, defaults to active tab)"
        },
        "fullPage" => %{
          "type" => "boolean",
          "description" => "Capture full scrollable page for screenshot"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "navigate", "url" => url} = args) when is_binary(url) do
    params = %{"url" => url}
    params = maybe_put(params, "pageId", args["pageId"])

    case Bridge.call(:navigate, params) do
      {:ok, result} ->
        {:ok, "Navigated to #{result["url"]} (\"#{result["title"]}\") [page #{result["pageId"]}]"}

      {:error, reason} ->
        {:error, "Navigation failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => "navigate"}) do
    {:error, "Missing required parameter: url"}
  end

  def execute(%{"action" => "snapshot"} = args) do
    params = maybe_put(%{}, "pageId", args["pageId"])

    case Bridge.call(:snapshot, params) do
      {:ok, %{"snapshot" => snapshot, "url" => url, "title" => title}} ->
        {:ok, "Page: #{title} (#{url})\n\nAccessibility Tree:\n#{snapshot}"}

      {:error, reason} ->
        {:error, "Snapshot failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => "click"} = args) do
    params =
      %{}
      |> maybe_put("selector", args["selector"])
      |> maybe_put("text", args["text"])
      |> maybe_put("pageId", args["pageId"])

    if params["selector"] == nil && params["text"] == nil do
      {:error, "Either 'selector' or 'text' is required for click"}
    else
      case Bridge.call(:click, params) do
        {:ok, _} -> {:ok, "Clicked successfully. Use 'snapshot' to see the updated page."}
        {:error, reason} -> {:error, "Click failed: #{format_error(reason)}"}
      end
    end
  end

  def execute(%{"action" => "type", "text" => text} = args) when is_binary(text) do
    params =
      %{"text" => text}
      |> maybe_put("selector", args["selector"])
      |> maybe_put("pageId", args["pageId"])

    case Bridge.call(:type, params) do
      {:ok, _} -> {:ok, "Typed text successfully."}
      {:error, reason} -> {:error, "Type failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => "type"}) do
    {:error, "Missing required parameter: text"}
  end

  def execute(%{"action" => "fill", "selector" => sel, "value" => val} = args)
      when is_binary(sel) and is_binary(val) do
    params =
      %{"selector" => sel, "value" => val}
      |> maybe_put("pageId", args["pageId"])

    case Bridge.call(:fill, params) do
      {:ok, _} -> {:ok, "Filled '#{sel}' with value."}
      {:error, reason} -> {:error, "Fill failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => "fill"}) do
    {:error, "Missing required parameters: selector, value"}
  end

  def execute(%{"action" => "screenshot"} = args) do
    params =
      %{}
      |> maybe_put("fullPage", args["fullPage"])
      |> maybe_put("pageId", args["pageId"])

    case Bridge.call(:screenshot, params) do
      {:ok, result} ->
        {:ok, "Screenshot taken (#{result["size"]} bytes, #{result["format"]})."}

      {:error, reason} ->
        {:error, "Screenshot failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => "evaluate", "expression" => expr} = args) when is_binary(expr) do
    params =
      %{"expression" => expr}
      |> maybe_put("pageId", args["pageId"])

    case Bridge.call(:evaluate, params) do
      {:ok, %{"result" => result}} -> {:ok, "Result: #{result}"}
      {:error, reason} -> {:error, "Evaluate failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => "evaluate"}) do
    {:error, "Missing required parameter: expression"}
  end

  def execute(%{"action" => "get_text"} = args) do
    params =
      %{}
      |> maybe_put("selector", args["selector"])
      |> maybe_put("pageId", args["pageId"])

    case Bridge.call(:get_text, params) do
      {:ok, %{"text" => text}} -> {:ok, text}
      {:error, reason} -> {:error, "Get text failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => "press_key", "key" => key} = args) when is_binary(key) do
    params =
      %{"key" => key}
      |> maybe_put("pageId", args["pageId"])

    case Bridge.call(:press_key, params) do
      {:ok, _} -> {:ok, "Pressed #{key}."}
      {:error, reason} -> {:error, "Press key failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => "press_key"}) do
    {:error, "Missing required parameter: key"}
  end

  def execute(%{"action" => "list_tabs"}) do
    case Bridge.call(:list_tabs) do
      {:ok, %{"tabs" => tabs}} ->
        if tabs == [] do
          {:ok, "No open tabs."}
        else
          lines =
            Enum.map(tabs, fn t ->
              "  [#{t["pageId"]}] #{t["title"]} - #{t["url"]}"
            end)

          {:ok, "Open tabs:\n#{Enum.join(lines, "\n")}"}
        end

      {:error, reason} ->
        {:error, "List tabs failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => "new_tab"} = args) do
    params = maybe_put(%{}, "url", args["url"])

    case Bridge.call(:new_tab, params) do
      {:ok, result} ->
        {:ok, "Opened new tab [#{result["pageId"]}]: #{result["url"]}"}

      {:error, reason} ->
        {:error, "New tab failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => "close_tab"} = args) do
    params = maybe_put(%{}, "pageId", args["pageId"])

    case Bridge.call(:close_tab, params) do
      {:ok, _} -> {:ok, "Tab closed."}
      {:error, reason} -> {:error, "Close tab failed: #{format_error(reason)}"}
    end
  end

  def execute(%{"action" => action}) do
    {:error,
     "Unknown action: #{action}. Supported: navigate, snapshot, click, type, fill, screenshot, evaluate, get_text, press_key, list_tabs, new_tab, close_tab"}
  end

  def execute(_), do: {:error, "Missing required parameter: action"}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(:timeout), do: "operation timed out"
  defp format_error(reason), do: inspect(reason)
end
