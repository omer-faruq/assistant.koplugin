-- test_assistant_css.lua
-- The shared viewer CSS module (assistant_css.lua): a single BASE (table rules
-- included) built by build(), with the RTL and justify fragments attaching
-- only when switched on.
--
-- The MuPDF constraints (see docs/UI_DIALOGS.md) are asserted against the
-- built CSS rather than the source file, and the rendered result is checked by
--   SDL_VIDEODRIVER=dummy ./test/runui.sh ui/markdown_render
-- The headless module is pure Lua with no KOReader requires, so it loads here.
local helper = require("test.helper")
local assert = helper.assert

local CSS = require("assistant_css")

-- MuPDF's css-properties.gperf is the whole property table: anything outside it
-- is dropped silently, so these are the properties the viewer layout depends on.
local function find(css, needle)
    return css:find(needle, 1, true) ~= nil
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("module surface: only build", function()
        assert.isTrue(type(CSS.build) == "function", "module must export build")
        assert.isTrue(CSS.TABLE_CSS == nil, "no independent table css export")
        assert.isTrue(CSS.build_notebook_append == nil, "no notebook append builder")
    end),

    test("build: default keeps base, carriers and table rules", function()
        local css = CSS.build()
        assert.matches(css, '@page', "base @page block missing")
        local carriers = { "user-bubble", "thought-block", "dict-excerpt",
            "user-bubble-title", "user-bubble-meta", "suggestion-link" }
        for carrier_idx = 1, #carriers do
            local class = carriers[carrier_idx]
            assert.isTrue(find(css, "." .. class .. " {"),
                "the " .. class .. " carrier must be styled")
        end
        assert.matches(css, 'border%-collapse', "table rules missing")
        assert.notMatches(css, 'code%.language%-reasoning',
            "the reasoning fence is unwrapped upstream, so its indent rule must stay gone")
        assert.notMatches(css, 'direction: rtl', "rtl must stay off by default")
        assert.notMatches(css, 'text%-align: justify', "justify must stay off by default")
    end),

    test("build: explicit false opts equal the default", function()
        assert.equal(CSS.build({ rtl = false, justified = false }), CSS.build())
    end),

    test("build: rtl and justify attach only when on", function()
        assert.matches(CSS.build({ rtl = true }), 'direction: rtl', "rtl fragment missing")
        assert.notMatches(CSS.build({ rtl = true }), 'text%-align: justify', "justify must not ride along with rtl")
        assert.matches(CSS.build({ justified = true }), 'text%-align: justify', "justify fragment missing")
        assert.notMatches(CSS.build({ justified = true }), 'direction: rtl', "rtl must not ride along with justify")
        local both = CSS.build({ rtl = true, justified = true })
        assert.matches(both, 'direction: rtl', "rtl fragment missing with both on")
        assert.matches(both, 'text%-align: justify', "justify fragment missing with both on")
    end),

    test("build: heading scale is capped at h1/h2", function()
        -- The base zeroes the indent on every heading, so h3-h6 stay default
        -- size and only the two the reader scrolls past are scaled.
        local css = CSS.build()
        assert.matches(css, 'font%-size: 1%.3em', "h1 1.3em must stay")
        assert.matches(css, 'font%-size: 1%.2em', "h2 1.2em must stay")
    end),

    test("build: the bubble right-aligns the way MuPDF honors", function()
        -- MuPDF's property table has no max-width and no auto margin, so the
        -- bubble right-aligns with a fixed percentage margin-left, which also
        -- caps how wide it can grow.
        local css = CSS.build()
        assert.isTrue(find(css, "margin-left: 38%"),
            "the bubble must right-align via a percentage margin-left")
        assert.notMatches(css, 'margin%-left: auto', "MuPDF does not honor an auto margin")
        assert.notMatches(css, 'max%-width', "MuPDF does not honor max-width")
        assert.notMatches(css, 'border%-radius', "MuPDF does not honor border-radius")
        -- A width would fix the box and, with no box-sizing, let padding and
        -- border overflow it; the bubble must stay shrink-to-fit.
        local rule = css:match("%.user%-bubble%s*{(.-)}")
        assert.notNil(rule, "the .user-bubble rule must exist")
        assert.notMatches(rule, "width:", "the bubble must not set a width")
    end),

    test("build: the carriers are the only backgrounded blocks", function()
        -- A new background-color on a body-level rule would paint the whole
        -- page; the carriers carry theirs on the container, and nothing else
        -- may.
        local css = CSS.build()
        assert.notMatches(css, 'body%s*{[^}]*background', "the body must stay unpainted")
        assert.notMatches(css, 'p%s*{[^}]*background', "paragraphs must stay unpainted")
    end),
}

return helper.runTests("assistant_css", tests)
