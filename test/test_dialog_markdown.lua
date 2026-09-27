-- test_dialog_markdown.lua
-- Guards the chat-bubble zero-heading scheme (dialog + viewer):
--   * the shared assistant_text_utils emitter produces
--     <div class="user-bubble"> turns and <div class="thought-block">
--     reasoning, never `###`/`####` container headings and never
--     Question/Response carriers
--   * dialog calls the shared emitter (no local fork); inter-round
--     separator is `---`, not `------------`
--   * assistant_css.lua styles .user-bubble / .thought-block;
--     _renderMarkdown unwraps puremd's <p>-wrapped bubbles and filters
--     nothing else
-- Headless-safe: asserts on shipped sources plus a representative generated
-- sample (the shapes formatSingleMessage emits); assistant_dialog.lua itself
-- is widget-heavy and never required here.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local TextUtils = helper.TextUtils

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local dialog_src = read_source("assistant_dialog.lua")
local format_src = read_source("assistant_text_utils.lua")
local viewer_src = read_source("assistant_viewer.lua")
local css_src = read_source("assistant_css.lua")

-- Representative two-round text, the shapes the dialog emits after T()
-- substitution (C locale: %1/%2/%3 replaced in order).
local SAMPLE = table.concat({
    '<div class="user-bubble">What is the One Ring?</div>\n\n',
    '<div class="thought-block">thinking here</div>\n\n',
    'The Ring rules them all.\n\n',
    '---\n\n',
    '<div class="user-bubble">Who carries it?</div>\n\n',
    'Frodo Baggins.\n\n',
})

