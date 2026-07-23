local buffer       = require "resty.hoedown.buffer"
local new_buf      = buffer.new
local lib          = require "resty.hoedown.library"
local ffi          = require "ffi"
local ffi_gc       = ffi.gc
local ffi_cdef     = ffi.cdef
local bit          = require "bit"
local bor          = bit.bor
local type         = type
local ipairs       = ipairs
local tostring     = tostring
local tonumber     = tonumber
local setmetatable = setmetatable

ffi_cdef[[
typedef enum hoedown_html_flags {
	HOEDOWN_HTML_SKIP_HTML = (1 << 0),
	HOEDOWN_HTML_ESCAPE    = (1 << 1),
	HOEDOWN_HTML_HARD_WRAP = (1 << 2),
	HOEDOWN_HTML_USE_XHTML = (1 << 3)
} hoedown_html_flags;
typedef enum hoedown_html_tag {
	HOEDOWN_HTML_TAG_NONE = 0,
	HOEDOWN_HTML_TAG_OPEN,
	HOEDOWN_HTML_TAG_CLOSE
} hoedown_html_tag;
struct hoedown_html_renderer_state {
    void *opaque;
    struct {
        int header_count;
        int current_level;
        int level_offset;
        int nesting_level;
    } toc_data;
    hoedown_html_flags flags;
    void (*link_attributes)(hoedown_buffer *ob, const hoedown_buffer *url, const hoedown_renderer_data *data);
};
typedef struct hoedown_html_renderer_state hoedown_html_renderer_state;
void              hoedown_html_smartypants(hoedown_buffer *ob, const uint8_t *data, size_t size);
hoedown_html_tag  hoedown_html_is_tag(const uint8_t *data, size_t size, const char *tagname);
hoedown_renderer* hoedown_html_renderer_new(hoedown_html_flags render_flags, int nesting_level) __attribute__ ((malloc));
hoedown_renderer* hoedown_html_toc_renderer_new(int nesting_level) __attribute__ ((malloc));
void              hoedown_html_renderer_free(hoedown_renderer *renderer);
]]

local html_flags = {
    skip_html = lib.HOEDOWN_HTML_SKIP_HTML,
    escape    = lib.HOEDOWN_HTML_ESCAPE,
    hard_wrap = lib.HOEDOWN_HTML_HARD_WRAP,
    use_xhtml = lib.HOEDOWN_HTML_USE_XHTML
}

local html_tag = {
    none      = lib.HOEDOWN_HTML_TAG_NONE,
    open      = lib.HOEDOWN_HTML_TAG_OPEN,
    close     = lib.HOEDOWN_HTML_TAG_CLOSE
}

local function free(self)
    lib.hoedown_html_renderer_free(self.context)
end

local toc = { free = free }
toc.__index = toc

function toc.new(nesting)
    return setmetatable({ context = ffi_gc(lib.hoedown_html_toc_renderer_new(nesting or 6), lib.hoedown_html_renderer_free) }, toc)
end

local html = { free = free, toc = toc, flags = html_flags, tag = html_tag }
html.__index = html

function html.new(flags, nesting)
    local t = type(flags)
    local f = 0
    if t == "number" then
        f = flags
    elseif t == "table" then
        for _, v in ipairs(flags) do
            if type(v) == "number" then
                f = bor(v, f)
            else
                f = bor(html_flags[v] or 0, f)
            end
        end
    end
    return setmetatable({ context = ffi_gc(lib.hoedown_html_renderer_new(f, nesting or 0), lib.hoedown_html_renderer_free) }, html)
end
function html.smartypants(data)
    local str = tostring(data)
    local len = #str
    local buf = new_buf(len);
    lib.hoedown_html_smartypants(buf.context, str, len);
    return tostring(buf)
end
function html.is_tag(data, tag)
    local str = tostring(data)
    local len = #str
    return tonumber(lib.hoedown_html_is_tag(str, len, tostring(tag)))
end

return html