--- Network helpers: HTTP with gzip, JSON fetch, headers, error messages.
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local https = require("ssl.https")
local json = require("rapidjson")
local logger = require("logger")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local koutil = require("util")
local strbuf = require("string.buffer")
local T = require("ffi/util").template
local _ = require("assistant_gettext")

local M = {}

--- Run a callback once the network is available, avoiding a DNS timeout when
--- the Wi-Fi radio is already off.
---@param callback function run once online
function M.runWhenOnlineFast(callback)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isWifiOn() then
        NetworkMgr:promptWifiOn(callback)
        return
    end
    NetworkMgr:runWhenOnline(callback)
end

require("ffi/zlib_h")
local libz = ffi.loadlib("z", 1)
local ZLIB_HEADER = "\x78\x9c"
local scratch = strbuf.new()
-- Enhanced uncompress that natively tolerates the Gzip-to-Zlib trailer mismatch
local function zlib_uncompress_gzip(gzip_data, max_datalen)
    local total_len = #gzip_data
    if total_len < 18 then return nil, "Data truncated" end

    local deflate_len = total_len - 18
    local src_ptr = ffi.cast("const uint8_t*", gzip_data)

    -- reused buffer
    scratch:reset()
    -- 1. Prepend a valid standard Zlib header (0x78 0x9C)
    scratch:put(ZLIB_HEADER)
    -- 2. Strip the 10-byte Gzip header
    scratch:putcdata(src_ptr + 10, deflate_len)
    local payload_ptr, payload_len = scratch:ref()

    -- 3. Prepare the memory buffers
    local buf = ffi.new("uint8_t[?]", max_datalen)
    local buflen = ffi.new("unsigned long[1]", max_datalen)

    -- 4. Invoke the low-level libz
    local res = libz.uncompress(buf, buflen,
        ffi.cast("const unsigned char*", payload_ptr), payload_len)

    -- res == 0 means perfect zlib format
    -- res == -3 (Z_DATA_ERROR) happens here because the tail has a Gzip CRC32 instead of Zlib Adler32.
    -- But since the Deflate payload itself is 100% correct, the bytes in 'buf' are ALREADY completely deflated!
    if res == 0 or res == -3 then
        local actual_len = buflen[0]
        if actual_len > 0 then
            return ffi.string(buf, actual_len)
        end
    end

    return nil, "Zlib core uncompress failed with severe code: " .. tostring(res)
end

--- Case-insensitive header lookup.
--- @param headers table|nil response headers
--- @param header_name string|nil header name
--- @return string|nil header value, or nil
function M.getHeader(headers, header_name)
    if type(headers) ~= "table" then return nil end
    if type(header_name) ~= "string" then return nil end
    local lower_name = header_name:lower()

    for k, v in pairs(headers) do
        if type(k) == "string" and k:lower() == lower_name then
            return v
        end
    end
    return nil
end

---
--- Checks content-encoding
local function http_is_encoded(headers, encoding)
    local value = M.getHeader(headers, "content-encoding")
    if not value then return false end
    return value:lower():find((encoding or "gzip"):lower()) ~= nil
end

---
--- these codes are first defined in api_handlers/base.lua
local BaseHandler = {}
BaseHandler.CODE_CANCELLED          = "USER_CANCELED"
BaseHandler.CODE_NETWORK_ERROR      = "NETWORK_ERROR"
BaseHandler.CODE_TIMEOUT            = "REQUEST_TIMEOUT"
BaseHandler.CODE_UNSUPPORTED_PROTO  = "UNSUPPORTED_PROTOCOL"
BaseHandler.CODE_INCOMPLETE         = "INCOMPLETE_CONTENT"
BaseHandler.CODE_DECOMPRESS_ERROR   = "DECOMPRESS_ERROR"
BaseHandler.CODE_SERVER_ERROR       = "SERVER_ERROR"
M.HANDLERCODE = BaseHandler

