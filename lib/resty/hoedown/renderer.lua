local ffi      = require "ffi"
local ffi_cdef = ffi.cdef

ffi_cdef[[
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
]]

-- TODO: NYI.