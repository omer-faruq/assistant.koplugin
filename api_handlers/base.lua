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
local strbuf = require("string.buffer")
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
BaseHandler.MAX_RETRIES = 8

-- ---------------------------------------------------------------------------
-- 429 retry helpers
-- ---------------------------------------------------------------------------

local MONTHS = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

--- Case-insensitive header lookup.
local function getHeader(headers, name)
    if type(headers) ~= "table" then return nil end
    local lower = name:lower()
    for k, v in pairs(headers) do
        if type(k) == "string" and k:lower() == lower then
            return v
        end
    end
    return nil
end

--- Parse an RFC1123 HTTP-date ("Sun, 06 Nov 1994 08:49:37 GMT") into epoch seconds.
--- os.time() interprets a table as local time, so we convert the parsed UTC
--- clock back to an epoch by adding the local-vs-UTC offset.
local function parseHttpDate(str)
    if type(str) ~= "string" then return nil end
    local day, mon, year, hh, mm, ss = str:match("(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)")
    if not day then return nil end
    local m = MONTHS[mon]
    if not m then return nil end
    local t = { year = tonumber(year), month = m, day = tonumber(day),
                hour = tonumber(hh), min = tonumber(mm), sec = tonumber(ss) }
    local time = os.time(t)
    local utc = os.date("!*t", time)
    local diff = os.difftime(time, os.time(utc))
    return time + diff
end

--- Decode a response body (string or already-decoded table) into a table, or nil.
local function decodeBody(body)
    if type(body) == "table" then return body end
    if type(body) == "string" and #body > 0 then
        local ok, j = pcall(json.decode, body)
        if ok and type(j) == "table" then return j end
    end
    return nil
end

--- Return the error node from a decoded 429 body, unwrapping common
--- proxy wrappers like {"detail":{"error":{...}}} or {"detail":{...}}.
--- @param decoded table|nil decoded JSON body
--- @return table|string|nil error node
local function getErrorNode(decoded)
    if type(decoded) ~= "table" then return nil end
    if decoded.error ~= nil then return decoded.error end
    local d = decoded.detail
    if type(d) == "table" then
        if d.error ~= nil then return d.error end
        if d.message ~= nil or d.code ~= nil or d.status ~= nil then return d end
    elseif type(d) == "string" and #d > 0 then
        return d
    end
    return nil
end

--- Maximum number of 429 retries, overridable via additional_parameters.max_retries (clamped 0..8).
function BaseHandler:getMaxRetries()
    local mr = self.additional_parameters and self.additional_parameters.max_retries
    if mr == nil then return self.MAX_RETRIES end
    mr = tonumber(mr)
    if not mr then return self.MAX_RETRIES end
    mr = math.floor(mr)
    if mr < 0 then mr = 0 end
    if mr > self.MAX_RETRIES then mr = self.MAX_RETRIES end
    return mr
end

--- Parse the wait time for a 429 response, in priority order:
---   retry-after-ms > x-ms-retry-after-ms > retry-after (delta-seconds | HTTP-date)
---   > Gemini error.details[].retryDelay > error.message "try again in Xs".
--- @return number|nil seconds to wait, or nil if none could be determined.
function BaseHandler:parseRetryAfter(headers, body)
    -- 1. retry-after-ms
    local v = getHeader(headers, "retry-after-ms")
    if v then
        local ms = tonumber(v)
        if ms then return ms / 1000 end
    end
    -- 2. x-ms-retry-after-ms
    v = getHeader(headers, "x-ms-retry-after-ms")
    if v then
        local ms = tonumber(v)
        if ms then return ms / 1000 end
    end
    -- 3. retry-after (delta-seconds or HTTP-date)
    v = getHeader(headers, "retry-after")
    if v then
        local secs = tonumber(v)
        if secs then return secs end
        local date = parseHttpDate(v)
        if date then
            local delay = date - os.time()
            if delay < 0 then delay = 0 end
            return delay
        end
    end
    -- 4. body-based hints
    local decoded = decodeBody(body)
    if type(decoded) == "table" then
        -- Gemini error.details[].retryDelay like "42s"
        local details = decoded.error and decoded.error.details
        if type(details) == "table" then
            for _, d in ipairs(details) do
                if type(d) == "table" and type(d.retryDelay) == "string" then
                    local secs = tonumber(d.retryDelay:match("^(%d+)"))
                    if secs then return secs end
                end
            end
        end
        -- error message "try again in X.Xs" (shared helper covers wrappers)
        local msg = ASUtils.extractErrorMessage(decoded)
        if type(msg) == "string" then
            local secs = msg:match("try again in ([%d%.]+)s")
            if secs then
                local n = tonumber(secs)
                if n then return n end
            end
        end
    end
    return nil
