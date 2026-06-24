local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local https = require("ssl.https")
local Trapper = require("ui/trapper")
local json = require("rapidjson")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local koutil = require("util")
local T = ffiutil.template
local _ = require("assistant_gettext")

local assistant_utils = require("assistant_utils")
local json_default = assistant_utils.json_default

local BaseHandler = {
    trap_widget = nil,  -- widget to trap the request
}

BaseHandler.CODE_CANCELLED          = "USER_CANCELED"
BaseHandler.CODE_NETWORK_ERROR      = "NETWORK_ERROR"
BaseHandler.CODE_TIMEOUT            = "REQUEST_TIMEOUT"
BaseHandler.CODE_UNSUPPORTED_PROTO  = "UNSUPPORTED_PROTOCOL"
BaseHandler.CODE_INCOMPLETE         = "INCOMPLETE_CONTENT"
BaseHandler.CODE_DECOMPRESS_ERROR   = "DECOMPRESS_ERROR"
BaseHandler.CODE_SERVER_ERROR       = "SERVER_ERROR"
BaseHandler.PROTOCOL_NON_200 = "X-NON-200-STATUS:"

function BaseHandler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BaseHandler:setTrapWidget(trap_widget)
    self.trap_widget = trap_widget
end

function BaseHandler:resetTrapWidget()
    local w = self.trap_widget
    self.trap_widget = nil
    return w
end

--- Query method to be implemented by specific handlers.
---
--- Behaviour depends on query_option.use_stream_mode:
---   stream=true  → build request body and return self:backgroundRequest(...) immediately
---                  (a function); never call makeRequest.
---   stream=false → call makeRequest; if LLM returned tool_calls return a table
---                  { tool_calls=<parsed>, messages_to_append=<list> } for the Querier
---                  to merge into message_history and loop; otherwise return the content
---                  string (or nil, err).
---
--- @param message_history  table   conversation history
--- @param provider_setting table   provider-specific config
--- @param query_option     table   { use_stream_mode=boolean, use_websearch=string }
--- @return string|function|table result, string|nil error
function BaseHandler:query(message_history, provider_setting, query_option)
    -- To be implemented by specific handlers
    error("query method must be implemented")
end


--- Make a synchronous HTTP POST request, optionally through a dismissable subprocess.
function BaseHandler:makeRequest(url, headers, body, timeout, maxtime)
    local completed, success, code, content
    if self.trap_widget then
        local request_timeout, request_maxtime
        if body and #body > 10000 then
            request_timeout = timeout or 300
            request_maxtime = maxtime or 120
        else
            request_timeout = timeout or 45
            request_maxtime = maxtime or 120
        end
        completed, success, code, content = Trapper:dismissableRunInSubprocess(function()
                return assistant_utils.httpRequest(url, request_timeout, request_maxtime, body, nil, headers)
            end, self.trap_widget)
        if not completed then
            return false, self.CODE_CANCELLED, content
        end
    else
        success, code, content = assistant_utils.httpRequest(url, timeout or 20, maxtime or 45, body, nil, headers)
    end

    return success, code, content
end

--- Return a background-process function suitable for streaming (subprocess + pipe).
--- The returned function is passed to Querier:processStream via runInSubProcess.
function BaseHandler:backgroundRequest(url, headers, body)

    local function wrap_fd(fd)
        local fo = {}
        function fo:write(chunk)
            ffiutil.writeToFD(fd, chunk)
            return self
        end
        function fo:close() return true end -- mock close method
        return fo
    end

    return function(pid, child_write_fd)
        if not pid or not child_write_fd then
            logger.warn("Invalid parameters for background request")
            return
        end

        if url:sub(1, 5) == "https" then
            https.cert_verify = false -- old devices cannot verify ssl certs
        end

        local request = {
            url    = url,
            method = "POST",
            headers = headers or {},
            source  = ltn12.source.string(body or ""),
            sink    = ltn12.sink.file(wrap_fd(child_write_fd)),
        }
        local code, resp_headers, status = socket.skip(1, http.request(request))
        if code ~= 200 then
            logger.warn("Background request non-200:", code, "status:", status, "url:", url)
            ffiutil.writeToFD(child_write_fd,
                string.format("\r\n%s [%s %s] URL:%s\n\n",
                    self.PROTOCOL_NON_200, status or "", code or "", url))
        end
        ffi.C.close(child_write_fd)
    end
