local buffer       = require "resty.hoedown.buffer"
local new_buf      = buffer.new
local lib          = require "resty.hoedown.library"
local ffi          = require "ffi"
local ffi_cdef     = ffi.cdef
local setmetatable = setmetatable
local tostring     = tostring

ffi_cdef[[
void hoedown_escape_href(hoedown_buffer *ob, const uint8_t *data, size_t size);
void hoedown_escape_html(hoedown_buffer *ob, const uint8_t *data, size_t size, int secure);
]]

local escape = {}

function escape.href(source)
    local str = tostring(source)
    local len = #str
    local buf = new_buf(len);
    lib.hoedown_escape_href(buf.context, str, len);
    return tostring(buf)
end
function escape.html(source, secure)
    local str = tostring(source)
    local len = #str
    local buf = new_buf(len);
    lib.hoedown_escape_html(buf.context, str, len, secure and 1 or 0);
    return tostring(buf)
end
return setmetatable(escape, { __call = function(_, source, secure)
    return escape.html(source, secure)
end })