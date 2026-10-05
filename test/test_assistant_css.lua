-- test_assistant_css.lua
-- The shared viewer CSS module (assistant_css.lua): a single BASE (table rules
-- included) built by build(), with the RTL mirror, the justify fragment and
-- the Response Font @font-face rules attaching only when asked.
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
        local carriers = { "user-bubble", "short-text", "long-text", "source-text",
            "thought-block", "dict-excerpt", "user-bubble-title", "user-bubble-meta",
            "suggestion-link" }
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
        assert.equal(CSS.build({ justified = false }), CSS.build())
    end),

    test("build: no CSS direction, no logical alignment", function()
        -- Blocks carry their direction inline (dir= and mirrored insets, see
        -- assistant_text_utils), so the stylesheet must hold no `direction`:
        -- it would inherit and suppress those attributes. `text-align: right`
        -- is out too -- MuPDF swaps left/right logically under RTL markup, so
        -- the default already right-aligns an RTL block.
        local css = CSS.build()
        assert.notMatches(css, 'direction:', "no rule may set a CSS direction")
        assert.notMatches(css, 'text%-align: right', "MuPDF swaps text-align logically under RTL markup")
        assert.notMatches(css, 'text%-align%-last', "MuPDF has no text-align-last")
    end),

    test("build: justify attaches only when asked", function()
        assert.notMatches(CSS.build(), 'text%-align: justify', "justify must stay off by default")
        assert.matches(CSS.build({ justified = true }), 'text%-align: justify', "justify fragment missing")
    end),

    test("build: the response font registers files with MuPDF", function()
        -- MuPDF resolves @font-face by file path; a family name alone falls
        -- back to its built-in fonts. Both @page and body carry the family.
        local css = CSS.build({ font = {
            family = "Vazirmatn",
            faces = {
                { path = "/fonts/Vazirmatn-Regular.ttf", weight = "normal", style = "normal" },
                { path = "/fonts/Vazirmatn-Bold.ttf", weight = "bold", style = "normal" },
            },
        } })
        assert.matches(css, '@font%-face', "the faces must be registered")
        assert.matches(css, "Vazirmatn%-Regular%.ttf", "the regular file must be registered")
        assert.matches(css, "Vazirmatn%-Bold%.ttf", "the bold file must be registered")
        assert.matches(css, 'font%-weight: bold', "the bold face must carry its weight")
        assert.matches(css, '@page { font%-family: \'Vazirmatn\'; }', "@page must carry the family")
        assert.matches(css, 'body { font%-family: \'Vazirmatn\'; }', "body must carry the family")
        -- No font, no font rules: the default stack is the base @page rule.
        local plain = CSS.build()
        assert.notMatches(plain, '@font%-face', "no font means no registration")
        assert.matches(plain, '@page', "the base @page block must stay")
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

    test("build: the bubble width classes and the source band", function()
        -- MuPDF has no max-width, so margin-left is the width cap: the length
        -- classes differ only in how much of the page they yield.
        local css = CSS.build()
        assert.matches(css, '%.short%-text%s*{[^}]*margin%-left: 38%%',
            "the chat shape must keep the 38% margin")
        assert.matches(css, '%.long%-text%s*{[^}]*margin%-left: 6%%',
            "a long turn must get the page")
        local rule = css:match('%.source%-text%s*{(.-)}')
        assert.notNil(rule, "the source block must be styled")
        assert.matches(rule, 'font%-size: 0%.8em',
            "the source block must stay subordinate to the answer")
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