end


-- ---------------------------------------------------------------------------
-- Tool-call parsing helpers (module-local, shared by all handlers via base)
-- ---------------------------------------------------------------------------

--- Parse a stage-1 LLM response and extract tool call details.
--- This is an internal helper called by parseToolCalls().
---
--- Returns: tool_call_id, keywords, raw_assistant, direct_content, error
local function parseStage1Response(responseData, format)
    if format == "anthropic" then
        local content_blocks = responseData.content
        if type(content_blocks) ~= "table" then
            local errmsg = koutil.tableGetValue(responseData, "error", "message")
                        or "Anthropic stage-1: missing content array"
            return nil, nil, nil, nil, errmsg
        end
        local tool_use_block, text_block
        for _, block in ipairs(content_blocks) do
            if type(block) == "table" then
                if block.type == "tool_use" then tool_use_block = block end
                if block.type == "text"     then text_block     = block end
            end
        end
        if not tool_use_block then
            local direct = text_block and tostring(text_block.text) or nil
            return nil, nil, nil, direct, nil
        end
        local tool_id = tostring(tool_use_block.id or "toolu_0")
        local input   = tool_use_block.input or {}
        local kw      = input.keywords
        if not kw then
            return nil, nil, nil, nil, "Anthropic stage-1: tool_use block missing keywords input"
        end
        return tool_id, tostring(kw), content_blocks, nil, nil

    elseif format == "gemini" then
        local parts = koutil.tableGetValue(responseData, "candidates", 1, "content", "parts")
        if type(parts) ~= "table" then
            local errmsg = koutil.tableGetValue(responseData, "error", "message")
                        or "Gemini stage-1: missing content parts"
            return nil, nil, nil, nil, errmsg
        end
        local fn_call, text_part
        for _, part in ipairs(parts) do
            if type(part) == "table" then
                if part.functionCall then fn_call   = part.functionCall end
                if part.text         then text_part  = part              end
            end
        end
        if not fn_call then
            local direct = text_part and tostring(text_part.text) or nil
            return nil, nil, nil, direct, nil
        end
        local call_id = fn_call.id or fn_call.name or "fc_0"
        local args    = fn_call.args or {}
        local kw      = args.keywords
        if not kw then
            return nil, nil, nil, nil, "Gemini stage-1: functionCall missing keywords arg"
        end
        local model_content = koutil.tableGetValue(responseData, "candidates", 1, "content")
        return tostring(call_id), tostring(kw), model_content, nil, nil

    else  -- "openai" (default — shared by groq / openrouter / deepseek / mistral / etc.)
        local assistant_message = koutil.tableGetValue(responseData, "choices", 1, "message")
        if not assistant_message then
            local err_msg = koutil.tableGetValue(responseData, "error", "message")
                         or koutil.tableGetValue(responseData, "message")
                         or "OpenAI stage-1: no message in response"
            logger.warn("stage1 parse, responseData:", responseData)
            return nil, nil, nil, nil, err_msg
        end
        local tool_calls = assistant_message.tool_calls
        if not tool_calls or not tool_calls[1] then
            local direct = assistant_message.content
            return nil, nil, nil, direct and tostring(direct) or nil, nil
        end
        local tc            = tool_calls[1]
        local tool_call_id  = json_default(tc.id, "call_0")
        local arguments_str = koutil.tableGetValue(tc, "function", "arguments") or "{}"
        local arg_ok, args  = pcall(json.decode, arguments_str)
        if not arg_ok or not args or not json_default(args.keywords) then
            return nil, nil, nil, nil,
                "OpenAI stage-1: failed to parse tool_call arguments: " .. arguments_str
        end
        return tool_call_id, args.keywords, assistant_message, nil, nil
    end
end

