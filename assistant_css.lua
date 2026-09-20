-- assistant_css.lua
--
-- Shared CSS for the plugin's HTML viewers. Single source of truth for the
-- viewer base style (black-and-white table rules included) plus the RTL and
-- justify fragments. Both ChatGPTViewer and NotebookViewer build from this
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
    margin: 1em 0 1em 3em;
    font-size: 0.8em;
    color: #333;
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
.assistant-label {
    padding-left: 0;
    font-weight: bold;
    font-size: 1.1em;
    margin: 0.8em 0 0.3em;
}

.assistant-label--thought {
    font-size: 0.85em;
    margin-top: 0.4em;
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

-- Full viewer CSS, shared by ChatGPTViewer and NotebookViewer.
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
