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
local assistant_utils = require("assistant_utils")
local json_default = assistant_utils.json_default

local BaseHandler = {
    name = "BASE",
    base_url = "", model = "", api_key = "",
    additional_parameters = {},
    trap_widget = nil,  -- widget to trap the request
    can_fetch_models = false,
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

    -- Apply user selected model override
    local selected_model = querier.settings:readSetting("seleted_model_" .. self.provider_name)
    if selected_model then
        self.model = selected_model
    end
end

function BaseHandler:FetchModels()
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
