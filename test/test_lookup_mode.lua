-- test_lookup_mode.lua
-- Tests for the Smart Dictionary Lookup routing helpers in assistant_lookup.lua:
-- script-aware routing of a highlight to the AI Dictionary (short) or the full
-- Translate action (long). CJK is counted by UTF-8 characters (no word
-- separators); other scripts by whitespace-delimited words.
local helper = require("test.helper")
local assert = helper.assert
local Lookup = require("assistant_lookup")
local CJK_MAX = Lookup.CJK_LOOKUP_MAX_CHARS
local WORD_MAX = Lookup.WORD_LOOKUP_MAX_WORDS

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Repeat a CJK character until the string has n UTF-8 characters.
local function cjk(n)
    return string.rep("苹", n)
end

-- Build n whitespace-separated Latin words (1-based count).
local function words(n)
    local list = {}
    for i = 1, n do
        list[i] = "w" .. i
    end
    return table.concat(list, " ")
end

local tests = {

    test("main.lua consumes assistant_lookup", function()
        -- The shipped module table, not a copy of it, must drive routing.
        assert.equal(type(Lookup), "table", "assistant_lookup must export a table")
        assert.equal(type(Lookup.lookup_mode_for_selection), "function",
            "assistant_lookup must export lookup_mode_for_selection")
        assert.equal(type(Lookup.resolve_translate_route), "function",
            "assistant_lookup must export resolve_translate_route")
        assert.equal(Lookup.lookup_mode_for_selection(words(WORD_MAX)), "dictionary",
            "the exported function must be the live implementation")
    end),

    test("nil selection -> translate", function()
        assert.equal(Lookup.lookup_mode_for_selection(nil), "translate",
            "nil should not be treated as a dictionary lookup")
    end),

    test("non-string selection -> translate", function()
        assert.equal(Lookup.lookup_mode_for_selection(42), "translate",
            "non-string input should fall back to translate")
        assert.equal(Lookup.lookup_mode_for_selection({}), "translate",
            "table input should fall back to translate")
    end),

    test("empty string -> translate", function()
        assert.equal(Lookup.lookup_mode_for_selection(""), "translate",
            "empty string should fall back to translate")
    end),

    test("whitespace-only selection -> translate", function()
        assert.equal(Lookup.lookup_mode_for_selection("   "), "translate",
            "whitespace-only input should fall back to translate")
    end),

    test("single word -> dictionary", function()
        assert.equal(Lookup.lookup_mode_for_selection("hello"), "dictionary",
            "one word should route to the dictionary")
    end),

    test("two words -> dictionary", function()
        assert.equal(Lookup.lookup_mode_for_selection("hello world"), "dictionary",
            "two words should route to the dictionary")
    end),

    test("exactly the word threshold -> dictionary", function()
        assert.equal(Lookup.lookup_mode_for_selection(words(WORD_MAX)), "dictionary",
            "the word threshold is inclusive for the dictionary")
    end),

    test("surrounding whitespace ignored, punctuation word count -> dictionary", function()
        assert.equal(Lookup.lookup_mode_for_selection("  hello,   world!  "), "dictionary",
            "leading/trailing whitespace should be trimmed; two words -> dictionary")
    end),

    test("one word over the word threshold -> translate", function()
        assert.equal(Lookup.lookup_mode_for_selection(words(WORD_MAX + 1)), "translate",
            "exceeding the word threshold routes to translate")
    end),

    test("newline-separated words -> translate", function()
        assert.equal(Lookup.lookup_mode_for_selection("one\ntwo\nthree\nfour\nfive\nsix"), "translate",
            "newline-separated words should still be counted as six -> translate")
    end),

    test("short CJK word -> dictionary", function()
        assert.equal(Lookup.lookup_mode_for_selection("苹果"), "dictionary",
            "two CJK characters should route to the dictionary")
    end),

    test("exactly the CJK character threshold -> dictionary", function()
        assert.equal(Lookup.lookup_mode_for_selection(cjk(CJK_MAX)), "dictionary",
            "the CJK character threshold is inclusive for the dictionary")
    end),

    test("one CJK character over the threshold -> translate", function()
        assert.equal(Lookup.lookup_mode_for_selection(cjk(CJK_MAX + 1)), "translate",
            "exceeding the CJK character threshold routes to translate")
    end),

    test("long CJK sentence -> translate", function()
        assert.equal(Lookup.lookup_mode_for_selection("这是一个很长的中文句子用于测试"), "translate",
            "a full CJK sentence must not be mis-routed to the dictionary")
    end),

    test("dictionary mode, nil choice -> ask", function()
        assert.equal(Lookup.resolve_translate_route(nil, "dictionary"), "ask",
            "never asked in dictionary mode should prompt the explainer")
    end),

    test("dictionary mode, true choice -> dictionary", function()
        assert.equal(Lookup.resolve_translate_route(true, "dictionary"), "dictionary",
            "smart lookup enabled should route to the dictionary")
    end),

    test("dictionary mode, false choice -> translate", function()
        assert.equal(Lookup.resolve_translate_route(false, "dictionary"), "translate",
            "smart lookup disabled should route to translate")
    end),

    test("translate mode, nil choice -> translate", function()
        assert.equal(Lookup.resolve_translate_route(nil, "translate"), "translate",
            "long selections never prompt even when never asked")
    end),

    test("translate mode, true choice -> translate", function()
        assert.equal(Lookup.resolve_translate_route(true, "translate"), "translate",
            "long selections never route to the dictionary")
    end),

    test("translate mode, false choice -> translate", function()
        assert.equal(Lookup.resolve_translate_route(false, "translate"), "translate",
            "long selections never route to the dictionary")
    end),
}

return helper.runTests("lookup_mode", tests)
