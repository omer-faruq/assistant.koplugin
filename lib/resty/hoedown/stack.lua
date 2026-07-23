require "resty.hoedown.buffer"

local ffi      = require "ffi"
local ffi_cdef = ffi.cdef

ffi_cdef[[
struct hoedown_stack {
    void **item;
    size_t size;
    size_t asize;
};
typedef struct hoedown_stack hoedown_stack;
void hoedown_stack_init(hoedown_stack *st, size_t initial_size);
void hoedown_stack_uninit(hoedown_stack *st);
void hoedown_stack_grow(hoedown_stack *st, size_t neosz);
void hoedown_stack_push(hoedown_stack *st, void *item);
void *hoedown_stack_pop(hoedown_stack *st);
void *hoedown_stack_top(const hoedown_stack *st);
]]

-- TODO: NYI.