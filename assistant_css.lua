-- assistant_css.lua
--
-- Shared CSS for the plugin's HTML viewers. Single source of truth for the
-- viewer base style (black-and-white table rules included) plus the RTL and
-- justify fragments. Both ResultViewer and NotebookViewer build from this
-- same BASE via build().
--
-- Pure functions only: no settings are read here, callers pass
-- opts = { rtl = bool, justified = bool } explicitly so the outputs stay
-- unit-testable. The base carries the same rule set as the historical
-- viewer CSS, grouped by category for readability.
--
-- Undo default margins and padding in ScrollHtmlWidget, based on
-- ui/widget/dictquicklookup.
-- font-family order: https://github.com/koreader/koreader/blob/19f3278d6b2c4677ced5358b83dc9157a8210d33/frontend/document/credocument.lua#L59
local M = {}

-- Undo default margins and padding in ScrollHtmlWidget, based on
-- ui/widget/dictquicklookup.
-- font-family order: https://github.com/koreader/koreader/blob/19f3278d6b2c4677ced5358b83dc9157a8210d33/frontend/document/credocument.lua#L59
-- Rules below are grouped by category: page & document, text blocks,
-- headings, lists, plugin components, tables.
local BASE_CSS = [[
/* Page & document */
@page {
    margin: 0;
    font-family: 'Noto Sans CJK TC', 'Noto Sans Arabic', 'Noto Sans Devanagari UI', 'Noto Sans Bengali UI', 'FreeSans', 'Noto Sans', sans-serif;
}

body {
    margin: 0;
    line-height: 1.25;
    padding: 0;
}

/* Text blocks */
p {
    padding-left: 1em;
}

blockquote, dd {
    margin: 0 1em;
    font-size: 0.8em;
}

pre {
    white-space: pre-wrap;
    overflow-wrap: break-word;
}

hr {
    border-color: #BBB;
}

/* Headings */
h1, h2, h3, h4, h5, h6 {
    padding-left: 0;
}

h1 {
    font-size: 1.3em;
}

h2 {
    font-size: 1.2em;
}

/* Lists */
ol, ul, menu {
    margin: 0;
    padding-left: 2em;
}

ul li {
    list-style-type: disc !important;
}

/* Plugin components */

/* User message bubble: right-aligned via margin-left, gray bg, left border accent.
   margin-left doubles as the max width: MuPDF shrink-to-fits the bubble within
   whatever the margin leaves, so 38% caps it at 62% of the page while a short
   turn still hugs its text. */
.user-bubble {
    margin-left: 38%;
    margin-top: 0.8em;
    margin-bottom: 2em;
    padding: 0.5em 0.8em;
    background-color: #f4f4f4;
    border-left: 3px solid #999;
}

/* The word in its surrounding sentence, shown once above the definition. */
.dict-excerpt {
    margin: 0 0 0.8em;
    padding: 0.5em 0.8em;
    font-size: 0.9em;
    color: #555;
    background-color: #F0F0F0;
    border-left: 3px solid #C8C8C8;
}

/* Which preset prompt produced the turn, and what it was pointed at. The
   formatter supplies the angle quotes (U+2039/U+203A) and the selection that
   follows them; this is the whole caption. */
.user-bubble-title {
    font-size: 0.8em;
    font-weight: bold;
    color: #666;
    margin-bottom: 0.3em;
}

/* p resets: the base paragraph margin and indent would space these like body text */
.user-bubble-meta {
    font-size: 0.75em;
    color: #666;
    margin-bottom: 0.2em;
}

.user-bubble-meta p {
    margin: 0;
    padding-left: 0;
}

/* Thought block: left-aligned, smaller font, gray bg, left border */
.thought-block {
    margin: 0.5em 0;
    padding: 0.5em 0.8em;
    font-size: 0.85em;
    color: #555;
    background-color: #F0F0F0;
    border-left: 3px solid #C8C8C8;
}

.suggestion-link {
    margin: 0.6em 0;
    display: inline-block;
}

/* Tables */
table {
    margin: 0;
    padding: 0;
    width: 100%;
    border-collapse: collapse;
    border-spacing: 0;
    font-size: 0.85em;
}

table td, table th {
    border: 1px solid black;
    padding: 0;
    overflow-wrap: break-word;
}

table th {
    white-space: nowrap;
    background-color: #bbb;
}
]]

local RTL_CSS = [[
body {
    direction: rtl !important;
    text-align: right !important;
}
]]

local JUSTIFY_CSS = "\nbody {\n    text-align: justify;\n}\n"

-- Full viewer CSS, shared by ResultViewer and NotebookViewer.
-- build() with no opts returns just the grouped base below.
function M.build(opts)
    opts = opts or {}
    local css = BASE_CSS
    if opts.rtl then
        css = css .. RTL_CSS
    end
    if opts.justified then
        css = css .. JUSTIFY_CSS
    end
    return css
end

return M
