local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local https = require("ssl.https")
local Trapper = require("ui/trapper")
local json = require("rapidjson")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local koutil = require("util")
local T = ffiutil.template
local _ = require("assistant_gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local assistant_utils = require("assistant_utils")

-- default_value for rapidjson decoded object
local function json_default(value, default_value)
    if value == nil or value == json.null then
        return default_value
    end
    return value
end

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

--- Query method to be implemented by specific handlers
--- @param message_history table: conversation history, a list of messages
--- @param provider_setting table: settings for the specific provider
--- @return string response_content, string error_message
function BaseHandler:query(message_history, provider_setting, query_option)
    -- To be implemented by specific handlers
    error("query method must be implemented")
end

local function httpRequest(url, timeout, maxtime, post_body, post_content_type, headers)
    local parsed = socket_url.parse(url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return false, BaseHandler.CODE_UNSUPPORTED_PROTO, "Unsupported protocol"
    end
    if parsed.scheme == "https" then
        https.cert_verify = false
    end
    if not timeout then timeout = 10 end
    socketutil:set_timeout(timeout, maxtime or 30)

    if not headers then
        headers = {}
    end
    headers["Accept-Encoding"] = "gzip"

    local sink = {}
    local request = {
        url     = url,
        method  = post_body and "POST" or "GET",
        headers = headers,
        sink    = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
    }
    if post_body then
        local body = type(post_body) == "table" and socketutil.form_encode(post_body) or post_body
        request.source = ltn12.source.string(body)
        headers["Content-Type"]   = headers["Content-Type"] or post_content_type or "application/x-www-form-urlencoded"
        headers["Content-Length"] = headers["Content-Length"] or tostring(#body)
    end

    local code, resp_headers, status = socket.skip(1, http.request(request))
    local content = table.concat(sink)
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE or
       code == socketutil.SSL_HANDSHAKE_CODE or
       code == socketutil.SINK_TIMEOUT_CODE
    then
        logger.warn("request interrupted:", code)
        return false, BaseHandler.CODE_TIMEOUT, "Request interrupted/timed out"
    end
    if resp_headers == nil then
        logger.warn("No HTTP headers:", status or code or "network unreachable")
        return false, BaseHandler.CODE_NETWORK_ERROR, "Network Error: " .. (status or code)
    end
    if not code then
        logger.warn("HTTP status not okay:", status or code or "network unreachable")
        logger.dgb("Response headers:", resp_headers)
        return false, code, content or "Remote server error or unavailable"
    end

    local http_len = assistant_utils.http_get_header(resp_headers, "content-length")
    if http_len then
        if #content ~= tonumber(http_len) then
            return false, BaseHandler.CODE_INCOMPLETE, "Incomplete content received"
        end
    end

    if assistant_utils.http_is_encoded(resp_headers, "gzip") then
        local decompressed, err = assistant_utils.zlib_uncompress_gzip(content, 8*1024*1024)
        if not decompressed then
            logger.warn("Failed to decompress data:", err)
            return false, BaseHandler.CODE_DECOMPRESS_ERROR, "Failed to decompress data: " .. tostring(err)
        end
        content = decompressed
    end

    return true, code, content
end

--- func description: Make a request to the specified URL with headers and body.
function BaseHandler:makeRequest(url, headers, body, timeout, maxtime)
    local completed, success, code, content
    if self.trap_widget then
        -- Use larger timeout and maxtime when running a large book analysis
        local request_timeout, request_maxtime
        if body and #body > 10000 then
            request_timeout = timeout or 300
            request_maxtime = maxtime or 120
        else
            request_timeout = timeout or 45
            request_maxtime = maxtime or 120
        end
        -- If a trap widget is set, run the request in a subprocess
        completed, success, code, content = Trapper:dismissableRunInSubprocess(function()
                return httpRequest(url, request_timeout, request_maxtime, body, nil, headers)
            end, self.trap_widget)
        if not completed then
            return false, self.CODE_CANCELLED, content
        end
    else
        -- If no trap widget is set, run the request directly
        -- use smaller timeout because we are blocking the UI
        success, content = httpRequest(url, timeout or 20, maxtime or 45, body, nil, headers)
    end

    return success, code, content
end

--- Wrap a file descriptor into a Lua file-like object
--- that has :write() and :close() methods, suitable for ltn12.
--- @param fd integer file descriptor
--- @return table file-like object
local function wrap_fd(fd)
    local file_object = {}
    function file_object:write(chunk)
        ffiutil.writeToFD(fd, chunk)
        return self
    end

    function file_object:close()
        -- null close op,
        -- we need to use the fd later, then close manually
        return true
    end

    return file_object
end

-- Background request function
--- This function is used to make a request in the background,
--- typically in a subprocess, and write the response to a pipe.
function BaseHandler:backgroundRequest(url, headers, body)
    return function(pid, child_write_fd)
        if not pid or not child_write_fd then
            logger.warn("Invalid parameters for background request")
            return
        end

        local pipe_w = wrap_fd(child_write_fd)  -- wrap the write end of the pipe
        local request = {
            url = url,
            method = "POST",
            headers = headers or {},
            source = ltn12.source.string(body or ""),
            sink = ltn12.sink.file(pipe_w),  -- response body write to pipe
        }
        local code, headers, status = socket.skip(1, http.request(request)) -- skip the first return value
        if code ~= 200 then -- non-200 response code, write error to pipe
            logger.warn("Background request non-200:", code, "status:", status, "url:", url)
            ffiutil.writeToFD(child_write_fd, string.format("\r\n%s [%s %s] URL:%s\n\n", self.PROTOCOL_NON_200, status or "", code or "", url))  -- write end of response
        end
        ffi.C.close(child_write_fd)  -- close the write end of the pipe
    end
end


--- Build the web_search tool definition in the format required by a given platform.
---
--- format = "openai"     → OpenAI function calling shape (groq/openrouter/openai/azure/
---                          mistral/deepseek/gigachat/ollama all speak this dialect)
--- format = "anthropic"  → Anthropic tool shape (name + description + input_schema)
--- format = "gemini"     → Gemini function_declarations shape
---
--- @param format string  "openai" | "anthropic" | "gemini"
--- @return table tool definition ready to embed in the request body
function BaseHandler:buildExternalSearchToolDef(format)
    -- Shared parameter schema (OpenAPI subset, accepted by all three platforms)
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
    local description = "Search the web for up-to-date information. Use this when the user's question requires current or recent information."

    if format == "anthropic" then
        return {
            name        = "web_search",
            description = description,
            input_schema = param_schema,
        }
    elseif format == "gemini" then
        -- Gemini wraps all functions inside a function_declarations list
        return {
            function_declarations = {
                {
                    name        = "web_search",
                    description = description,
                    parameters  = param_schema,
                },
            },
        }
    else
        -- "openai" (default) — used by all OpenAI-compatible handlers
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

--- Parse the stage-1 LLM response and extract (tool_call_id, keywords, raw_assistant_data).
--- Returns platform-specific raw assistant data needed to reconstruct the message history.
---
--- @param responseData table  decoded JSON response from the LLM
--- @param format string       "openai" | "anthropic" | "gemini"
--- @return string|nil tool_call_id
--- @return string|nil keywords
--- @return table|nil  raw assistant payload (format-specific)
--- @return string|nil direct_content (set when model replied without a tool call)
--- @return string|nil error
local function parseStage1Response(responseData, format)
    if format == "anthropic" then
        -- Anthropic: stop_reason == "tool_use", content is an array of blocks
        local content_blocks = responseData.content
        if type(content_blocks) ~= "table" then
            local errmsg = koutil.tableGetValue(responseData, "error", "message") or "Anthropic stage-1: missing content array"
            return nil, nil, nil, nil, errmsg
        end
        local tool_use_block = nil
        local text_block     = nil
        for _, block in ipairs(content_blocks) do
            if type(block) == "table" then
                if block.type == "tool_use"  then tool_use_block = block end
                if block.type == "text"      then text_block     = block end
            end
        end
        if not tool_use_block then
            -- Model answered directly
            local direct = text_block and tostring(text_block.text) or nil
            return nil, nil, nil, direct, nil
        end
        local tool_id = tostring(tool_use_block.id or "toolu_0")
        local input   = tool_use_block.input or {}
        local kw      = input.keywords
        if not kw then
            return nil, nil, nil, nil, "Anthropic stage-1: tool_use block missing keywords input"
        end
        -- raw assistant payload = original content blocks array (including the tool_use block)
        return tool_id, tostring(kw), content_blocks, nil, nil

    elseif format == "gemini" then
        -- Gemini: candidates[1].content.parts contains functionCall objects
        local parts = koutil.tableGetValue(responseData, "candidates", 1, "content", "parts")
        if type(parts) ~= "table" then
            local errmsg = koutil.tableGetValue(responseData, "error", "message") or "Gemini stage-1: missing content parts"
            return nil, nil, nil, nil, errmsg
        end
        local fn_call  = nil
        local text_part = nil
        for _, part in ipairs(parts) do
            if type(part) == "table" then
                if part.functionCall  then fn_call   = part.functionCall  end
                if part.text          then text_part  = part               end
            end
        end
        if not fn_call then
            local direct = text_part and tostring(text_part.text) or nil
            return nil, nil, nil, direct, nil
        end
        -- fn_call.id may be nil on older Gemini models; fall back to fn_call.name
        local call_id = fn_call.id or fn_call.name or "fc_0"
        local args    = fn_call.args or {}
        local kw      = args.keywords
        if not kw then
            return nil, nil, nil, nil, "Gemini stage-1: functionCall missing keywords arg"
        end
        -- raw assistant payload = the model content object (role + parts) to replay
        local model_content = koutil.tableGetValue(responseData, "candidates", 1, "content")
        return tostring(call_id), tostring(kw), model_content, nil, nil

    else
        -- "openai" (default)
        local assistant_message = koutil.tableGetValue(responseData, "choices", 1, "message")
        if not assistant_message then
            local err_msg = koutil.tableGetValue(responseData, "error", "message") or -- OpenAI error
                            koutil.tableGetValue(responseData, "message") or -- mistrial error
                            "OpenAI stage-1: no message in response"
            logger.warn("stage1_body", responseData)
            return nil, nil, nil, nil, err_msg
        end
        local tool_calls = assistant_message.tool_calls
        if not tool_calls or not tool_calls[1] then
            -- Model answered directly
            local direct = assistant_message.content
            return nil, nil, nil, direct and tostring(direct) or nil, nil
        end
        local tc           = tool_calls[1]
        local tool_call_id = json_default(tc.id, "call_0")
        local arguments_str = koutil.tableGetValue(tc, "function", "arguments") or "{}"
        local arg_ok, args  = pcall(json.decode, arguments_str)
        if not arg_ok or not args or not json_default(args.keywords) then
            return nil, nil, nil, nil, "OpenAI stage-1: failed to parse tool_call arguments: " .. arguments_str
        end
        -- raw assistant payload = the full assistant message (preserves tool_calls array)
        return tool_call_id, args.keywords, assistant_message, nil, nil
    end
end

--- Append the stage-1 assistant turn and the tool result to message_history,
--- using the correct format for the target platform.
---
--- @param augmented      table   the list to append to (copy of original message_history)
--- @param raw_assistant  table   platform-specific assistant payload from parseStage1Response
--- @param tool_call_id   string
--- @param search_result  string  markdown text from the search API
--- @param format         string  "openai" | "anthropic" | "gemini"
local function appendToolResult(augmented, raw_assistant, tool_call_id, search_result, format)
    if format == "anthropic" then
        -- Assistant turn: role="assistant", content=<original content blocks array>
        table.insert(augmented, {
            role    = "assistant",
            content = raw_assistant,  -- the full content blocks array (includes tool_use block)
        })
        -- Tool result turn: role="user", content=[{type="tool_result", ...}]
        table.insert(augmented, {
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
        -- Model turn: replay the original model content (role="model", parts=[functionCall...])
        table.insert(augmented, raw_assistant)
        -- Function response turn: role="user", parts=[{functionResponse={name, response, id}}]
        table.insert(augmented, {
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

    else
        -- "openai"
        -- Assistant turn: preserve tool_calls array exactly as returned
        table.insert(augmented, {
            role       = "assistant",
            content    = raw_assistant.content,   -- may be nil; correct per spec
            tool_calls = { raw_assistant.tool_calls[1] }, -- only answered the first call
        })
        -- Tool result turn
        table.insert(augmented, {
            role         = "tool",
            tool_call_id = tool_call_id,
            content      = search_result,
        })
    end
end

--- Two-stage external search flow (serpapi or tavilyapi).
---
--- Stage 1: send a non-streaming request with the web_search tool definition so
---          the LLM can extract search keywords via a tool call.
--- Stage 2: execute the appropriate search API with those keywords, then return
---          an augmented message list ready for the caller's final LLM request.
---
--- @param message_history  table    original conversation history
--- @param provider_setting table    provider config; must contain .serpapi or .tavilyapi
--- @param query_option     table    must contain .use_websearch ("serpapi" | "tavilyapi")
--- @param build_request_fn function(messages, tools) → requestBody string
--- @param headers          table    HTTP headers for the stage-1 request
--- @param url              string   endpoint URL for the stage-1 request
--- @param format           string   "openai" | "anthropic" | "gemini"
--- @return table|nil augmented_messages, string|nil error_message
function BaseHandler:resolveExternalSearch(message_history, provider_setting, query_option,
                                           build_request_fn, headers, url, format)
    format = format or "openai"

    -- Stage 1: ask the LLM to produce a tool call with search keywords.
    -- Wrap tool_def into the shape each platform expects for body.tools:
    --   openai / anthropic → { tool_def }  (an array with one entry)
    --   gemini             → { tool_def }  (tool_def is {function_declarations=[...]},
    --                                       body.tools is an array of such objects)
    local tool_def    = self:buildExternalSearchToolDef(format)
    local stage1_body = build_request_fn(message_history, { tool_def })

    local status, code, response = self:makeRequest(url, headers, stage1_body)
    if not status then
        if code == self.CODE_CANCELLED then
            return nil, response
        end
        return nil, "External search stage-1 request failed: " .. tostring(code) .. " - " .. tostring(response)
    end

    local ok, responseData = pcall(json.decode, response)
    if not ok or not responseData then
        return nil, "External search stage-1: failed to parse LLM response"
    end

    local tool_call_id, keywords, raw_assistant, direct_content, parse_err =
        parseStage1Response(responseData, format)

    if parse_err then
        return nil, parse_err
    end

    -- Model chose not to call the tool → return sentinel with the direct text answer
    if direct_content then
        return { __direct_content = direct_content }, nil
    end

    if not keywords then
        return nil, "External search stage-1: LLM did not produce a tool call and gave no text"
    end

    UIManager:close(self:resetTrapWidget())
    local keywordmsg = InfoMessage:new({icon = "appbar.search", text = _("Searching with Keywords:\n\n" .. keywords)})
    UIManager:show(keywordmsg)
    self:setTrapWidget(keywordmsg)

    -- Stage 2: run the external search API
    local ws_mode = query_option.use_websearch
    local search_ok, search_result
    if ws_mode == "serpapi" then
        search_ok, search_result = self:serpAPISearchRequest(provider_setting.serpapi, keywords)
    elseif ws_mode == "tavilyapi" then
        search_ok, search_result = self:tavilyAPISearchRequest(provider_setting.tavilyapi, keywords)
    else
        return nil, "resolveExternalSearch: unknown use_websearch value: " .. tostring(ws_mode)
    end

    if not search_ok then
        return nil, "External search API failed: " .. tostring(search_result)
    end

    -- Build augmented message history
    local augmented = {}
    for _, msg in ipairs(message_history) do
        table.insert(augmented, msg)
    end
    appendToolResult(augmented, raw_assistant, tool_call_id, search_result, format)

    return augmented, nil
end

function BaseHandler:serpAPISearchRequest(serpconfig, keywords)

    local base_url = serpconfig.base_url or "https://serpapi.com/search"
    local key = serpconfig.api_key
    local q = koutil.urlEncode(keywords)
    local url = T("%1?engine=google_ai_mode&api_key=%2&q=%3", base_url, key, q)

    local completed, success, code, content

    local timeout = 45
    local maxtime = 120

    completed, success, code, content = Trapper:dismissableRunInSubprocess(function()
            return httpRequest(url, timeout, maxtime, nil, nil, nil)
        end, self.trap_widget)

    if not completed then
        return false, self.CODE_CANCELLED
    end
    if not success or code ~= 200 then
        return false, content
    end

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
            local idx = json_default(ref.index, 0)
            local title = json_default(ref.title, "Untitled Source")
            local link = json_default(ref.link, "N/A")
            local source_name = json_default(ref.source, "Web")

            local ref_line = string.format("[%d] %s (%s) - URL: %s", idx, title, source_name, link)
            table.insert(segments, ref_line)
        end
    end

    return true, table.concat(segments, "\n")
end

function BaseHandler:tavilyAPISearchRequest(tavilyconfig, keywords)

    local base_url = tavilyconfig.base_url or "https://api.tavily.com/search"
    local key = tavilyconfig.api_key

    local requestBodyTable = {
        ["api_key"] = key,
        ["auto_parameters"] = true,
        ["max_results"] = 3,
        ["search_depth"] = "basic",
        ["include_answer"] = true,
        ["include_raw_content"] = false,
        ["query"] = keywords,
    }
    local requestBody = json.encode(requestBodyTable)

    local completed, success, code, content
    local timeout = 45
    local maxtime = 120

    completed, success, code, content = Trapper:dismissableRunInSubprocess(function()
            return httpRequest(base_url, timeout, maxtime, requestBody, "application/json", nil)
        end, self.trap_widget)

    if not completed then
        return false, self.CODE_CANCELLED
    end
    if not success or code ~= 200 then
        return false, content
    end

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
        table.insert(segments, string.format("### Source %d: %s", i, json_default(item.title, "Untitled")))
        table.insert(segments, string.format("* URL: %s", json_default(item.url, "N/A")))
        table.insert(segments, string.format("* Summary: %s", json_default(item.content, "")))
        table.insert(segments, "\n")
    end

    return true, table.concat(segments, "\n")
end

return BaseHandler