--- Build the list of messages that must be appended to message_history after a tool call,
--- in the correct wire format for each platform.
---
--- @param raw_assistant  table   platform-specific assistant payload from parseStage1Response
--- @param tool_call_id   string
--- @param search_result  string  markdown text from the search API
--- @param format         string  "openai" | "anthropic" | "gemini"
--- @return table  list of message objects ready to be appended
local function buildToolResultMessages(raw_assistant, tool_call_id, search_result, format)
    local msgs = {}
    if format == "anthropic" then
        table.insert(msgs, {
            role    = "assistant",
            content = raw_assistant,
        })
        table.insert(msgs, {
            role    = "user",
            content = {
                {
                    type        = "tool_result",
                    tool_use_id = tool_call_id,
                    content     = search_result,
                },
            },
        })

    elseif format == "gemini" then
        table.insert(msgs, raw_assistant)   -- model turn (role="model", parts=[functionCall…])
        table.insert(msgs, {
            role  = "user",
            parts = {
                {
                    functionResponse = {
                        name     = "web_search",
                        id       = tool_call_id,
                        response = { result = search_result },
                    },
                },
            },
        })

    else  -- "openai"
        table.insert(msgs, {
            role       = "assistant",
            content    = raw_assistant.content,
            reasoning_content = raw_assistant.reasoning_content,
            tool_calls = { raw_assistant.tool_calls[1] },
        })
        table.insert(msgs, {
            role         = "tool",
            tool_call_id = tool_call_id,
            content      = search_result,
        })
    end
    return msgs
end

-- ---------------------------------------------------------------------------
-- Public interface: parseToolCalls
-- ---------------------------------------------------------------------------

--- Parse a non-streaming LLM response and determine what to do next.
---
--- This is the unified interface called by Querier after every non-stream makeRequest.
--- It inspects the decoded JSON from the LLM and returns one of three outcomes:
---
---   1. The model returned a normal text answer:
---        returns  content_string, nil
---
---   2. The model issued a tool call (web_search):
---        returns  table {
---                   tool_call_id       = string,
---                   keywords           = string,
---                   messages_to_append = list-of-message-objects,  -- append to history
---                 }, nil
---      After appending messages_to_append the caller should repeat the LLM request.
---      The table also carries a  __is_tool_call = true  sentinel so Querier can
---      branch without inspecting the full structure.
---
---   3. An error occurred:
---        returns  nil, error_string
---
--- @param responseData  table   decoded JSON from the LLM (non-stream response)
--- @param format        string  "openai" | "anthropic" | "gemini"
--- @return string|table result, string|nil error
function BaseHandler:parseToolCalls(responseData, format)
    local tool_call_id, keywords, raw_assistant, direct_content, parse_err =
        parseStage1Response(responseData, format)

    if parse_err then
        return nil, parse_err
    end

    -- Model answered without a tool call
    if direct_content then
        return direct_content, nil
    end

    -- Model issued a tool call but we have no search result yet.
    -- Return a descriptor; the Querier will execute the search and loop.
    if keywords then
        -- Build placeholder messages_to_append (search result will be filled in by Querier).
        -- We expose raw_assistant so the Querier can call buildToolResult() once it has results.
        return {
            __is_tool_call  = true,
            tool_call_id    = tool_call_id,
            keywords        = keywords,
            raw_assistant   = raw_assistant,  -- opaque; pass back to buildToolResultMessages
            format          = format,
        }, nil
    end

    return nil, "parseToolCalls: unexpected response (no content, no tool call)"
end

--- Build the messages_to_append list once a search result is available.
--- Called by Querier after it has executed the search API.
---
--- @param tool_call_result  table   the table returned by parseToolCalls (with __is_tool_call)
--- @param search_result     string  markdown text from the search API
--- @return table  list of messages to append to message_history
function BaseHandler:buildToolResultMessages(tool_call_result, search_result)
    return buildToolResultMessages(
        tool_call_result.raw_assistant,
        tool_call_result.tool_call_id,
        search_result,
        tool_call_result.format
    )
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
function BaseHandler:buildExternalSearchToolDef(format)
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
    local description =
        "Search the web for up-to-date information. " ..
        "Use this when the user's question requires current or recent information."

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

return BaseHandler
