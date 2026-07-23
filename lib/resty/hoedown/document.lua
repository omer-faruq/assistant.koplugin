local buffer       = require "resty.hoedown.buffer"
local new_buf      = buffer.new
local lib          = require "resty.hoedown.library"
local ffi          = require "ffi"
local ffi_gc       = ffi.gc
local ffi_cdef     = ffi.cdef
local bit          = require "bit"
local bor          = bit.bor
local type         = type
local tostring     = tostring
local ipairs       = ipairs
local setmetatable = setmetatable

ffi_cdef[[
typedef enum hoedown_extensions {
    HOEDOWN_EXT_TABLES = (1 << 0),
    HOEDOWN_EXT_FENCED_CODE = (1 << 1),
    HOEDOWN_EXT_FOOTNOTES = (1 << 2),
    HOEDOWN_EXT_AUTOLINK = (1 << 3),
    HOEDOWN_EXT_STRIKETHROUGH = (1 << 4),
    HOEDOWN_EXT_UNDERLINE = (1 << 5),
    HOEDOWN_EXT_HIGHLIGHT = (1 << 6),
    HOEDOWN_EXT_QUOTE = (1 << 7),
    HOEDOWN_EXT_SUPERSCRIPT = (1 << 8),
    HOEDOWN_EXT_MATH = (1 << 9),
    HOEDOWN_EXT_NO_INTRA_EMPHASIS = (1 << 11),
    HOEDOWN_EXT_SPACE_HEADERS = (1 << 12),
    HOEDOWN_EXT_MATH_EXPLICIT = (1 << 13),
    HOEDOWN_EXT_DISABLE_INDENTED_CODE = (1 << 14)
} hoedown_extensions;
typedef enum hoedown_list_flags {
    HOEDOWN_LIST_ORDERED = (1 << 0),
    HOEDOWN_LI_BLOCK = (1 << 1)
} hoedown_list_flags;
typedef enum hoedown_table_flags {
    HOEDOWN_TABLE_ALIGN_LEFT = 1,
    HOEDOWN_TABLE_ALIGN_RIGHT = 2,
    HOEDOWN_TABLE_ALIGN_CENTER = 3,
    HOEDOWN_TABLE_ALIGNMASK = 3,
    HOEDOWN_TABLE_HEADER = 4
} hoedown_table_flags;
typedef enum hoedown_autolink_type {
    HOEDOWN_AUTOLINK_NONE,
    HOEDOWN_AUTOLINK_NORMAL,
    HOEDOWN_AUTOLINK_EMAIL
} hoedown_autolink_type;
struct hoedown_document;
typedef struct hoedown_document hoedown_document;
struct hoedown_renderer_data { void *opaque; };
typedef struct hoedown_renderer_data hoedown_renderer_data;
struct hoedown_renderer {
    void *opaque;
    void (*blockcode)(hoedown_buffer *ob, const hoedown_buffer *text, const hoedown_buffer *lang, const hoedown_renderer_data *data);
    void (*blockquote)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    void (*header)(hoedown_buffer *ob, const hoedown_buffer *content, int level, const hoedown_renderer_data *data);
    void (*hrule)(hoedown_buffer *ob, const hoedown_renderer_data *data);
    void (*list)(hoedown_buffer *ob, const hoedown_buffer *content, hoedown_list_flags flags, const hoedown_renderer_data *data);
    void (*listitem)(hoedown_buffer *ob, const hoedown_buffer *content, hoedown_list_flags flags, const hoedown_renderer_data *data);
    void (*paragraph)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    void (*table)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    void (*table_header)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    void (*table_body)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    void (*table_row)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    void (*table_cell)(hoedown_buffer *ob, const hoedown_buffer *content, hoedown_table_flags flags, const hoedown_renderer_data *data);
    void (*footnotes)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    void (*footnote_def)(hoedown_buffer *ob, const hoedown_buffer *content, unsigned int num, const hoedown_renderer_data *data);
    void (*blockhtml)(hoedown_buffer *ob, const hoedown_buffer *text, const hoedown_renderer_data *data);
    int (*autolink)(hoedown_buffer *ob, const hoedown_buffer *link, hoedown_autolink_type type, const hoedown_renderer_data *data);
    int (*codespan)(hoedown_buffer *ob, const hoedown_buffer *text, const hoedown_renderer_data *data);
    int (*double_emphasis)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    int (*emphasis)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    int (*underline)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    int (*highlight)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    int (*quote)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    int (*image)(hoedown_buffer *ob, const hoedown_buffer *link, const hoedown_buffer *title, const hoedown_buffer *alt, const hoedown_renderer_data *data);
    int (*linebreak)(hoedown_buffer *ob, const hoedown_renderer_data *data);
    int (*link)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_buffer *link, const hoedown_buffer *title, const hoedown_renderer_data *data);
    int (*triple_emphasis)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    int (*strikethrough)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    int (*superscript)(hoedown_buffer *ob, const hoedown_buffer *content, const hoedown_renderer_data *data);
    int (*footnote_ref)(hoedown_buffer *ob, unsigned int num, const hoedown_renderer_data *data);
    int (*math)(hoedown_buffer *ob, const hoedown_buffer *text, int displaymode, const hoedown_renderer_data *data);
    int (*raw_html)(hoedown_buffer *ob, const hoedown_buffer *text, const hoedown_renderer_data *data);
    void (*entity)(hoedown_buffer *ob, const hoedown_buffer *text, const hoedown_renderer_data *data);
    void (*normal_text)(hoedown_buffer *ob, const hoedown_buffer *text, const hoedown_renderer_data *data);
    void (*doc_header)(hoedown_buffer *ob, int inline_render, const hoedown_renderer_data *data);
    void (*doc_footer)(hoedown_buffer *ob, int inline_render, const hoedown_renderer_data *data);
};
typedef struct hoedown_renderer hoedown_renderer;
hoedown_document* hoedown_document_new(const hoedown_renderer *renderer, hoedown_extensions extensions, size_t max_nesting) __attribute__ ((malloc));
void              hoedown_document_render(hoedown_document *doc, hoedown_buffer *ob, const uint8_t *data, size_t size);
void              hoedown_document_render_inline(hoedown_document *doc, hoedown_buffer *ob, const uint8_t *data, size_t size);
void              hoedown_document_free(hoedown_document *doc);
]]