-- httpRequest with gzip compress support, GET/POST method only
--- @param url string request URL
--- @param timeout number|nil block timeout in seconds (defaults to 10)
--- @param maxtime number|nil total timeout in seconds (defaults to 30)
--- @param post_body table|string|nil POST body, JSON-encoded unless already a string
--- @param post_content_type string|nil Content-Type for POST
--- @param headers table|nil request headers
--- @return boolean ok
--- @return string|number code
--- @return string|nil content
--- @return table|nil resp_headers
function M.httpRequest(url, timeout, maxtime, post_body, post_content_type, headers)
    local parsed = socket_url.parse(url)
    if not parsed then
        return false, BaseHandler.CODE_UNSUPPORTED_PROTO, "URL cannot reconized" .. tostring(url)
    end
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
        if type(post_body) ~= "string" then post_body = json.encode(post_body) end
        request.source = ltn12.source.string(post_body)
        headers["Content-Type"]   = headers["Content-Type"] or post_content_type or "application/json"
        headers["Content-Length"] = headers["Content-Length"] or tostring(#post_body)
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
        return false, code, content or "Remote server error or unavailable"
    end

    local http_len = M.getHeader(resp_headers, "content-length")
    if http_len then
        if #content ~= tonumber(http_len) then
            return false, BaseHandler.CODE_INCOMPLETE, "Incomplete content received"
        end
    end

    if http_is_encoded(resp_headers, "gzip") then
        local decompressed, err = zlib_uncompress_gzip(content, 8*1024*1024)
        if not decompressed then
            logger.warn("Failed to decompress data:", err)
            return false, BaseHandler.CODE_DECOMPRESS_ERROR, "Failed to decompress data: " .. tostring(err)
        end
        content = decompressed
    end

    return true, code, content, resp_headers
end


--- Extract a human-readable error message from an API response body.
--- Canonical default (single source of truth): deterministic order --
---   error.message > flat error > detail.error.message > detail.error >
---   detail.message > detail string > bare message. The detail.* proxy
---   fallback covers OpenAI-gateway bodies (proxies e.g. DeepSeek wrap
---   upstream errors under detail). A machine-code suffix
--- (unique non-empty error.type / error.status or top-level status /
--- error.code joined with "/") is appended in ASCII brackets, untranslated.
--- @param body string|table|nil raw body or already-decoded JSON
--- @return string|nil error message, or nil if none found
function M.extractErrorMessage(body)
    local decoded = body
    if type(body) == "string" then
        if #body == 0 then return nil end
        local ok, j = pcall(json.decode, body)
        if not ok or type(j) ~= "table" then return nil end
        decoded = j
    end
    if type(decoded) ~= "table" then return nil end
    local function pick(v)
        if type(v) == "string" and #v > 0 then return v end
        if type(v) == "number" then return tostring(v) end
        return nil
    end
    local msg = pick(koutil.tableGetValue(decoded, "error", "message"))
        or pick(decoded.error)
        or pick(koutil.tableGetValue(decoded, "detail", "error", "message"))
        or pick(koutil.tableGetValue(decoded, "detail", "error"))
        or pick(koutil.tableGetValue(decoded, "detail", "message"))
        or pick(decoded.detail)
        or pick(decoded.message)
    if msg == nil then return nil end
    local tag_parts = {}
    local seen = {}
    local candidates = {
        pick(koutil.tableGetValue(decoded, "error", "type")),
        pick(koutil.tableGetValue(decoded, "error", "status")) or pick(decoded.status),
        pick(koutil.tableGetValue(decoded, "error", "code")),
    }
    for i = 1, 3 do
        local v = candidates[i]
        if v ~= nil and not seen[v] then
            seen[v] = true
            tag_parts[#tag_parts + 1] = v
        end
    end
    if #tag_parts == 0 then return msg end
    return msg .. " [" .. table.concat(tag_parts, "/") .. "]"
end

--- Fetch JSON over HTTP behind a cancellable trap widget.
--- @param url string request URL
--- @param header table|nil request headers
--- @param string_or_widget string|table trap message, or widget closed afterwards
--- @param timeout number|nil block timeout in seconds (defaults to 10)
--- @param maxtime number|nil total timeout in seconds (defaults to 30; nil also skips the total-timeout sink)
--- @param post_body table|string|nil POST body, JSON-encoded unless already a string
--- @return table|nil parsed JSON on success
--- @return string|nil error code or message
function M.fetchJSON(url, header, string_or_widget, timeout, maxtime, post_body)

  local completed, success, code, body = Trapper:dismissableRunInSubprocess(function()
    return M.httpRequest(url, timeout, maxtime, post_body, "application/json", header or {})
  end, string_or_widget)

  if type(string_or_widget) == "table" then
    UIManager:close(string_or_widget)
  end

  if not completed then
    return nil, BaseHandler.CODE_CANCELLED
  end

  if not success then
    return nil, BaseHandler.CODE_NETWORK_ERROR
  end

  if code ~= 200 then
    if body and #body > 0 then
      local ok_ex, msg = pcall(M.extractErrorMessage, body)
      if ok_ex and type(msg) == "string" and #msg > 0 then return nil, msg end
      return nil, T("HTTP Status %1: %2", code, body)
    end
    return nil, T("HTTP Status %1", code)
  end

  local ok, parsed = pcall(json.decode, body)
  if not ok or not parsed then
    return nil, _("fetchJSON: failed to parse returned data")
  end

  return parsed, nil
end

return M