end

--- Decide whether a 429 is worth retrying.
--- Non-retryable: x-should-retry:false, insufficient_quota, billing_hard_limit_reached,
--- and quotaExceeded/RESOURCE_EXHAUSTED that explicitly indicate daily/quota exhaustion.
function BaseHandler:isRetryable429(code, headers, body)
    if tonumber(code) ~= 429 then return false end
    local should_retry = getHeader(headers, "x-should-retry")
    if should_retry and tostring(should_retry):lower() == "false" then
        return false
    end
    local decoded = decodeBody(body)
    if type(decoded) == "table" then
        local e = getErrorNode(decoded)
        local code_str = type(e) == "table" and e.code or (type(e) == "string" and e) or nil
        local status   = type(e) == "table" and e.status or nil
        local reason   = type(e) == "table" and e.reason or nil
        local msg      = (type(e) == "table" and e.message)
            or (type(e) == "string" and e)
            or decoded.message
            or (type(decoded.detail) == "table" and decoded.detail.message)
            or nil
        if code_str == "insufficient_quota" or code_str == "billing_hard_limit_reached" then
            return false
        end
        if code_str == "quotaExceeded" or status == "RESOURCE_EXHAUSTED" then
            -- Only the message/reason/status wording counts; the code itself
            -- ("quotaExceeded") must not trigger the "quota" keyword match.
            local combined = tostring(reason) .. " " .. tostring(status) .. " " .. tostring(msg)
            local lower = combined:lower()
            if lower:find("daily") or lower:find("quota") then
                return false
            end
        end
    end
    return true
end

--- Compute the retry decision for a 429.
--- Progressive wait capped at 5s: the server hint (Retry-After etc.) is
--- only a floor; the actual delay is min(max(server_hint, backoff), 5).
--- This keeps repeated 429s with a tiny Retry-After (e.g. 1s x 8 = 8s)
--- from finishing too quickly (1, 2, 4, 5, 5, ...s + jitter), while never
--- making the user wait longer than 5s per retry.
--- @return table { retryable=boolean, delay=number, reason=string }
function BaseHandler:getRetryDelay(code, headers, body, attempt)
    if not self:isRetryable429(code, headers, body) then
        return { retryable = false, delay = 0, reason = "not-retryable" }
    end
    attempt = tonumber(attempt) or 1
    if attempt < 1 then attempt = 1 end
    -- Exponential backoff: base 1s * 2^(attempt-1), cap 5s, + jitter ±25%
    -- (jitter output clamped to 5s so a capped retry is exactly 5s).
    local base = 1 * (2 ^ (attempt - 1))
    local capped = math.min(base, 5)
    local jitter = capped * 0.25
    local backoff = capped + (math.random() * 2 - 1) * jitter
    if backoff < 0 then backoff = 0 end
    if backoff > 5 then backoff = 5 end
    local server_delay = self:parseRetryAfter(headers, body)
    if server_delay and server_delay > 0 then
        local delay = math.max(server_delay, backoff)
        if delay > 5 then delay = 5 end
        if server_delay >= backoff then
            return { retryable = true, delay = delay, reason = "retry-after" }
        end
        return { retryable = true, delay = delay, reason = "backoff" }
    end
    -- No (or non-positive) server hint: pure backoff. A past HTTP-date
    -- parses to 0 and lands here, so we never sleep 0s between retries.
    return { retryable = true, delay = backoff, reason = "backoff" }
