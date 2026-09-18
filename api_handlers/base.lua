local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local https = require("ssl.https")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
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
    trap_widget = nil,
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

--- Prefix an error message with its HTTP status code for quick triage.
--- Numeric codes in the 100-599 range get a "[NNN] " prefix; failures
--- without an HTTP code (nil, socket error strings, other internal codes)
--- get a "[0] " prefix. USER_CANCELED passes through untouched (compared
--- by literal to avoid coupling the helper to the CODE_* constants).
--- Already-prefixed messages are returned as-is.
--- @param code number|string|nil HTTP status or internal code
--- @param msg any error message (non-strings returned untouched)
--- @return any "[NNN] msg", "[0] msg", or the original msg
function BaseHandler.prefixHttpCode(code, msg)
    if type(msg) ~= "string" then return msg end
    if msg:match("^%[%d+%]") then return msg end
    if code == "USER_CANCELED" then return msg end
    local num = tonumber(code)
    if not num or num < 100 or num > 599 or math.floor(num) ~= num then
        return "[0] " .. msg
    end
    return string.format("[%d] %s", num, msg)
end

-- ---------------------------------------------------------------------------
-- 429 retry helpers (header/date parsing lives in assistant_utils)
-- ---------------------------------------------------------------------------

--- Decode a response body (string or already-decoded table) into a table, or nil.
local function decodeBody(body)
    if type(body) == "table" then return body end
    if type(body) == "string" and #body > 0 then
        local ok, j = pcall(json.decode, body)
        if ok and type(j) == "table" then return j end
    end
    return nil
end

--- Unwrap the error node from a decoded 429 body.
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

--- Normalize a candidate error value: non-empty string as-is,
--- number via tostring, anything else nil. Shared by all
--- extractErrorMessage implementations (dot-call, no self).
--- @param v any candidate value
--- @return string|nil normalized message
function BaseHandler.pickErrorValue(v)
    if type(v) == "string" and #v > 0 then return v end
    if type(v) == "number" then return tostring(v) end
    return nil
end

--- Extract a human-readable error message from an API response body.
--- Canonical default: deterministic order ONLY —
---   error.message > flat error > bare message (3 lookups max).
--- Wire-format-specific shapes (e.g. FastAPI-style detail.* proxies)
--- belong in per-handler overrides, never here.
--- @param body string|table|nil raw body or already-decoded JSON
--- @return string|nil error message, or nil if none found
function BaseHandler:extractErrorMessage(body)
    local decoded = decodeBody(body)
    if type(decoded) ~= "table" then return nil end
    local pick = BaseHandler.pickErrorValue
    return pick(koutil.tableGetValue(decoded, "error", "message"))
        or pick(decoded.error)
        or pick(decoded.message)
end

--- Parse the 429 wait time from retry headers, then body hints.
--- @return number|nil seconds to wait, or nil if none could be determined.
function BaseHandler:parseRetryAfter(headers, body)
    -- 1. retry-after-ms
    local v = ASUtils.getHeader(headers, "retry-after-ms")
    if v then
        local ms = tonumber(v)
        if ms then return ms / 1000 end
    end
    -- 2. x-ms-retry-after-ms
    v = ASUtils.getHeader(headers, "x-ms-retry-after-ms")
    if v then
        local ms = tonumber(v)
        if ms then return ms / 1000 end
    end
    -- 3. retry-after (delta-seconds or HTTP-date)
    v = ASUtils.getHeader(headers, "retry-after")
    if v then
        local secs = tonumber(v)
        if secs then return secs end
        local date = ASUtils.parseHttpDate(v)
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
        -- error message "try again in X.Xs"
        local msg = self:extractErrorMessage(decoded)
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
function BaseHandler:isRetryable429(code, headers, body)
    if tonumber(code) ~= 429 then return false end
    local should_retry = ASUtils.getHeader(headers, "x-should-retry")
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
            -- Match "daily"/"quota" in reason/status/message wording only, not the code itself.
            local combined = tostring(reason) .. " " .. tostring(status) .. " " .. tostring(msg)
            local lower = combined:lower()
            if lower:find("daily") or lower:find("quota") then
                return false
            end
        end
    end
    return true
end

--- Compute the 429 retry decision with backoff capped at 5s.
--- @return table { retryable=boolean, delay=number, reason=string }
function BaseHandler:getRetryDelay(code, headers, body, attempt)
    if not self:isRetryable429(code, headers, body) then
        return { retryable = false, delay = 0, reason = "not-retryable" }
    end
    attempt = tonumber(attempt) or 1
    if attempt < 1 then attempt = 1 end
    -- Exponential backoff: 1s * 2^(attempt-1), capped at 5s with ±25% jitter.
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
    -- Fall back to pure backoff without a positive server hint.
    return { retryable = true, delay = backoff, reason = "backoff" }
end

--- Extract a short one-line detail from a 429 response body.
--- @param body string|table|nil response body
--- @return string|nil short detail
function BaseHandler:extractRetryDetail(body)
    local decoded = decodeBody(body)
    local msg = self:extractErrorMessage(decoded or body)
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

