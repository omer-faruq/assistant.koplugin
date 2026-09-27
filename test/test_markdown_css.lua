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
        assert.equal(count_plain(SAMPLE, '<div class="user-bubble">'), 2,
            "expect 2x user-bubble divs")
        assert.matches(SAMPLE, '<div class="user%-bubble">', "user-bubble div missing")
        assert.equal(count_plain(SAMPLE, "user-bubble"), 2, "expect two user-bubble rounds")
        assert.matches(SAMPLE, '<div class="thought%-block">', "thought-block div missing")
        assert.matches(SAMPLE, 'The user asks', "reasoning text missing")
        assert.notMatches(SAMPLE, 'assistant%-label', "no assistant-label divs in new format")
        assert.notMatches(SAMPLE, '☺', "no Question label in new format")
        assert.notMatches(SAMPLE, '✦', "no Response label in new format")
        assert.matches(SAMPLE, '🌐 Frodo Baggins Ring bearer Mordor', "Search keyword line missing")
        assert.matches(SAMPLE, '---\n\n<div class="user%-bubble">', "inter-round --- before round two missing")
        assert.isTrue(count_sep_lines(SAMPLE) >= 3, "expect inter-round --- plus generic ---")
        assert.equal(count_plain(SAMPLE, "#q:"), 2, "expect two suggestion links")
    end),

    test("render: the search keyword line is the smallest heading", function()
        -- h6 is the smallest heading, and the base CSS zeroes the indent on
        -- every heading, so the keyword line sits flush left where a paragraph
        -- would carry the 1em indent.
        local html = unwrap_label(MD("###### \u{1F310} frodo mordor\n\n"))
        assert.matches(html, '<h6[^>]*>', "the keyword line must render as a heading")
        assert.notMatches(html, '<p>\u{1F310}', "it must not stay a paragraph")
    end),

    test("render: container divs survive as top-level divs after unwrap", function()
        local html = MD(SAMPLE)
        assert.notNil(html, "MD() must render the sample")
        assert.isTrue(type(html) == "string", "MD() must return HTML text")
        local unwrapped = unwrap_label(html)
        assert.matches(unwrapped, '<div class="user%-bubble">', "user-bubble div lost in render")
        assert.matches(unwrapped, '<div class="thought%-block">', "thought-block div lost in render")
        assert.notMatches(unwrapped, '<p>%s*<div class="user-bubble', "no p-wrapped user-bubble may remain")
        assert.notMatches(unwrapped, '<p>%s*<div class="thought-block', "no p-wrapped thought-block may remain")
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

    test("render: thought block carries reasoning text", function()
        local html = unwrap_label(MD(SAMPLE))
        assert.matches(html, '<div class="thought%-block">', "thought block must render")
        assert.matches(html, 'internal knowledge suffices', "reasoning body must survive rendering")
        local block_pos = html:find('thought-block', 1, true)
        assert.isTrue(block_pos ~= nil, "thought block must render")
    end),

    test("render: suggestion links kept, --- becomes hr", function()
        local html = apply_suggestion_class(unwrap_label(MD(SAMPLE)))
        assert.matches(html, '#q:', "suggestion href must be kept")
        assert.matches(html, '<a[^>]*href="#q:', "suggestion anchor must render")
        assert.matches(html, 'suggestion%-link', "suggestion anchor must carry the styling class")
        assert.matches(html, '<hr', "--- separators must render as hr")
        assert.matches(html, 'Tom Bombadil', "suggestion text must survive")
    end),

    test("unwrap: puremd p-wrapped container divs collapse, bare divs pass through", function()
        local wrapped = '<p><div class="user-bubble">X</div></p>'
        assert.equal(unwrap_label(wrapped), '<div class="user-bubble">X</div>')
        local bare = '<div class="thought-block">X</div>'
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
