--- Tool Executor module for handling tool calls and search API integration
---
--- Centralizes tool execution logic, search API calls, and UI feedback.
--- Provides a clean interface for both stream and non-stream modes.

local logger = require("logger")
local koutil = require("util")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local json = require("rapidjson")
local assistant_utils = require("assistant_utils")
local json_default = assistant_utils.json_default

-- ---------------------------------------------------------------------------
-- External-search two-stage flow (used by handlers that don't natively
-- support web search but want serpapi / tavilyapi integration).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Search API helpers
-- ---------------------------------------------------------------------------

local function serpAPISearchRequest(handler, serpconfig, keywords)
    local base_url = serpconfig.base_url or "https://serpapi.com/search"
    local key      = serpconfig.api_key
    local q        = koutil.urlEncode(keywords)
    local url      = T("%1?engine=google_ai_mode&api_key=%2&q=%3", base_url, key, q)

    local timeout = 45
    local maxtime = 120

    local completed, success, code, content =
        Trapper:dismissableRunInSubprocess(function()
            return assistant_utils.httpRequest(url, timeout, maxtime, nil, nil, nil)
        end, handler.trap_widget)

    if not completed then return false, handler.CODE_CANCELLED end
    if not success or code ~= 200 then return false, content end

    local ok, parsed = pcall(json.decode, content)
    if not ok or not parsed then
        return false, "fail to parse serpapi return"
    end

    if not parsed.reconstructed_markdown and not parsed.references then
        return false, "No relevant search or AI summary results found."
    end

    local segments = {}
    if json_default(parsed.reconstructed_markdown) then
        table.insert(segments, "## Google AI Summary:\n")
        table.insert(segments, parsed.reconstructed_markdown)
        table.insert(segments, "\n")
    end
    if parsed.references and #parsed.references > 0 then
        table.insert(segments, "## Verified Sources (References):")
        table.insert(segments, "LLM Note: Please use these indexes and URLs to generate precise citations if needed.\n")
        for _, ref in ipairs(parsed.references) do
            local idx         = json_default(ref.index, 0)
            local title       = json_default(ref.title, "Untitled Source")
            local link        = json_default(ref.link, "N/A")
            local source_name = json_default(ref.source, "Web")
            table.insert(segments,
                string.format("[%d] %s (%s) - URL: %s", idx, title, source_name, link))
        end
    end

    return true, table.concat(segments, "\n")
end

local function tavilyAPISearchRequest(handler, tavilyconfig, keywords)
    local base_url = tavilyconfig.base_url or "https://api.tavily.com/search"
    local key      = tavilyconfig.api_key

    local requestBodyTable = {
        api_key              = key,
        auto_parameters      = true,
        max_results          = 3,
        search_depth         = "basic",
        include_answer       = true,
        include_raw_content  = false,
        query                = keywords,
    }
    local requestBody = json.encode(requestBodyTable)

    local timeout = 45
    local maxtime = 120

    local completed, success, code, content =
        Trapper:dismissableRunInSubprocess(function()
            return assistant_utils.httpRequest(base_url, timeout, maxtime, requestBody, "application/json", nil)
        end, handler.trap_widget)

    if not completed then return false, handler.CODE_CANCELLED end
    if not success or code ~= 200 then return false, content end

    local ok, parsed = pcall(json.decode, content)
    if not ok or not parsed or not parsed.results then
        return false, "fail to parse tavily return"
    end

    local segments = {}
    if json_default(parsed.answer) then
        table.insert(segments, "## Summary\n")
        table.insert(segments, parsed.answer)
        table.insert(segments, "\n")
    end
    table.insert(segments, "Here are the verified search results from Tavily:\n")
    table.insert(segments, "LLM Note: Use these indexes and URLs to generate precise citations if needed.\n")
    for i, item in ipairs(parsed.results) do
        table.insert(segments, "---")
        table.insert(segments, string.format("### Source %d: %s", i,
            json_default(item.title, "Untitled")))
        table.insert(segments, string.format("* URL: %s", json_default(item.url, "N/A")))
        table.insert(segments, string.format("* Summary: %s", json_default(item.content, "")))
        table.insert(segments, "\n")
    end

    return true, table.concat(segments, "\n")
end

local ToolExecutor = {}

local apitext = {
    ["serpapi"] = "Serp",
    ["tavilyapi"] = "Tavily",
}

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
        text = T(_("Searching with %1:\n\n%2"), apitext[ws_mode], keywords),
    })
    UIManager:show(keywordmsg)
    handler:setTrapWidget(keywordmsg)

    -- Execute search API based on mode
    local search_ok, search_result
    if ws_mode == "serpapi" then
        search_ok, search_result = serpAPISearchRequest(handler, provider_config.serpapi, keywords)
    elseif ws_mode == "tavilyapi" then
        search_ok, search_result = tavilyAPISearchRequest(handler, provider_config.tavilyapi, keywords)
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

-- ---------------------------------------------------------------------------
-- Public interface: buildRawAssistantForToolCall
-- ---------------------------------------------------------------------------

--- Build a raw_assistant structure for a tool call.
--- This factory method ensures all providers format tool calls consistently.
---
--- @param tool_call_id  string  The unique ID for this tool call
--- @param keywords      string  The search keywords extracted
--- @param format        string  "openai" | "anthropic" | "gemini"
--- @param contents      table|nil   table contains "content", "reasoning_content"
--- @return table       raw_assistant structure ready for buildToolResultMessages
function ToolExecutor.buildRawAssistantForToolCall(tool_call_id, keywords, format, contents)
    format = format or "openai"
    
    if format == "anthropic" then
        -- Anthropic expects content_blocks array
        return {
            {
                type  = "tool_use",
                id    = tool_call_id,
                name  = "web_search",
                input = { keywords = keywords },
            },
        }
    elseif format == "gemini" then
        -- Gemini expects a model turn (role="model")
        return {
            role  = "model",
            parts = {
                {
                    functionCall = {
                        name = "web_search",
                        id   = tool_call_id,
                        args = { keywords = keywords },
                    },
                },
            },
        }
    else  -- "openai" (and compatible: groq, openrouter, deepseek, mistral, etc.)
        local raw = {
            role       = "assistant",
            content    = contents and contents.content,
            tool_calls = {
                {
                    id       = tool_call_id,
                    type     = "function",
                    ["function"] = {
                        name      = "web_search",
                        arguments = json.encode({ keywords = keywords }),
                    },
                },
            },
        }
        if contents and contents.reasoning_key and contents.reasoning_content then
            raw[contents.reasoning_key] = contents.reasoning_content
        end
        return raw
    end
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

function ToolExecutor.maximumToolRoundReached()
    local prompt = [[## Force Final Answer After Max Web Search Limit

You have already used the web_search tool the maximum allowed times. You must now STOP making any further web_search calls or any other tool calls that would require additional external searches.

Synthesize a complete, helpful, and well-structured final answer using ONLY the information you have already gathered from previous searches and your internal knowledge. 

Do not mention tool limits, search counts, or the fact that you stopped searching. Present the response naturally as a confident, comprehensive answer to the user's original question. If some aspects remain uncertain due to limited search results, briefly acknowledge that and provide the best possible response based on available data.

Begin writing the final answer now.
]]

    return true, prompt
end

return ToolExecutor