--- Show a cancellable retry countdown.
--- @param delay number seconds to wait
--- @param attempt number current attempt (1-based)
--- @param max_retries number configured max retries
--- @param detail string|nil optional API error text (already truncated)
--- @return boolean true when the wait finished, false when the user cancelled.
function BaseHandler:sleepWithRetryInfo(delay, attempt, max_retries, detail)
    local raw = T(_("<b>API Busy</b>\nAttempts %1/%2 ... Retry in (%d secs)"), attempt, max_retries)
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

-- Sync provider and model options from the querier.
function BaseHandler:SyncOptions(querier)
    self.provider_name = querier.provider_name
    self.handler_name = querier.handler_name
    koutil.tableMerge(self, querier.provider_setting)
    self.model_parameters = nil

    self:normalizeBaseUrl()

    local selected_model = querier.settings:readSetting("selected_model_" .. self.provider_name)
    if selected_model then
        self.model = selected_model
    end

    -- Rebuild request parameters from the querier settings.
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

    -- Merge the runtime reasoning overlay over same-name top-level keys.
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

--- Strip known API path suffixes from base_url.
function BaseHandler:normalizeBaseUrl()
    if not self.base_url or self.base_url == "" then return end
    self.base_url = self.base_url
        :gsub("/+$", "")
        :gsub("/chat/completions$", "")
        :gsub("/messages$", "")
        :gsub("/responses$", "")
        :gsub("/models/[^/]+:generateContent$", "")
        :gsub("/+$", "")
end

--- Connection-test instruction echoed back verbatim by the model.
--- Sent to the API as-is.
BaseHandler.TEST_PROMPT = "Reply with exactly one word: OK"

--- Check whether the connection-test echo contains a standalone OK.
--- @param content string|nil extracted assistant text from the report
--- @return boolean true when the echo proves endpoint, key and model at once
function BaseHandler.isEchoOk(content)
    if type(content) ~= "string" then return false end
    return content:find("%f[%w]OK%f[%W]") ~= nil
end

--- Report that this handler does not support connection testing.
function BaseHandler:Test()
    return nil, T(_("%1 handler does not support connection testing"), tostring(self.name))
end

--- POST the connection-test request and package the exchange into a report.
--- @param url string full endpoint URL
--- @param headers table auth/content headers
--- @param body table Lua request body
--- @param extract function decoded response table -> assistant text, or nil
--- @return table|nil report { url, body, status, raw, content } @return string|nil err
function BaseHandler:testRequest(url, headers, body, extract)
    local json_body = json.encode(body)
    -- Dismissable wait indicator; tapping it cancels the request.
    local infomsg = InfoMessage:new{
        face = Font:getFace("xx_smallinfofont"),
        text = ASUtils.bold_format(_("<b>Testing connection...</b>")) .. "\nPOST " .. url,
    }
    UIManager:show(infomsg)
    self:setTrapWidget(infomsg)
    local success, code, raw = self:makeRequest(url, headers, json_body)
    self:resetTrapWidget()
    UIManager:close(infomsg)
    if not success then
        if code == self.CODE_CANCELLED then
            return nil, self.CODE_CANCELLED
        end
        local status = tonumber(code)
        if not status then
            -- transport-level failure: raw holds a readable reason
            return nil, tostring(raw or code)
        end
        -- HTTP error: keep status and body in the report.
        return { url = url, body = json_body, status = status, raw = raw or "" }
    end
    local report = {
        url    = url,
        body   = json_body,
        status = tonumber(code) or 0,
        raw    = raw or "",
    }
    local ok, decoded = pcall(json.decode, report.raw)
    if ok and type(decoded) == "table" then
        report.content = extract(decoded)
    end
    return report
end

--- Query the model; behavior depends on query_option.use_stream_mode.
---
--- @param message_history  table   conversation history
--- @param query_option     table   { use_stream_mode=boolean, use_websearch=string }
--- @return string|function|table result, string|nil error
function BaseHandler:query(message_history, query_option)
    error("query method must be implemented")
end


--- POST synchronously, retrying retryable 429s up to getMaxRetries() times.
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
                    return false, self.CODE_CANCELLED, self.CODE_CANCELLED
                end
            else
                return false, code, content
            end
        else
            if is_429 then
                -- Final 429 failure is returned as an error.
                return false, code, content
            end
            return success, code, content
        end
    end
end

--- Build the streaming request function run in a subprocess.
function BaseHandler:backgroundRequest(url, headers, body)

    local function wrap_fd(fd)
        local fo = {}
        function fo:write(chunk)
            ffiutil.writeToFD(fd, chunk)
            return self
        end
        function fo:close() return true end
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

        -- Buffer the body (capped) for the error path.
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

--- Parse a non-streaming LLM response into text, a tool call, or an error.
--- @param responseData  table   decoded JSON from the LLM (non-stream response)
--- @param format        string  "openai" | "anthropic" | "gemini"
--- @return string|table result, string|nil error
function BaseHandler:parseToolCalls(responseData, format)
    local tool_calls, raw_assistant, direct_content, parse_err =
        ToolExecutor.parseToolCallsResponse(responseData, format)

    if parse_err then
        return nil, parse_err
    end

    if direct_content then
        return direct_content, nil
    end

    if tool_calls and #tool_calls > 0 then
        return {
            __is_tool_call  = true,
            raw_assistant   = raw_assistant,
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
