require "resty.hoedown.buffer"
local ffi      = require "ffi"
local ffi_cdef = ffi.cdef

ffi_cdef[[
typedef enum hoedown_autolink_flags {
    HOEDOWN_AUTOLINK_SHORT_DOMAINS = (1 << 0)
} hoedown_autolink_flags;
int hoedown_autolink_is_safe(const uint8_t *data, size_t size);
size_t hoedown_autolink__www(size_t *rewind_p, hoedown_buffer *link, uint8_t *data, size_t offset, size_t size, hoedown_autolink_flags flags);
size_t hoedown_autolink__email(size_t *rewind_p, hoedown_buffer *link, uint8_t *data, size_t offset, size_t size, hoedown_autolink_flags flags);
size_t hoedown_autolink__url(size_t *rewind_p, hoedown_buffer *link, uint8_t *data, size_t offset, size_t size, hoedown_autolink_flags flags);
]]

return {}

-- TODO: NYI.