-- test_dialog_markdown.lua
-- Guards the container-label zero-heading scheme (dialog + viewer):
--   * the shared assistant_message_format emitter produces
--     <div class="assistant-label"> carriers, never `###`/`####`
--     container headings; glyphs ride %1 outside ASCII msgids
--   * dialog calls the shared emitter (no local fork); inter-round
--     separator is `---`, not `------------`
--   * inter-round separator is `---`, not `------------`
--   * VIEWER_CSS styles .assistant-label; _renderMarkdown unwraps puremd's
--     <p>-wrapped labels; strip_reasoning matches the new div shape
-- Headless-safe: asserts on shipped sources plus a representative generated
-- sample (the shapes formatSingleMessage emits); assistant_dialog.lua itself
-- is widget-heavy and never required here.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local dialog_src = read_source("assistant_dialog.lua")
local format_src = read_source("assistant_message_format.lua")
local viewer_src = read_source("assistant_viewer.lua")

-- Representative two-round text, the shapes the dialog emits after T()
-- substitution (C locale: %1/%2/%3 replaced in order).
local SAMPLE = table.concat({
    '<div class="assistant-label">\226\152\186 Question</div>\n\n',
    '\226\158\164 What is the One Ring?\n\n',
    '<div class="assistant-label assistant-label--thought">\226\128\187 Deeply Thought</div>\n\n',
    '```reasoning\nthinking here\n```\n\n---\n\n',
    '<div class="assistant-label">\226\156\166 Response</div>\n\n',
    'The Ring rules them all.\n\n',
    '---\n\n',
    '<div class="assistant-label">\226\152\186 Question</div>\n\n',
    '\226\158\164 Who carries it?\n\n',
    '<div class="assistant-label">\226\156\166 Search</div>\n\n',
    'Frodo Baggins.\n\n',
})

-- Strip helper for the viewer pipeline: titled div block first, then the
-- bare fence the querier stores; think-tag handling is the real
-- ASUtils.strip_think_tags (assistant_utils.lua, single source of truth).
local function strip_reasoning(text)
    text = text:gsub('<div class="assistant%-label[^"]*">[^\n]*</div>%s*```reasoning%s*[%s%S]-%s*```%s*%-%-%-%s*', "")
    text = text:gsub("```reasoning%s*[%s%S]-%s*```%s*", "")
    return ASUtils.strip_think_tags(text, nil, false)
end

-- ata: puremd wraps raw HTML blocks in <p>; hoedown leaves them bare.
local function unwrap_label(html)
    return html:gsub('<p>%s*<div class="(assistant%-label[^"]*)">(.-)</div>%s*</p>', '<div class="%1">%2</div>')
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
    test("dialog: question label is a div, no h3 container", function()
        assert.matches(dialog_src, 'require%("assistant_message_format"%)', "dialog must use the shared emitter")
        assert.matches(format_src, '<div class="assistant%-label">%%1 Question</div>', "question div missing")
        assert.notMatches(format_src, '### %%1 Question', "old h3 question heading still present")
        assert.notMatches(dialog_src, '### %%1 Question', "old h3 question heading still present")
    end),

    test("dialog: thought label is a div, glyph outside msgid", function()
        assert.matches(format_src, 'assistant%-label assistant%-label%-%-thought', "thought div missing")
        assert.matches(format_src, '%%1 Deeply Thought', "thought msgid shape missing")
        assert.matches(format_src, '"\226\128\187", reasoning_text', "glyph must ride %%1 outside _()")
        assert.notMatches(format_src, '#### \226\128\187', "old h4 thought heading still present")
        assert.notMatches(dialog_src, '#### \226\128\187', "old h4 thought heading still present")
    end),

    test("dialog: response/search labels are divs via T, no h3", function()
        assert.matches(format_src, '<div class="assistant%-label">%%1 %%2</div>', "response div missing")
        assert.matches(format_src, '"\226\156\166", answer_type, assistant_content', "glyph must ride %%1 outside _()")
        assert.notMatches(format_src, '### \226\156\166 %%s', "old h3 response heading still present")
        assert.notMatches(dialog_src, '### \226\156\166 %%s', "old h3 response heading still present")
    end),

    test("dialog: inter-round separator is ---", function()
        assert.matches(dialog_src, '"%-%-%-\\n\\n" %.%.', "--- separator missing")
        assert.notMatches(dialog_src, '%-%-%-%-%-%-%-%-%-%-%-%s*\\n', "old ------------ separator still present")
    end),

    test("viewer css: label rules present, h1/h2 scale kept", function()
        assert.matches(viewer_src, '%.assistant%-label %s*{', ".assistant-label rule missing")
        assert.matches(viewer_src, '%.assistant%-label%-%-thought', ".assistant-label--thought rule missing")
        assert.matches(viewer_src, 'font%-size: 1%.3em', "h1 1.3em must stay")
        assert.matches(viewer_src, 'font%-size: 1%.2em', "h2 1.2em must stay")
    end),

    test("viewer: p-wrapped label unwrap present and working", function()
        assert.matches(viewer_src, 'assistant%%%-label', "unwrap gsub missing in viewer")
        local wrapped = '<p><div class="assistant-label">X</div></p>'
        assert.equal(unwrap_label(wrapped), '<div class="assistant-label">X</div>')
        local bare = '<div class="assistant-label">X</div>'
        assert.equal(unwrap_label(bare), bare)
    end),

    test("viewer: strip matches new div shape, old h4 gone", function()
        assert.matches(viewer_src, 'assistant%%%-label', "new strip pattern missing")
        assert.notMatches(viewer_src, '#### %[%^', "old #### strip pattern still present")
        local stripped = strip_reasoning(SAMPLE)
        assert.notMatches(stripped, '```reasoning', "reasoning fence must be stripped")
        assert.notMatches(stripped, 'assistant%-label%-%-thought', "thought label must be stripped")
        assert.matches(stripped, 'assistant%-label', "response/search labels must survive")
        assert.matches(stripped, 'The Ring rules them all', "answer body must survive")
    end),

    test("generated: zero container heading lines", function()
        local bad = heading_lines(SAMPLE)
        assert.equal(#bad, 0, "container must emit no ^#{1,6} lines, got: " .. table.concat(bad))
    end),

    test("generated: labels present, --- count, fence kept", function()
        assert.matches(SAMPLE, 'assistant%-label', "assistant-label div missing")
        assert.matches(SAMPLE, 'assistant%-label%-%-thought', "thought div missing")
        assert.equal(count_sep_lines(SAMPLE), 2, "expect 1 reasoning --- + 1 inter-round ---")
        assert.matches(SAMPLE, '```reasoning\nthinking here\n```', "reasoning fence must be kept pre-strip")
    end),
}

return helper.runTests("dialog_markdown.lua", tests)
