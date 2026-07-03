--- Tool Executor module for handling tool calls and search API integration
---
--- Centralizes tool execution logic, search API calls, and UI feedback.
--- Provides a clean interface for both stream and non-stream modes.

local logger = require("logger")
local koutil = require("util")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local strbuf = require("string.buffer")
local json = require("rapidjson")
local ExtTools = require("assistant_exttools")
local ASUtils = require("assistant_utils")
local json_default = ASUtils.json_default


-- MENU order of search tools
local SEARCH_API_NAMES = {
    "none",
    "builtin",
    "serpapi",
    "tavilyapi",
    "searxngapi"
 }

---- Build the messages_to_append list once a search result is available.
---- Called by Querier after it has executed the search API.
----
---- @param tool_call_result  table   the table returned by parseToolCalls (with __is_tool_call)
---- @param search_result     string  markdown text from the search API
---- @return table  list of messages to append to message_history
local function buildToolResultMessages(tool_call_result)

    local raw_assistant = tool_call_result.raw_assistant
    local format = tool_call_result.format
    local results = tool_call_result.search_results

    local keywords = strbuf.new()
    local msgs = {}
    if format == "anthropic" then
        table.insert(msgs, {
            role    = "assistant",
            content = raw_assistant,
        })
        local contents = {}
        for _, result in ipairs(results) do
            table.insert(contents, {
                    type        = "tool_result",
                    tool_use_id = result.tool_call_id,
                    content     = result.search_result,
                })
            keywords:putf("⌗ %s\n\n", result.search_keywords)
        end

        ASUtils.set_attr(msgs[#msgs], "search_keywords", keywords:get())
        table.insert(msgs, {
            role    = "user",
            content = contents,
        })
    elseif format == "gemini" then
        table.insert(msgs, raw_assistant)   -- model turn (role="model", parts=[functionCall…])

        local parts = {}
        for _, result in ipairs(results) do
            table.insert(parts, {
                    functionResponse = {
                        name     = "web_search",
                        id       = result.tool_call_id,
                        response = { result = result.search_result },
                    },
                })
            keywords:putf("⌗ %s\n\n", result.search_keywords)
        end
        ASUtils.set_attr(msgs[#msgs], "search_keywords", keywords:get())
        table.insert(msgs, { role  = "user", parts = parts, })

    else  -- "openai"
        table.insert(msgs, raw_assistant)
        local pos = #msgs
        for _, result in ipairs(results) do
            table.insert(msgs, {
                role         = "tool",
                tool_call_id = result.tool_call_id,
                content      = result.search_result,
            })
            keywords:putf("⌗ %s\n\n", result.search_keywords)
        end
        ASUtils.set_attr(msgs[pos], "search_keywords", keywords:get())
    end
    return msgs
end


local ToolExecutor = {}
ToolExecutor.SEARCH_API_NAMES = SEARCH_API_NAMES

--- Exposed func to set module variable
function ToolExecutor.SetSearchAPIConfig(CONFIGURATION)
    for api, tool in pairs(ExtTools) do
        local c = koutil.tableGetValue(CONFIGURATION, "provider_settings", api)
        if c then
            if c.api_key then tool.api_key = c.api_key end
            if c.base_url then tool.base_url = c.base_url:gsub("/+$", "") end -- trim the ending `/`
        end
    end
end

function ToolExecutor.IsExtSearch(key)
    return ExtTools[key].is_external
end

function ToolExecutor.ToolToText(key)
    return ExtTools[key].name
end


--- Execute a web search using the configured search service.
---
--- Handles UI feedback (keyword search indicator) internally.
---
--- @param keywords           string  search query keywords
--- @param ws_mode            string  "serpapi" | "tavilyapi"
--- @param handler            table   BaseHandler instance with search methods
--- @param tool_round         integer  Notice for the number of rounds the tool called
--- @return boolean success, string result
function ToolExecutor.executeWebSearch(keywords, ws_mode, handler, tool_round)
    if not keywords or #keywords == 0 then
        return false, _("Search keywords are empty.")
    end

    -- Show search indicator
    UIManager:close(handler:resetTrapWidget())
    local keywordmsg = InfoMessage:new({
        face = Font:getFace("smallinfofont"),
        icon = "appbar.search",
        text = T(_("Searching with %1 ... [%2]\n\n%3"), ToolExecutor.ToolToText(ws_mode), tool_round, keywords),
    })
    UIManager:show(keywordmsg)

    -- Execute search API based on mode
    local search_ok, search_result
    local API = ExtTools[ws_mode]
    if not API then
        UIManager:close(keywordmsg)
        return false, "Unknown web-search mode: " .. tostring(ws_mode)
    end
    search_ok, search_result = API:SearchKeywords(keywords, keywordmsg)
    if search_ok and type(search_result) == "string" then
        -- remove URLs saving context length
        search_result = search_result:gsub("https?://[%w%-%.%?%&%=%/%~_#:;+,@!$%'()*]+", "")
    end

    UIManager:close(keywordmsg)
    return search_ok, search_result
end

-- ---------------------------------------------------------------------------
-- Public interface: buildRawAssistantForToolCall
-- ---------------------------------------------------------------------------

--- Build a raw_assistant structure for a tool call.
--- This factory method ensures all providers format tool calls consistently.
---
--- @param tool_calls    table  The search tool_call_array
--- @param format        string  "openai" | "anthropic" | "gemini"
--- @param contents      table|nil   table contains "content", "reasoning_content"
--- @return boolean ok, table|string raw_assistant structure ready for buildToolResultMessages
function ToolExecutor.buildRawAssistantForToolCall(tool_calls, format, contents)
    format = format or "openai"
    
    if format == "anthropic" then
        -- Anthropic expects content_blocks array
        local ret = {}
        if contents and contents.reasoning_content then
            local tc = { type = "thinking", thinking = contents.reasoning_content, }
            if contents.signature then
                tc.signature = contents.signature
            end
            table.insert(ret, tc)
        end
        for _, tc in ipairs(tool_calls) do
            local id, kw, err = ToolExecutor.extractKeywords(tc)
            if err then
                return false, err
            end
            table.insert(ret, {
                    type  = "tool_use",
                    id    = id,
                    name  = "web_search",
                    input = { keywords = kw },
            })
        end
        return true, ret
    elseif format == "gemini" then
        -- Gemini expects a model turn (role="model")
        local parts = {}
        for _, tc in ipairs(tool_calls) do
            table.insert(parts, {
                    functionCall = {
                        name = "web_search",
                        id   = tc.tool_call_id,
                        args = { keywords = tc.keywords },
                    },
                })
            if contents and contents.signature then
                parts[#parts].thoughtSignature = contents.signature
            end
        end
        return true, { role  = "model", parts = parts, }
    else  -- "openai" (and compatible: groq, openrouter, deepseek, mistral, etc.)
        local raw_tool_calls = {}
        for _, tc in ipairs(tool_calls) do
            table.insert(raw_tool_calls, {
                    id        = tc.id,
                    type     = "function",
                    ["function"] = {
                        name      = tc.name,
                        arguments = tc.arguments,
                    },
                })
        end
        local raw = {
            role       = "assistant",
            content    = contents and contents.content,
            tool_calls = raw_tool_calls,
        }
        if contents and contents.reasoning_key and contents.reasoning_content then
            raw[contents.reasoning_key] = contents.reasoning_content
        end
        return true, raw
    end
end


--- Build tool result messages and append them to message history.
---
--- @param message_history    table   conversation history (modified in place)
--- @param tool_call_result   table   tool call descriptor with keywords, raw_assistant, format
--- @return boolean success, string|nil error
function ToolExecutor.appendToolResult(message_history, tool_call_result)

    if not tool_call_result then
        return false, "Invalid tool_call_result structure"
    end

    local tool_msgs = buildToolResultMessages(tool_call_result)
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
--- @return string|nil id, string|nil keywords, string|nil error
function ToolExecutor.extractKeywords(tool_call)
    local keywords = nil
    local id = nil

    if tool_call.args then
        -- Gemini: args is already a table
        id = tool_call.tool_call_id or tool_call.id
        keywords = tool_call.args.keywords
        if type(keywords) == "table" and #keywords > 0 then
            keywords = keywords[1] -- needs to be a string
        end
    elseif tool_call.arguments then
        -- OpenAI: arguments is a JSON string
        local ok_j, args = pcall(json.decode, tool_call.arguments)
        if ok_j and type(args) == "table" then
            keywords = json_default(args.keywords) or json_default(args.query)
        end
        id = tool_call.tool_call_id or tool_call.id
    elseif tool_call.input then
        -- Anthropic
        id = tool_call.id
        keywords = tool_call.input.keywords
    end

    if not id then
        return nil, nil, _("Tool call did not include id.")
    end
    if not keywords or #keywords == 0 then
        return nil, nil, _("Tool call did not include search keywords.")
    end

    return id, keywords, nil
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

-- ---------------------------------------------------------------------------
-- Tool-call parsing helpers
-- ---------------------------------------------------------------------------

--- Parse a LLM response and extract tool call details. (for NON-STREAM response)
---
--- Returns: {tool_calls_array}, raw_assistant, direct_content, error
function ToolExecutor.parseToolCallsResponse(responseData, format)
    if format == "anthropic" then
        local content_blocks = responseData.content
        if type(content_blocks) ~= "table" then
            local errmsg = koutil.tableGetValue(responseData, "error", "message")
                        or "Anthropic stage-1: missing content array"
            return nil, nil, nil, errmsg
        end

        local text_block
        local toolcall_blocks = {}
        for _, block in ipairs(content_blocks) do
            if type(block) == "table" then
                if block.type == "text" then
                    text_block = block
                end
                if block.type == "tool_use" and block.input and block.input.keywords then
                    table.insert(toolcall_blocks, block)
                end
            end
        end
        if text_block and #toolcall_blocks == 0 then
            local direct = text_block and text_block.text or nil
            return nil, nil, direct, nil
        end
        return toolcall_blocks, content_blocks, nil, nil

    elseif format == "gemini" then
        local model_content = koutil.tableGetValue(responseData, "candidates", 1, "content")
        if not model_content then
            local err_msg = koutil.tableGetValue(responseData, "error", "message")
                         or koutil.tableGetValue(responseData, "message")
                         or "Gemini: missing content"
            logger.warn("Gemini parse, responseData:", responseData)
            return nil, nil, nil, err_msg
        end
        local tool_calls = {}
        local text_part
        for _, part in ipairs(model_content.parts) do
            if type(part) == "table" then
                if part.functionCall then 
                    local fn_call   = part.functionCall 
                    table.insert(tool_calls, {
                        tool_call_id = fn_call.id or fn_call.name,
                        args = fn_call.args
                    })
                end
                if part.text         then text_part  = part              end
            end
        end

        if #tool_calls == 0 then
            local direct = text_part and text_part.text or nil
            return nil, model_content, direct, nil
        end
        return tool_calls, model_content, nil, nil

    else  -- "openai" (default — shared by groq / openrouter / deepseek / mistral / etc.)
        local assistant_message = koutil.tableGetValue(responseData, "choices", 1, "message")
        if not assistant_message then
            local err_msg = koutil.tableGetValue(responseData, "error", "message")
                         or koutil.tableGetValue(responseData, "message")
                         or "OpenAI stage-1: no message in response"
            logger.warn("parse, responseData:", responseData)
            return nil, nil, nil, err_msg
        end
        local raw_calls = assistant_message.tool_calls
        if not raw_calls then
            local direct = assistant_message.content
            return nil, nil, direct, nil
        end

        local tool_calls = {}
        for _, tc in ipairs(raw_calls) do
            local arguments_str = koutil.tableGetValue(tc, "function", "arguments") or "{}"
            table.insert(tool_calls, {
                tool_call_id = tc.id,
                name = koutil.tableGetValue(tc, "function", "name"),
                arguments = arguments_str,
            })
        end

        return tool_calls, assistant_message, nil, nil
    end
end

-- ---------------------------------------------------------------------------
-- Tool definition builders
-- ---------------------------------------------------------------------------

--- Build the web_search tool definition in the format required by a given platform.
---
--- format = "openai"     → OpenAI function calling shape
--- format = "anthropic"  → Anthropic tool shape
--- format = "gemini"     → Gemini function_declarations shape
---
--- @param format string  "openai" | "anthropic" | "gemini"
--- @return table tool definition
function ToolExecutor.buildExternalSearchToolDef(format)
    local param_schema = {
        type = "object",
        properties = {
            keywords = {
                type = "string",
                description = "Concise search query keywords extracted from the user's question",
            },
        },
        required = { "keywords" },
    }
    local description = [[Search the web for up-to-date information. 
Use this when the user's question requires current or recent information. 
Return exactly one concise search query string.]]

    if format == "anthropic" then
        return {
            name         = "web_search",
            description  = description,
            input_schema = param_schema,
        }
    elseif format == "gemini" then
        return {
            function_declarations = {
                {
                    name        = "web_search",
                    description = description,
                    parameters  = param_schema,
                },
            },
        }
    else  -- "openai"
        return {
            type = "function",
            ["function"] = {
                name        = "web_search",
                description = description,
                parameters  = param_schema,
            },
        }
    end
end

return ToolExecutor
