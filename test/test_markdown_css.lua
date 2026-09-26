-- test_markdown_css.lua
-- Display test for the dialog output shapes eyeballed via
-- test/markdown_css.lua: renders the shared two-round sample
-- (test/markdown_css_sample.md, same div/fence/---/keyword shapes
-- AssistantDialog:_createResultText emits) through the real
-- assistant_mdparser MD() and asserts what the viewer shows.
-- Headless-safe: the widget-heavy assistant_dialog.lua and
-- assistant_viewer.lua are never required; their pure string transforms
-- (label unwrap, suggestion-link rewrite) are mirrored inline per testing
-- policy, and the device stub is enriched before the mdparser platform
-- probe runs.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local TextUtils = helper.TextUtils

-- assistant_mdparser probes Device:isDesktop/isEmulator/isAndroid at load;
-- the headless stub only carries screen metrics, so add the predicates.
local device = package.loaded["device"]
if device == nil then device = require("device") end
if device.isDesktop == nil then
    device.isDesktop = function() return true end
end
if device.isEmulator == nil then
    device.isEmulator = function() return false end
end
if device.isAndroid == nil then
    device.isAndroid = function() return false end
end

local MD = require("assistant_mdparser")

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

-- Shared sample is a plain .md file: paste new text straight in, no escaping.
local SAMPLE = read_source("test/markdown_css_sample.md")

-- The sample is the Reasoning-Text-on shape. With the switch off the querier
-- never folds reasoning into the answer at all (TextUtils.strip_think_tags
-- with show_reasoning = false), so there is nothing for a renderer to strip:
-- the sample is rendered as-is and only the styling is checked.
--
-- Inline mirror of the puremd unwrap (assistant_viewer.lua _renderMarkdown):
-- puremd wraps raw HTML blocks in <p>; hoedown leaves them bare (no-op).
local function unwrap_label(html)
    return html:gsub('<p>%s*<div class="(assistant%-label[^"]*)">(.-)</div>%s*</p>', '<div class="%1">%2</div>')
end

-- Inline mirror of the suggestion-link rewrite (_renderMarkdown): #q: links
-- become tappable suggestion rows when follow-ups are enabled.
local function apply_suggestion_class(html)
    return html:gsub('<a href="#q:', '<a class="suggestion-link" href="#q:')
end

