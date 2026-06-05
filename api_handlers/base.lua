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

local assistant_utils = require("assistant_utils")

local BaseHandler = {
    trap_widget = nil,  -- widget to trap the request
}

BaseHandler.CODE_CANCELLED = "USER_CANCELED"
BaseHandler.CODE_NETWORK_ERROR = "NETWORK_ERROR"
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
    self.trap_widget = nil
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
        return false, "Unsupported protocol"
    end
    if parsed.scheme == "https" then
        https.cert_verify = false
    end
    if not timeout then timeout = 10 end
    socketutil:set_timeout(timeout, maxtime or 30)

    if not headers then headers = {} end
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
        return false, code
    end
    if resp_headers == nil then
        logger.warn("No HTTP headers:", status or code or "network unreachable")
        return false, "Network or remote server unavailable" .. tostring(status or code)
    end
    if not code or code < 200 or code > 299 then
        logger.warn("HTTP status not okay:", status or code or "network unreachable")
        logger.dbg("Response headers:", resp_headers)
        return false, "Remote server error or unavailable: " .. tostring(status or code)
    end

    local http_len = assistant_utils.http_get_header(resp_headers, "content-length")
    if http_len then
        if #content ~= tonumber(http_len) then
            return false, "Incomplete content received"
        end
    end

    if assistant_utils.http_is_encoded(resp_headers, "gzip") then
        local decompressed, err = assistant_utils.zlib_uncompress_gzip(content, 8*1024*1024)
        if not decompressed then
            logger.warn("Failed to decompress data:", err)
            return false, "Failed to decompress data:" .. tostring(err)
        end
        logger.info("content gzipped")
        content = decompressed
    end

    return true, content
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
        completed, success, content = Trapper:dismissableRunInSubprocess(function()
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
    if not success then
        code = self.CODE_NETWORK_ERROR
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


function BaseHandler:serpAPISearchRequest(serpconfig, keywords)

    local base_url = serpconfig.serpapi_url or "https://serpapi.com/search"
    local key = serpconfig.serpapi_key
    local q = koutil.urlEncode(keywords)
    local url = T("%1?engine=google_ai_mode&api_key=%2&q=%3", base_url, key, q)

    local completed, success, content

    local request_timeout = 45
    local request_maxtime = 120

    completed, success, content = Trapper:dismissableRunInSubprocess(function()
            return httpRequest(url, request_timeout, request_maxtime, nil, nil, nil)
        end, self.trap_widget)

    if not completed then
        return false, self.CODE_CANCELLED
    end
    if not success then
        return false, content
    end

    local ok, parsed = pcall(json.decode, content)
    if not ok or not parsed then
        return false, "fail to parse serpapi return"
    end

    if parsed.reconstructed_markdown then
        return true, parsed.reconstructed_markdown
    end

    return false, "Unrecognized SerpAPI result"
end

return BaseHandler