end

--- Extract a short human-readable detail from a 429 response body for display.
--- Tries error.message / detail.error.message / message in decoded JSON,
--- falls back to raw text.
--- Result is single-line, truncated to ~200 chars, or nil when empty.
--- @param body string|table|nil response body
--- @return string|nil short detail
function BaseHandler:extractRetryDetail(body)
    local decoded = decodeBody(body)
    local msg = ASUtils.extractErrorMessage(decoded or body)
    if type(msg) ~= "string" then
        -- No message shape (e.g. { error = { code = 429 } }): show the code.
        local e = decoded and getErrorNode(decoded) or nil
        if type(e) == "table" and e.code ~= nil then
            msg = tostring(e.code)
        end
    end
    if type(msg) ~= "string" and type(body) == "string" and #body > 0 then
        msg = body
    end
    if type(msg) ~= "string" then return nil end
    -- Collapse whitespace so multi-line JSON errors fit one dialog line.
    msg = msg:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then return nil end
    -- Strip our own bold markers so API text cannot break PTF formatting.
    msg = msg:gsub("<b>", ""):gsub("</b>", "")
    if #msg > 200 then
        msg = msg:sub(1, 200) .. "..."
    end
    return msg
end

--- Show a cancellable count-down while waiting to retry a 429.
--- Three-line countdown: bold PFT header + Attempts N/M — retry in
--- (countdown appended by sleepWithInfo) + optional Detail line.
--- @param delay number seconds to wait
--- @param attempt number current attempt (1-based)
--- @param max_retries number configured max retries
--- @param detail string|nil optional API error text (already truncated)
--- @return boolean true when the wait finished, false when the user cancelled.
function BaseHandler:sleepWithRetryInfo(delay, attempt, max_retries, detail)
    local raw = T(_("<b>API Busy</b>\nAttempts %1/%2 ... Retry in"), attempt, max_retries)
    if type(detail) == "string" and detail ~= "" then
        raw = T("%1\n\n%2 %3", raw, _("<b>Detail:</b>"), detail)
    end
    return ASUtils.sleepWithInfo(delay, ASUtils.bold_format(raw))
end

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
    -- model_parameters is never used on self; wipe it so no provider's
    -- presets linger on this shared instance.
    self.model_parameters = nil

    -- Normalize base_url: strip known API path suffixes for backward compatibility
    self:normalizeBaseUrl()

    -- Apply user selected model override
    local selected_model = querier.settings:readSetting("selected_model_" .. self.provider_name)
    if selected_model then
        self.model = selected_model
    end

    -- Rebuild request parameters from source on every sync: handlers are
    -- long-lived module-level singletons shared by providers, so parameters
    -- must never be read back from self — tableMerge leaves stale copies of
    -- setting-only fields (e.g. model_parameters) when the next provider
    -- does not define them.
    local setting = querier.provider_setting
    local shared = json_default(setting.additional_parameters, {})
    if type(shared) ~= "table" then shared = {} end
    local presets = json_default(setting.model_parameters, {})
    local preset = type(presets) == "table" and presets[self.model]
    if type(preset) == "table" then
        self.additional_parameters = koutil.tableDeepCopy(preset)
    else
        self.additional_parameters = koutil.tableDeepCopy(shared)
    end

    -- Runtime reasoning overlay (Reasoning Option dialog): shallow-merge the
    -- selected catalog entries over same-name top-level keys. Stored in
    -- settings under "reasoning_option_<provider_id>", never written back
    -- to configuration. Must rebuild from querier.provider_setting above on
    -- every sync (never read back from self): handlers are long-lived
    -- singletons shared by providers, so stale overlay keys must not linger.
    -- Only keys present in the current handler's PARAM_CATALOG are applied;
    -- unknown/stale keys are silently skipped to avoid polluting the request.
    local provider_id = querier.provider_name or self.provider_name or ""
    local Registry = require("assistant_provider_registry")
    local overlay_key = Registry.getReasoningKey(provider_id)
    local overlay
    if querier.settings and querier.settings.readSetting then
        local ok, val = pcall(function() return querier.settings:readSetting(overlay_key) end)
        if ok then overlay = val end
    end
    if type(overlay) == "table" then
        local ps = querier.provider_setting
        local catalog_key = Registry.resolveCatalogKey(provider_id, ps)
        local whitelist = (catalog_key and Registry.PARAM_CATALOG[catalog_key]) or {}
        local allowed = {}
        for _, entry in ipairs(whitelist) do
            allowed[entry.key] = true
        end
        for k, v in pairs(overlay) do
            if allowed[k] then
                self.additional_parameters[k] = koutil.tableDeepCopy(v)
            end
        end
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