local exts = {
    tables                = lib.HOEDOWN_EXT_TABLES,
    fenced_code           = lib.HOEDOWN_EXT_FENCED_CODE,
    footnotes             = lib.HOEDOWN_EXT_FOOTNOTES,
    autolink              = lib.HOEDOWN_EXT_AUTOLINK,
    strikethrough         = lib.HOEDOWN_EXT_STRIKETHROUGH,
    underline             = lib.HOEDOWN_EXT_UNDERLINE,
    highlight             = lib.HOEDOWN_EXT_HIGHLIGHT,
    quote                 = lib.HOEDOWN_EXT_QUOTE,
    superscript           = lib.HOEDOWN_EXT_SUPERSCRIPT,
    math                  = lib.HOEDOWN_EXT_MATH,
    no_intra_emphasis     = lib.HOEDOWN_EXT_NO_INTRA_EMPHASIS,
    space_headers         = lib.HOEDOWN_EXT_SPACE_HEADERS,
    math_explicit         = lib.HOEDOWN_EXT_MATH_EXPLICIT,
    disable_indented_code = lib.HOEDOWN_EXT_DISABLE_INDENTED_CODE
}

local document = { extensions = exts }
document.__index = document

function document.new(renderer, extensions, max_nesting)
    local t = type(extensions)
    local e = 0
    if t == "number" then
        e = extensions
    elseif t == "table" then
        for _, v in ipairs(extensions) do
            if type(v) == "number" then
                e = bor(v, e)
            else
                e = bor(exts[v] or 0, e)
            end
        end
    end
    return setmetatable({ context = ffi_gc(lib.hoedown_document_new(renderer.context or renderer, e, max_nesting or 16), lib.hoedown_document_free) }, document)
end
function document:render(data)
    local str = tostring(data)
    local len = #str
    local buf = new_buf(len);
    lib.hoedown_document_render(self.context, buf.context, str, len)
    return tostring(buf)
end
function document:render_inline(data)
    local str = tostring(data)
    local len = #str
    local buf = new_buf(len);
    lib.hoedown_document_render_inline(self.context, buf.context, str, len)
    return tostring(buf)
end
function document:free()
    lib.hoedown_document_free(self.context)
end

return document
