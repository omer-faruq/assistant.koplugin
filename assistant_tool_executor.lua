--- Tool Executor module for handling tool calls and search API integration
---
--- Centralizes tool execution logic, search API calls, and UI feedback.
--- Provides a clean interface for both stream and non-stream modes.

local logger = require("logger")
local koutil = require("util")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("assistant_gettext")

local ToolExecutor = {}

--- Execute a web search using the configured search service.
---
--- Handles UI feedback (keyword search indicator) internally.
---
--- @param keywords           string  search query keywords
--- @param ws_mode            string  "serpapi" | "tavilyapi"
--- @param provider_config    table   provider settings with .serpapi or .tavilyapi
--- @param handler            table   BaseHandler instance with search methods
--- @return boolean success, string result
function ToolExecutor.executeWebSearch(keywords, ws_mode, provider_config, handler)
    if not keywords or #keywords == 0 then
        return false, _("Search keywords are empty.")
    end

    -- Show search indicator
    UIManager:close(handler:resetTrapWidget())
    local keywordmsg = InfoMessage:new({
        icon = "appbar.search",
        text = _("Searching with Keywords:\n\n" .. keywords),
    })
    UIManager:show(keywordmsg)
    handler:setTrapWidget(keywordmsg)

    -- Execute search API based on mode
    local search_ok, search_result
    if ws_mode == "serpapi" then
        search_ok, search_result = handler:serpAPISearchRequest(provider_config.serpapi, keywords)
    elseif ws_mode == "tavilyapi" then
        search_ok, search_result = handler:tavilyAPISearchRequest(provider_config.tavilyapi, keywords)
    else
        UIManager:close(handler:resetTrapWidget())
        return false, "Unknown web-search mode: " .. tostring(ws_mode)
    end

    UIManager:close(handler:resetTrapWidget())

    if not search_ok then
        return false, "Search API failed: " .. tostring(search_result)
    end

    return true, search_result
end

--- Build tool result messages and append them to message history.
---
--- @param message_history    table   conversation history (modified in place)
--- @param tool_call_result   table   tool call descriptor with keywords, raw_assistant, format
--- @param search_result      string  search API result markdown
--- @param handler            table   BaseHandler instance
--- @return boolean success, string|nil error
function ToolExecutor.appendToolResult(message_history, tool_call_result, search_result, handler)
    if not tool_call_result or not tool_call_result.__is_tool_call then
        return false, "Invalid tool_call_result structure"
    end

    local tool_msgs = handler:buildToolResultMessages(tool_call_result, search_result)
    if not tool_msgs then
        return false, "Failed to build tool result messages"
    end

    for _, msg in ipairs(tool_msgs) do
        table.insert(message_history, msg)
    end

    return true, nil
end

--- Extract keywords from tool call arguments (handles multiple formats).
---
--- Supports:
--- - Gemini: args is already a table
--- - OpenAI/Anthropic: arguments is a JSON string
---
--- @param tool_call       table   single tool call object
--- @return string|nil keywords, string|nil error
function ToolExecutor.extractKeywords(tool_call)
    local keywords = nil
    local rapidjson = require('rapidjson')

    if tool_call.args then
        -- Gemini: args is already a table
        keywords = tool_call.args.query or tool_call.args.keywords
    elseif tool_call.arguments then
        -- OpenAI / Anthropic: arguments is a JSON string
        local ok_j, args = pcall(rapidjson.decode, tool_call.arguments)
        if ok_j and type(args) == "table" then
            keywords = args.query or args.keywords
        end
    end

    if not keywords or #keywords == 0 then
        logger.warn("extractKeywords", tool_call)
        return nil, _("Tool call did not include search keywords.")
    end

    return keywords, nil
end

--- Get the handler format based on handler name.
---
--- @param handler_name string  name of the handler (anthropic, gemini, openai, etc.)
--- @return string format  "anthropic" | "gemini" | "openai"
function ToolExecutor.getHandlerFormat(handler_name)
    if handler_name == "anthropic" then
        return "anthropic"
    elseif handler_name == "gemini" then
        return "gemini"
    else
        -- openai / groq / openrouter / deepseek / mistral / etc.
        return "openai"
    end
end

return ToolExecutor