--- Make a synchronous HTTP POST request, optionally through a dismissable subprocess.
--- Retries retryable 429 responses up to getMaxRetries() times, replaying the exact
--- same request. Intermediate 429s are not logged as errors; only the final failure
--- is returned (as success=false so handlers surface it as an error).
function BaseHandler:makeRequest(url, headers, body, timeout, maxtime)
    local max_retries = self:getMaxRetries()
    local attempt = 0
    while true do
        attempt = attempt + 1
        local completed, success, code, content, resp_headers
        if self.trap_widget then
            local request_timeout, request_maxtime
            if body and #body > 10000 then
                request_timeout = timeout or 300
                request_maxtime = maxtime or 120
            else
                request_timeout = timeout or 45
                request_maxtime = maxtime or 120
            end
            completed, success, code, content, resp_headers = Trapper:dismissableRunInSubprocess(function()
                    return ASUtils.httpRequest(url, request_timeout, request_maxtime, body, nil, headers)
                end, self.trap_widget)
            if not completed then
                return false, self.CODE_CANCELLED, content
            end
        else
            success, code, content, resp_headers = ASUtils.httpRequest(url, timeout or 20, maxtime or 45, body, nil, headers)
        end

        local is_429 = tonumber(code) == 429
        if is_429 and attempt <= max_retries then
            local info = self:getRetryDelay(code, resp_headers, content, attempt)
            if info.retryable then
                local detail = self:extractRetryDetail(content)
                local finished = self:sleepWithRetryInfo(info.delay, attempt, max_retries, detail)
                if not finished then
                    -- user cancelled the wait → treat as user cancellation
                    return false, self.CODE_CANCELLED, self.CODE_CANCELLED
                end
                -- retry with the exact same request (loop continues; url/headers/body unchanged)
            else
                -- not retryable → return the 429 as an error
                return false, code, content
            end
        else
            -- success, non-429 error, or 429 with retries exhausted
            if is_429 then
                -- final 429 failure → return as an error (httpRequest reports success=true for 429)
                return false, code, content
            end
            return success, code, content
        end
    end
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

        -- Buffer the body (capped) so the error path can report raw_body for
        -- 429 retry decisions (isRetryable429 / parseRetryAfter).
        local raw_body = strbuf.new()
        local MAX_ERR_BODY = 64 * 1024
        local sink = function(chunk)
            if chunk then
                if #raw_body < MAX_ERR_BODY then
                    raw_body:put(chunk:sub(1, MAX_ERR_BODY - #raw_body))
                end
                wrap_fd(child_write_fd):write(chunk)
            end
            return true
        end

        local request = {
            url    = url,
            method = "POST",
            headers = headers or {},
            source  = ltn12.source.string(body or ""),
            sink    = sink,
        }
        local code, resp_headers, status = socket.skip(1, http.request(request))
        if code ~= 200 then
            -- 429s may be retried by the Querier (getRetryDelay / isRetryable429);
            -- an intermediate 429 is not an error, so demote it to debug here.
            -- The final failure (non-retryable or retries exhausted) is logged
            -- as a warning by the Querier itself.
            if tonumber(code) == 429 then
                logger.dbg("Background request non-200 (429, may retry):", code, "status:", status, "url:", url)
            else
                logger.warn("Background request non-200:", code, "status:", status, "url:", url)
            end
            local err_struct = {
                code = code,
                url = url,
                resp_headers = resp_headers,
                status = status,
                raw_body = raw_body:get(),
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
