-- test_block_direction.lua
-- The RTL pipeline's per-block direction pass (assistant_text_utils
-- apply_block_directions): word-majority direction with the first strong
-- character as tiebreak in "auto", a forced direction in "rtl", and a
-- byte-identical passthrough in "ltr".
--
-- The rules are pinned here because the two natural heuristics fail on
-- opposite inputs: first-strong misjudges a Persian sentence opening with a
-- Latin word, letter-counting misjudges a Persian sentence carrying long
-- Latin words. Word counting with a first-strong tiebreak must handle both.
local helper = require("test.helper")
local assert = helper.assert

local TextUtils = require("assistant_text_utils")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function apply(html, mode, fallback_rtl)
    return TextUtils.apply_block_directions(html, mode, fallback_rtl)
end

local function find(html, needle)
    return html:find(needle, 1, true) ~= nil
end

-- The direction of every element with the given tag name, in document order.
local function dirs_of(html, tagname)
    local out = {}
    local pos = 1
    while true do
        local at = html:find("<" .. tagname, pos, true)
        if not at then break end
        local gt = html:find(">", at, true)
        out[#out + 1] = html:sub(at, gt):match('dir="(%a+)"')
        pos = gt + 1
    end
    return out
end

local tests = {
    test("each block gets the direction of its own text", function()
        local html = apply("<p>این یک متن فارسی است.</p>\n<p>This is an English sentence.</p>",
            "auto", true)
        local dirs = dirs_of(html, "p")
        assert.equal(dirs[1], "rtl", "the Persian block must be RTL")
        assert.equal(dirs[2], "ltr", "the English block must be LTR")
    end),

    test("a Persian sentence opening with a Latin word stays RTL", function()
        -- First-strong would judge this LTR from the opening "iPhone".
        local dirs = dirs_of(apply("<p>iPhone 15 یک گوشی هوشمند و بسیار خوب است.</p>",
            "auto", true), "p")
        assert.equal(dirs[1], "rtl", "word majority must beat the first strong character")
    end),

    test("long Latin words do not outvote the Persian words", function()
        -- Letter counting would judge this LTR (17 Latin letters to 9);
        -- words are 3 to 3, and the first strong character settles it.
        local dirs = dirs_of(apply("<p>با iPhone Galaxy Ultra گوشی خوب</p>", "auto", true), "p")
        assert.equal(dirs[1], "rtl", "words must be counted, not letters")
    end),

    test("an English sentence with Persian words stays LTR", function()
        local dirs = dirs_of(apply("<p>The word کتاب means book.</p>", "auto", true), "p")
        assert.equal(dirs[1], "ltr", "English must stay LTR")
    end),

    test("a block without strong characters takes the fallback", function()
        assert.equal(dirs_of(apply("<p>2024 2025</p>", "auto", true), "p")[1], "rtl",
            "neutral block with an rtl fallback must be RTL")
        assert.equal(dirs_of(apply("<p>2024 2025</p>", "auto", false), "p")[1], "ltr",
            "neutral block with an ltr fallback must be LTR")
    end),

    test("an HTML entity is not a word", function()
        -- Unneutralized, the entity's "amp" would be a Latin word and the
        -- first strong character would flip the block.
        local dirs = dirs_of(apply("<p>&amp; سلام</p>", "auto", true), "p")
        assert.equal(dirs[1], "rtl", "entities must not vote")
    end),

    test("rtl forces every block RTL, code stays LTR", function()
        local html = apply("<p>This is English.</p><pre>سلام</pre>", "rtl", true)
        assert.equal(dirs_of(html, "p")[1], "rtl", "rtl must force the block")
        assert.equal(dirs_of(html, "pre")[1], "ltr", "code must stay LTR")
    end),

    test("ltr keeps the HTML untouched", function()
        local html = "<p>این یک متن فارسی است.</p><p>This is English.</p>"
        assert.equal(apply(html, "ltr", true), html, "ltr must be a byte-identical passthrough")
    end),

    test("nested containers are annotated, not mangled", function()
        local html = apply(
            '<div class="user-bubble"><div class="user-bubble-title">عنوان</div><p>متن</p></div>',
            "auto", true)
        local dirs = dirs_of(html, "div")
        assert.equal(dirs[1], "rtl", "the bubble must be annotated")
        assert.equal(dirs[2], "rtl", "the title must be annotated")
        assert.equal(dirs_of(html, "p")[1], "rtl", "the paragraph must be annotated")
    end),

    test("Arabic script gets the taller line-height, Latin does not", function()
        local html = apply("<p>متن فارسی</p><p>English text</p>", "auto", true)
        local at = html:find(">", 1, true)
        assert.isTrue(find(html:sub(1, at), "line-height:1.35"),
            "Arabic script clips at the default leading")
        local second = html:find("<p", at, true)
        assert.isFalse(find(html:sub(second), "line-height"),
            "Latin text needs no extra leading")
    end),

    test("an RTL block mirrors the base inset, an LTR block keeps it", function()
        local html = apply("<p>متن فارسی</p><p>English</p><ul><li>متن</li></ul>", "auto", true)
        local first_end = html:find(">", 1, true)
        assert.isTrue(find(html:sub(1, first_end), "padding-left:0;padding-right:1em"),
            "the RTL paragraph must indent on the leading side")
        local second = html:find("<p", first_end, true)
        local second_end = html:find(">", second, true)
        assert.isFalse(find(html:sub(second, second_end), "padding-right"),
            "the LTR paragraph must keep the base inset")
        assert.isTrue(find(html, '<ul style="line-height:1.35;padding-left:0;padding-right:2em" dir="rtl">'),
            "the RTL list must mirror the list inset")
    end),

    test("annotation merges into an existing style and replaces dir", function()
        local html = apply('<p style="color:red" dir="ltr">متن</p>', "auto", true)
        assert.isTrue(find(html,
                '<p style="color:red;line-height:1.35;padding-left:0;padding-right:1em" dir="rtl">'),
            "the style must be extended and dir replaced")
        local _, dirs = html:gsub("dir=", "")
        assert.equal(dirs, 1, "there must be exactly one dir attribute")
    end),

    test("text without tags passes through unchanged", function()
        local plain = "متن ساده بدون برچسب"
        assert.equal(apply(plain, "auto", true), plain, "plain text must not be touched")
        assert.equal(apply("", "auto", true), "", "empty input must stay empty")
    end),

    test("every direction mode is reachable and separately labelled", function()
        -- The settings list and the viewer menu's cycle both build from these,
        -- so no mode can become unreachable (the reason the setting is a
        -- string and not a tri-state boolean).
        assert.equal(#TextUtils.DIRECTION_MODES, 3, "three modes must be listed")
        local labels = {}
        for i = 1, #TextUtils.DIRECTION_MODES do
            local mode = TextUtils.DIRECTION_MODES[i]
            local label = TextUtils.direction_label(mode)
            assert.isTrue(label ~= "" and labels[label] == nil,
                "each mode needs its own non-empty label: " .. mode)
            labels[label] = true
        end
        -- Cycling from any mode visits all three and returns to the start.
        local mode, seen = "auto", {}
        for i = 1, #TextUtils.DIRECTION_MODES do
            assert.isTrue(seen[mode] == nil, "the cycle must not repeat before covering all modes")
            seen[mode] = true
            mode = TextUtils.DIRECTION_CYCLE[mode]
        end
        assert.equal(mode, "auto", "the cycle must return to its start")
        -- An unknown mode still has a label instead of nil.
        assert.equal(TextUtils.direction_label("bogus"), TextUtils.direction_label("auto"))
    end),

    test("headings, table cells and quotes are annotated too", function()
        local html = apply(
            "<h2>متن</h2><table><tr><td>متن</td></tr></table>"
            .. "<blockquote><p>متن</p></blockquote>", "auto", true)
        assert.equal(dirs_of(html, "h2")[1], "rtl", "the heading must be annotated")
        assert.equal(dirs_of(html, "td")[1], "rtl", "the table cell must be annotated")
        assert.equal(dirs_of(html, "blockquote")[1], "rtl", "the quote must be annotated")
        assert.equal(dirs_of(html, "p")[1], "rtl", "the quoted paragraph must be annotated")
    end),

    test("a '>' inside an attribute does not end the tag", function()
        local html = apply('<p>متن <img src="x.png" alt="a > b"/></p>', "auto", true)
        assert.isTrue(find(html, '<img src="x.png" alt="a > b"/>'),
            "the void tag must survive verbatim")
        assert.equal(dirs_of(html, "p")[1], "rtl", "the paragraph must still be annotated")
    end),

    test("unbalanced or stray markup degrades safely", function()
        -- An unclosed block is left as it came: no direction, no loss.
        assert.equal(apply("<p>متن بدون إغلاق", "auto", true), "<p>متن بدون إغلاق",
            "an unclosed block must pass through unchanged")
        -- A stray '<' in text must not be read as a tag.
        local stray = "a < b and c > d"
        assert.equal(apply(stray, "auto", true), stray, "stray angle brackets must survive")
    end),
}

return helper.runTests("block_direction", tests)
