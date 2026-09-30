-- test_markdown_css.lua
-- The markdown the viewer's HTML is built from: everything here goes through
-- the shipped assistant_mdparser (hoedown, or the pure-Lua fallback) and the
-- shipped assistant_text_utils pipeline. Nothing asserts on a copy of a
-- production function.
--
-- The display transform itself (ResultViewer._renderMarkdown, which unwraps the
-- parser's <p> around raw container divs and tags the #q: links) lives in the
-- widget-heavy viewer and is verified by rendering the real viewer instead:
--   SDL_VIDEODRIVER=dummy ./test/runui.sh ui/markdown_render
local helper = require("test.helper")
local assert = helper.assert
local TextUtils = helper.TextUtils

-- assistant_mdparser probes Device:isDesktop/isEmulator/isAndroid at load;
-- the headless stub only carries screen metrics, so add the predicates.
local device = package.loaded["device"] or require("device")
if device.isDesktop == nil then device.isDesktop = function() return true end end
if device.isEmulator == nil then device.isEmulator = function() return false end end
if device.isAndroid == nil then device.isAndroid = function() return false end end

local MD = require("assistant_mdparser")
local CSS = require("assistant_css")

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

local function count_plain(text, needle)
    local n, init = 0, 1
    while true do
        local hit = text:find(needle, init, true)
        if not hit then break end
        n = n + 1
        init = hit + 1
    end
    return n
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("parse: the sample renders HTML text", function()
        local html = MD(SAMPLE)
        assert.isTrue(type(html) == "string", "MD() must return HTML text")
        assert.isTrue(#html > #SAMPLE / 2, "MD() must return a rendered document")
    end),

    test("parse: LLM h1/h2 headings survive", function()
        local html = MD(SAMPLE)
        assert.matches(html, '<h1', "LLM h1 must render")
        assert.matches(html, 'The Ring and Its Nature', "LLM h1 text must survive")
        assert.matches(html, '<h2', "LLM h2 must render")
        assert.matches(html, 'Why It Corrupts', "LLM h2 text must survive")
    end),

    test("parse: the search keyword line is the smallest heading", function()
        -- h6 is the smallest heading, and the base CSS zeroes the indent on
        -- every heading, so the keyword line sits flush left where a paragraph
        -- would carry the 1em indent.
        local html = MD("###### \u{1F310} frodo mordor\n\n")
        assert.matches(html, '<h6[^>]*>', "the keyword line must render as a heading")
        assert.notMatches(html, '<p>\u{1F310}', "it must not stay a paragraph")
    end),

    test("parse: container divs stay top-level, never p-wrapped", function()
        -- The two user turns and the Thought block are the carriers the
        -- formatter emits; a <p> around them would add a paragraph indent to
        -- the styled box. When the parser does wrap them (the pure-Lua path),
        -- unwrapping them is the viewer's job, checked by the UI render test.
        local html = MD(SAMPLE)
        assert.equal(count_plain(html, '<div class="user-bubble">'), 2, "expect 2x user-bubble divs")
        assert.equal(count_plain(html, '<div class="thought-block">'), 1, "expect the thought block")
        assert.notMatches(html, '<p>%s*<div class="user%-bubble"', "no p-wrapped user-bubble may reach the viewer")
        assert.notMatches(html, '<p>%s*<div class="thought%-block"', "no p-wrapped thought-block may reach the viewer")
    end),

    test("parse: a div the CSS does not style is left alone", function()
        -- hoedown's footnotes block is a div too, and it is not a container the
        -- viewer unwraps; it must arrive as the parser emitted it.
        local html = MD(SAMPLE)
        assert.matches(html, '<div class="footnotes"', "the footnotes block must render")
    end),

    test("parse: --- becomes hr, suggestion links keep their href", function()
        local html = MD(SAMPLE)
        local hrs = 0
        for hr_tag in html:gmatch("<hr") do hrs = hrs + 1 end
        assert.isTrue(hrs >= 3, "the inter-round and generic --- separators must render as hr, got " .. hrs)
        assert.matches(html, '<a[^>]*href="#q:', "suggestion anchor must render")
        assert.equal(count_plain(html, "#q:"), 2, "expect two suggestion links")
        assert.matches(html, 'Tom Bombadil', "suggestion text must survive")
    end),

    test("parse: a pipe table becomes real table markup", function()
        -- The parser post-processor turns a pipe block into <table>; without it
        -- MuPDF would show the pipes as body text.
        local html = MD("| A | B |\n| --- | --- |\n| 1 | 2 |\n")
        assert.matches(html, '<table>', "a pipe table must become a table")
        assert.matches(html, '<th>A</th>', "the header row must become th cells")
        assert.matches(html, '<td>1</td>', "the body row must become td cells")
    end),

    test("parse: a fenced code block keeps its content", function()
        local html = MD("```lua\nprint('hello')\n```\n")
        assert.matches(html, '<pre>', "a fence must render as pre")
        assert.matches(html, 'hello', "the fenced source must survive")
    end),

    test("parse: a bare angle bracket in prose is escaped", function()
        local html = MD("a < b and c > d\n")
        assert.matches(html, '&lt;', "a bare < must be escaped")
        assert.matches(html, '&gt;', "a bare > must be escaped")
    end),

    test("pipeline: Reasoning-Text-off never reaches the renderer", function()
        -- The drop happens when the answer is produced, so the parser only ever
        -- sees the answer body (querier: strip_think_tags(_, _, false)).
        local answer_only = TextUtils.strip_think_tags(
            "<think>no web search is needed</think>\n\nThe Ring is corrupting.", nil, false)
        assert.equal(answer_only, "The Ring is corrupting.", "think-tag reasoning must be dropped")
        local html = MD(answer_only)
        assert.notMatches(html, '<think>', "rendered HTML must not contain think tags")
        assert.notMatches(html, '```reasoning', "rendered HTML must not contain a fence")
        assert.matches(html, 'The Ring is corrupting', "answer body must survive")
    end),

    test("css: every carrier class the parser emits is styled", function()
        -- A class dropped from the CSS would leave the carrier unstyled while
        -- the document still rendered, so the two are checked against each
        -- other. Plain find: a class name may contain a "-", which a Lua
        -- pattern would read as a quantifier.
        local html = MD(SAMPLE)
        local css = CSS.build()
        for class in html:gmatch('<div class="([^"]*)"') do
            -- footnotes is hoedown's own wrapper, not one of our carriers.
            if class ~= "footnotes" then
                assert.isTrue(css:find("." .. class .. " {", 1, true) ~= nil,
                    "the parser emits div class " .. class .. " but the CSS does not style it")
            end
        end
        assert.isTrue(css:find(".suggestion-link {", 1, true) ~= nil,
            "the class the viewer stamps on #q: links must be styled")
    end),
}

return helper.runTests("markdown_css.lua", tests)