local function count_plain(text, needle)
    local n = 0
    local init = 1
    while true do
        local hit = text:find(needle, init, true)
        if not hit then break end
        n = n + 1
        init = hit + 1
    end
    return n
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

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("sample: two-round dialog shape with divs, fence, keywords", function()
        assert.equal(count_plain(SAMPLE, '<div class="assistant-label">'), 5,
            "expect 2x Question + 2x Response + 1x Search divs")
        assert.matches(SAMPLE, 'assistant%-label">☺ Question</div>', "Question div missing")
        assert.equal(count_plain(SAMPLE, "☺ Question"), 2, "expect two Question rounds")
        assert.matches(SAMPLE, 'assistant%-label%-%-thought">❖ Deeply Thought</div>', "Thought div missing")
        assert.matches(SAMPLE, '```reasoning\nThe user asks', "reasoning fence missing")
        assert.matches(SAMPLE, 'assistant%-label">✦ Response</div>', "Response div missing")
        assert.matches(SAMPLE, 'assistant%-label">✦ Search</div>', "Search div missing")
        assert.matches(SAMPLE, '⌗ Frodo Baggins Ring bearer Mordor', "Search keyword line missing")
        assert.matches(SAMPLE, '---\n\n<div class="assistant%-label">☺ Question</div>', "inter-round --- before round two missing")
        assert.isTrue(count_sep_lines(SAMPLE) >= 3, "expect inter-round --- plus generic ---")
        assert.equal(count_plain(SAMPLE, "#q:"), 2, "expect two suggestion links")
    end),

    test("render: labels survive as top-level divs after unwrap", function()
        local html = MD(SAMPLE)
        assert.notNil(html, "MD() must render the sample")
        assert.isTrue(type(html) == "string", "MD() must return HTML text")
        local unwrapped = unwrap_label(html)
        assert.matches(unwrapped, '<div class="assistant%-label">☺ Question</div>', "Question div lost in render")
        assert.matches(unwrapped, 'assistant%-label%-%-thought', "Thought div lost in render")
        assert.matches(unwrapped, '✦ Search</div>', "Search div lost in render")
        assert.matches(unwrapped, '✦ Response</div>', "Response div lost in render")
        assert.notMatches(unwrapped, '<p>%s*<div class="assistant%-label', "no p-wrapped label may remain")
    end),

    test("render: LLM h1/h2 headings survive inside Response", function()
        local html = unwrap_label(MD(SAMPLE))
        assert.matches(html, '<h1', "LLM h1 must render")
        assert.matches(html, 'The Ring and Its Nature', "LLM h1 text must survive")
        assert.matches(html, '<h2', "LLM h2 must render")
        assert.matches(html, 'Why It Corrupts', "LLM h2 text must survive")
    end),

    test("render: Reasoning-Text-off never reaches the renderer", function()
        -- The drop happens when the answer is produced, so the renderer only
        -- ever sees the answer body (querier: strip_think_tags(_, _, false)).
        local answer_only = TextUtils.strip_think_tags(
            "<think>no web search is needed</think>\n\nThe Ring is corrupting.", nil, false)
        assert.equal(answer_only, "The Ring is corrupting.", "think-tag reasoning must be dropped")
        local html = unwrap_label(MD(answer_only))
        assert.notMatches(html, '<think>', "rendered HTML must not contain think tags")
        assert.notMatches(html, '```reasoning', "rendered HTML must not contain a fence")
        assert.matches(html, 'The Ring is corrupting', "answer body must survive")
    end),

    test("render: thought label heads a pre block for reasoning text", function()
        local html = unwrap_label(MD(SAMPLE))
        assert.matches(html, 'assistant%-label%-%-thought">❖ Deeply Thought</div>', "thought label must render")
        assert.matches(html, '<pre', "reasoning fence must render as a pre block")
        assert.matches(html, 'internal knowledge suffices', "reasoning body must survive rendering")
        local label_pos = html:find('assistant-label--thought', 1, true)
        assert.isTrue(label_pos ~= nil, "thought label must render")
        -- The sample also carries a ```lua block up front, so anchor the
        -- search past the thought label to reach the reasoning pre.
        local pre_pos = html:find('<pre', label_pos, true)
        assert.isTrue(pre_pos ~= nil and pre_pos > label_pos,
            "a pre block must follow the thought label")
    end),

    test("render: suggestion links kept, --- becomes hr", function()
        local html = apply_suggestion_class(unwrap_label(MD(SAMPLE)))
        assert.matches(html, '#q:', "suggestion href must be kept")
        assert.matches(html, '<a[^>]*href="#q:', "suggestion anchor must render")
        assert.matches(html, 'suggestion%-link', "suggestion anchor must carry the styling class")
        assert.matches(html, '<hr', "--- separators must render as hr")
        assert.matches(html, 'Tom Bombadil', "suggestion text must survive")
    end),

    test("unwrap: puremd p-wrapped labels collapse, bare divs pass through", function()
        local wrapped = '<p><div class="assistant-label">X</div></p>'
        assert.equal(unwrap_label(wrapped), '<div class="assistant-label">X</div>')
        local bare = '<div class="assistant-label">X</div>'
        assert.equal(unwrap_label(bare), bare)
    end),

    test("ui script: runui entry uses the shared sample", function()
        local ui_src = read_source("test/markdown_css.lua")
        assert.matches(ui_src, 'markdown_css_sample', "UI script must require the shared sample")
        assert.matches(ui_src, 'ChatGPTViewer:new', "UI script must still build the viewer")
        assert.matches(ui_src, 'UIManager:run%(%)', "UI script must end with UIManager:run()")
        assert.notMatches(ui_src, 'SAMPLE = %[%[', "UI script must not carry a forked inline SAMPLE")
    end),
}

return helper.runTests("markdown_css.lua", tests)