-- puremd wraps raw HTML blocks in <p>; hoedown leaves them bare.
-- Mirror of the viewer's gated single-pass unwrap.
local CONTAINER_CLASSES = { ["user-bubble"] = true, ["thought-block"] = true }
local function unwrap_label(html)
    if html:find('<div class="user-bubble">', 1, true)
        or html:find('<div class="thought-block">', 1, true) then
        html = html:gsub('<p>%s*<div class="([^"]+)">(.-)</div>%s*</p>', function(class, inner)
            if CONTAINER_CLASSES[class] then
                return '<div class="' .. class .. '">' .. inner .. '</div>'
            end
            return nil
        end)
    end
    return html
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local function heading_lines(text)
    local found = {}
    for line in text:gmatch("[^\n]*\n?") do
        if line:match("^#{1,6} ") then
            found[#found + 1] = line
        end
    end
    return found
end

local function count_sep_lines(text)
    local n = 0
    for line in text:gmatch("[^\n]*\n?") do
        if line:match("^%-%-%-%s*\n?$") then
            n = n + 1
        end
    end
    return n
end

local tests = {
    test("dialog: user turn is a bubble, no heading container", function()
        assert.matches(dialog_src, 'require%("assistant_text_utils"%)', "dialog must use the shared emitter")
        assert.matches(format_src, '<div class="user%-bubble">', "user bubble missing")
        assert.matches(format_src, 'user%-bubble%-title', "prompt name must head the bubble")
        assert.notMatches(format_src, "_%('<div", "HTML must not enter _()")
        assert.notMatches(format_src, '### %%1 Question', "old h3 question heading still present")
        assert.notMatches(dialog_src, '### %%1 Question', "old h3 question heading still present")
        -- The carriers are gone: no Question/Response/Search wording survives.
        assert.notMatches(format_src, '_%("Question"%)', "the Question carrier must stay removed")
        assert.notMatches(format_src, '_%("Response"%)', "the Response carrier must stay removed")
        assert.notMatches(format_src, '_%("Deeply Thought"%)', "the Thought carrier must stay removed")
    end),

    test("dialog: reasoning is an unindented thought block, not a fence heading", function()
        assert.matches(format_src, '<div class="thought%-block">', "thought block missing")
        assert.notMatches(format_src, "_%('<div", "HTML must not enter _()")
        assert.notMatches(format_src, '#### \226\157\150', "old h4 thought heading still present")
        assert.notMatches(dialog_src, '#### \226\157\150', "old h4 thought heading still present")
    end),

    test("dialog: the answer body carries no wrapper of its own", function()
        assert.matches(format_src, 'reasoning_section .. assistant_content', "answer follows the thought block bare")
        assert.matches(format_src, 'return assistant_content .. "\\n\\n"', "answer-only return must stay bare")
        assert.notMatches(format_src, "_%('<div", "HTML must not enter _()")
        assert.notMatches(format_src, '### \226\156\166 %%s', "old h3 response heading still present")
        assert.notMatches(dialog_src, '### \226\156\166 %%s', "old h3 response heading still present")
    end),

    test("dialog: inter-round separator is ---", function()
        local conv_src = read_source("assistant_conversation.lua")
        assert.matches(conv_src, '"%-%-%-\\n\\n"', "--- separator missing from renderer")
        assert.notMatches(dialog_src, '%-%-%-%-%-%-%-%-%-%-%-%s*\\n', "old ------------ separator still present")
    end),

    test("viewer css: bubble rules present, h1/h2 scale kept", function()
        assert.matches(viewer_src, 'require%("assistant_css"%)', "viewer must use the shared css module")
        assert.matches(viewer_src, 'ViewerCSS%.build%(', "viewer css must build from the shared module")
        assert.notMatches(viewer_src, 'local VIEWER_CSS', "viewer must not keep a local css fork")
        assert.matches(css_src, '%.user%-bubble %s*{', ".user-bubble rule missing")
        assert.matches(css_src, '%.thought%-block %s*{', ".thought-block rule missing")
        assert.matches(css_src, 'font%-size: 1%.3em', "h1 1.3em must stay")
        assert.matches(css_src, 'font%-size: 1%.2em', "h2 1.2em must stay")
    end),

    test("viewer css: right alignment uses what MuPDF honors", function()
        -- MuPDF's property table has no max-width and no auto margin, so the
        -- bubble right-aligns with a fixed percentage margin-left, which also
        -- caps how wide it can grow.
        assert.matches(css_src, 'margin%-left: 38%%', "bubble must right-align via a percentage margin-left")
        assert.notMatches(css_src, 'margin%-left: auto', "MuPDF does not honor an auto margin")
        assert.notMatches(css_src, 'max%-width', "MuPDF does not honor max-width")
        assert.notMatches(css_src, 'border%-radius', "MuPDF does not honor border-radius")
        -- A width would fix the box and, with no box-sizing, let padding and
        -- border overflow it; the bubble must stay shrink-to-fit.
        assert.notMatches(css_src, '%.user%-bubble %s*{[^}]*width:', "the bubble must not set a width")
    end),

    test("viewer: p-wrapped bubble unwrap present and working", function()
        assert.matches(viewer_src, 'UNWRAP_CONTAINERS', "the unwrap gsub must exist in the viewer")
        assert.matches(viewer_src, 'CONTAINER_CLASSES', "the viewer must gate on the container class list")
        assert.matches(viewer_src, "html_body:find%('<div class=\"user%-bubble\">', 1, true%)",
            "the unwrap must be gated on a plain scan, not an unconditional gsub")
        local wrapped = '<p><div class="user-bubble">X</div></p>'
        assert.equal(unwrap_label(wrapped), '<div class="user-bubble">X</div>')
        local bare = '<div class="thought-block">X</div>'
        assert.equal(unwrap_label(bare), bare)
    end),

    test("viewer: the unwrap leaves other divs wrapped", function()
        -- One pass handles every container, so it must not strip the <p> from
        -- a div the CSS does not style (hoedown's footnotes block).
        local other = '<p><div class="footnotes"><hr></div></p>'
        assert.equal(unwrap_label(other), other)
    end),

    test("viewer: no heading or reasoning strip left", function()
        assert.notMatches(viewer_src, '#### %[%^', "old #### strip pattern still present")
        assert.notMatches(viewer_src, "strip_reasoning", "the viewer must not filter the answer")
        assert.notMatches(viewer_src, "strip_think_tags", "the querier already split think tags")
        assert.matches(viewer_src, 'UNWRAP_CONTAINERS', "the bubble unwrap must stay")
        -- Reasoning is dropped when the answer is produced, so the sample is
        -- rendered as-is: bubbles and the thought block stay where they are.
        assert.matches(SAMPLE, 'thought%-block', "thought block is a producer shape")
        assert.matches(SAMPLE, 'user%-bubble', "user bubbles must pass through")
        assert.matches(SAMPLE, 'The Ring rules them all', "answer body must survive")
    end),

    test("generated: zero container heading lines", function()
        local bad = heading_lines(SAMPLE)
        assert.equal(#bad, 0, "container must emit no ^#{1,6} lines, got: " .. table.concat(bad))
    end),

    test("generated: bubbles present and the inter-round --- is the only separator", function()
        assert.matches(SAMPLE, 'user%-bubble', "user-bubble div missing")
        assert.matches(SAMPLE, 'thought%-block', "thought block missing")
        assert.equal(count_sep_lines(SAMPLE), 1, "expect only the inter-round ---")
    end),
}

return helper.runTests("dialog_markdown.lua", tests)
