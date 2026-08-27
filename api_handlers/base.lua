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

local ToolExecutor = require("assistant_tool_executor")
local ASUtils = require("assistant_utils")
local json_default = ASUtils.json_default

local BaseHandler = {
    name = "BASE",
    base_url = "", model = "", api_key = "",
    additional_parameters = {},
    trap_widget = nil,  -- widget to trap the request
    can_fetch_models = false,
    has_builtin_websearch = false,
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

-- Sync Options from the querier (provider_setting)
--  and the settings for models
function BaseHandler:SyncOptions(querier)
    self.provider_name = querier.provider_name
    self.handler_name = querier.handler_name
    koutil.tableMerge(self, querier.provider_setting)

    -- Normalize base_url: strip known API path suffixes for backward compatibility
    self:normalizeBaseUrl()

    -- Apply user selected model override
    local selected_model = querier.settings:readSetting("selected_model_" .. self.provider_name)
    if selected_model then
        self.model = selected_model
    end
end

function BaseHandler:FetchModels()
end

--- Normalize base_url to a true base URL by stripping known API path suffixes.
--- Handles backward compatibility with old configs that included the full API path
--- (e.g. /chat/completions, /messages, /responses).
--- Called automatically from BaseHandler:SyncOptions; handlers append their own
--- API path suffix when constructing request URLs.
function BaseHandler:normalizeBaseUrl()
    if not self.base_url or self.base_url == "" then return end
    self.base_url = self.base_url
        :gsub("/+$", "")                            -- strip trailing slashes
        :gsub("/chat/completions$", "")             -- strip OpenAI chat path
        :gsub("/messages$", "")                     -- strip Anthropic messages path
        :gsub("/responses$", "")                    -- strip Responses API path
        :gsub("/models/[^/]+:generateContent$", "") -- strip Gemini model:action suffix
        :gsub("/+$", "")                            -- strip trailing slashes again
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
--- @param query_option     table   { use_stream_mode=boolean, use_websearch=string }
--- @return string|function|table result, string|nil error
function BaseHandler:query(message_history, query_option)
    -- To be implemented by specific handlers
    error("query method must be implemented")
end


--- Sanitize a user-supplied timeout value from the provider configuration.
--- Anything that is not a positive number (typos like "60", 0, negatives) is
--- rejected so it cannot produce a broken socket call; the caller falls through
--- to the next tier.
local function valid_timeout(value)
    if type(value) ~= "number" or value <= 0 then return nil end
    return value
end

--- Resolve the effective socket timeouts for a request.
---
--- Both values are resolved independently, so a provider may configure only one
--- of them. Precedence per value:
---   explicit argument  >  provider_settings key  >  the supplied default
---
--- `self.timeout` / `self.maxtime` land on the handler instance automatically:
--- BaseHandler:SyncOptions merges every key of the provider_settings entry onto
--- `self`, so no extra plumbing is needed to expose them.
---
--- @param timeout      number|nil  explicit per-read block timeout
--- @param maxtime      number|nil  explicit total-transfer budget
--- @param def_timeout  number|nil  fallback block timeout
--- @param def_maxtime  number|nil  fallback total budget
--- @return number|nil block_timeout, number|nil total_timeout
function BaseHandler:resolveTimeouts(timeout, maxtime, def_timeout, def_maxtime)
    local block = timeout or valid_timeout(self.timeout) or def_timeout
    local total = maxtime or valid_timeout(self.maxtime) or def_maxtime
    return block, total
end

--- Default per-read block timeout for streaming requests: the maximum gap
--- tolerated between received bytes, which for an LLM is dominated by the wait
--- for the first token (prompt processing on slow local servers).
BaseHandler.DEFAULT_STREAM_BLOCK_TIMEOUT = 120

--- Apply streaming socket timeouts and return the sink to use for the request.
---
--- Called from backgroundRequest implementations, i.e. always inside the forked
--- child process, so the global assignments here cannot leak into the parent.
--- Streaming never had a total-transfer cap and deliberately still does not get
--- one by default -- a long answer that works today must keep working. A total
--- cap is applied only when the provider explicitly configures `maxtime`.
---
--- @param sink function  the ltn12 sink to wrap
--- @return function sink
function BaseHandler:applyStreamTimeouts(sink)
    local block_timeout, total_timeout =
        self:resolveTimeouts(nil, nil, self.DEFAULT_STREAM_BLOCK_TIMEOUT, nil)

    http.TIMEOUT = block_timeout
    -- KOReader routes https through socket.http, but keep ssl.https in sync in
    -- case it services the request directly.
    if https.TIMEOUT then https.TIMEOUT = block_timeout end

    if not total_timeout then return sink end

    local deadline = socket.gettime() + total_timeout
    return function(chunk, err)
        if chunk and socket.gettime() > deadline then
            logger.warn("Background request exceeded total timeout of", total_timeout, "s")
            return nil, "total timeout exceeded"
        end
        return sink(chunk, err)
    end
end

--- Make a synchronous HTTP POST request, optionally through a dismissable subprocess.
function BaseHandler:makeRequest(url, headers, body, timeout, maxtime)
    local completed, success, code, content
    if self.trap_widget then
        local request_timeout, request_maxtime
        if body and #body > 10000 then
            request_timeout, request_maxtime = self:resolveTimeouts(timeout, maxtime, 300, 120)
        else
            request_timeout, request_maxtime = self:resolveTimeouts(timeout, maxtime, 45, 120)
        end
        completed, success, code, content = Trapper:dismissableRunInSubprocess(function()
                return ASUtils.httpRequest(url, request_timeout, request_maxtime, body, nil, headers)
            end, self.trap_widget)
        if not completed then
            return false, self.CODE_CANCELLED, content
        end
    else
        local request_timeout, request_maxtime = self:resolveTimeouts(timeout, maxtime, 20, 45)
        success, code, content = ASUtils.httpRequest(url, request_timeout, request_maxtime, body, nil, headers)
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

        -- Nothing was set here before, so the request inherited whatever global
        -- timeout the parent last left behind (ASUtils.httpRequest calls
        -- socketutil:reset_timeout() after every call), making streaming
        -- timeouts unpredictable. Set them explicitly instead.
        local sink = self:applyStreamTimeouts(ltn12.sink.file(wrap_fd(child_write_fd)))

        local request = {
            url    = url,
            method = "POST",
            headers = headers or {},
            source  = ltn12.source.string(body or ""),
            sink    = sink,
        }
        local code, resp_headers, status = socket.skip(1, http.request(request))
        if code ~= 200 then
            logger.warn("Background request non-200:", code, "status:", status, "url:", url)
            local err_struct = {
                code = code,
                url = url,
                resp_headers = resp_headers,
                status = status,
                raw_body = "",
            }
            ffiutil.writeToFD(child_write_fd, "\r\n")
            ffiutil.writeToFD(child_write_fd, self.PROTOCOL_NON_200)
            ffiutil.writeToFD(child_write_fd, json.encode(err_struct))
            ffiutil.writeToFD(child_write_fd, "\r\n")
        end
        ffi.C.close(child_write_fd)
    end
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
    local tool_calls, raw_assistant, direct_content, parse_err =
        ToolExecutor.parseToolCallsResponse(responseData, format)

    if parse_err then
        return nil, parse_err
    end

    -- Model answered without a tool call
    if direct_content then
        return direct_content, nil
    end

    -- Model issued a tool call but we have no search result yet.
    -- Return a descriptor; the Querier will execute the search and loop.
    if tool_calls and #tool_calls > 0 then
        -- Build placeholder messages_to_append (search result will be filled in by Querier).
        -- We expose raw_assistant so the Querier can call buildToolResult() once it has results.
        return {
            __is_tool_call  = true,
            raw_assistant   = raw_assistant,  -- opaque; pass back to buildToolResultMessages
            format          = format,
            tool_calls      = tool_calls,
        }, nil
    end

    return nil, "parseToolCalls: unexpected response (no content, no tool call)"
end

function BaseHandler:buildExternalSearchToolDef(format)
    return ToolExecutor.buildExternalSearchToolDef(format)
end

return BaseHandler
