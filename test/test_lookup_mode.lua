-- test_lookup_mode.lua
-- Tests for the Smart Lookup routing helpers, which live as locals in
-- main.lua (sole caller): script-aware routing of a highlight to the AI
-- Dictionary (short) or the full Translate action (long).
-- CJK is counted by UTF-8 characters (no word separators); other scripts by
-- whitespace-delimited words. Restored after dc7a373 / issues #207/#208.
--
-- main.lua is widget-heavy and never required headless, so the pure logic is
-- mirrored here inline; a source-shape guard below checks the real locals
-- live in main.lua.
local helper = require("test.helper")
local assert = helper.assert
local koutil = require("util")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Inline mirror of main.lua locals (verbatim logic).
local CJK_LOOKUP_MAX_CHARS = 8
local WORD_LOOKUP_MAX_WORDS = 5

local function lookup_mode_for_selection(text)
  if type(text) ~= "string" then return "translate" end
  local trimmed = text:match("^%s*(.-)%s*$")
  if trimmed == "" then return "translate" end

  if koutil.hasCJKChar(trimmed) then
    local count = 0
    for char in trimmed:gmatch(koutil.UTF8_CHAR_PATTERN) do
      count = count + 1
    end
    return count <= CJK_LOOKUP_MAX_CHARS and "dictionary" or "translate"
  end

  local word_count = select(2, trimmed:gsub("%S+", ""))
  return word_count <= WORD_LOOKUP_MAX_WORDS and "dictionary" or "translate"
end

local function resolve_translate_route(choice, mode)
  if mode ~= "dictionary" then return "translate" end
  if choice == nil then return "ask" end
  return choice and "dictionary" or "translate"
end

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    if not f then return nil end
    local src = f:read("*all")
    f:close()
    return src
end

local tests = {

    test("shape: main.lua owns the lookup locals", function()
        assert.notNil(project_root, "could not locate project root")
        local src = read_source("main.lua")
        assert.notNil(src, "could not read main.lua")
        assert.matches(src, "local function lookup_mode_for_selection",
            "main.lua must define local lookup_mode_for_selection")
        assert.matches(src, "local function resolve_translate_route",
            "main.lua must define local resolve_translate_route")
        assert.matches(src, "local CJK_LOOKUP_MAX_CHARS",
            "main.lua must own the CJK threshold const")
        assert.notMatches(src, "ASUtils%.lookup_mode_for_selection",
            "main.lua must not call ASUtils.lookup_mode_for_selection")
        assert.notMatches(src, "ASUtils%.resolve_translate_route",
            "main.lua must not call ASUtils.resolve_translate_route")
    end),

    test("nil selection -> translate", function()
        assert.equal(lookup_mode_for_selection(nil), "translate",
            "nil should not be treated as a dictionary lookup")
    end),

    test("non-string selection -> translate", function()
        assert.equal(lookup_mode_for_selection(42), "translate",
            "non-string input should fall back to translate")
        assert.equal(lookup_mode_for_selection({}), "translate",
            "table input should fall back to translate")
    end),

    test("empty string -> translate", function()
        assert.equal(lookup_mode_for_selection(""), "translate",
            "empty string should fall back to translate")
    end),

    test("whitespace-only selection -> translate", function()
        assert.equal(lookup_mode_for_selection("   "), "translate",
            "whitespace-only input should fall back to translate")
    end),

    test("single word -> dictionary", function()
        assert.equal(lookup_mode_for_selection("hello"), "dictionary",
            "one word should route to the dictionary")
    end),

    test("two words -> dictionary", function()
        assert.equal(lookup_mode_for_selection("hello world"), "dictionary",
            "two words should route to the dictionary")
    end),

    test("exactly five words -> dictionary", function()
        assert.equal(lookup_mode_for_selection("The quick brown fox jumps"), "dictionary",
            "five words is the inclusive dictionary threshold")
    end),

    test("surrounding whitespace ignored, punctuation word count -> dictionary", function()
        assert.equal(lookup_mode_for_selection("  hello,   world!  "), "dictionary",
            "leading/trailing whitespace should be trimmed; two words -> dictionary")
    end),

    test("exactly six words -> translate", function()
        assert.equal(lookup_mode_for_selection("The quick brown fox jumps over"), "translate",
            "six words exceeds the dictionary threshold")
    end),

    test("six newline-separated words -> translate", function()
        assert.equal(lookup_mode_for_selection("one\ntwo\nthree\nfour\nfive\nsix"), "translate",
            "newline-separated words should still be counted as six -> translate")
    end),

    test("short CJK word -> dictionary", function()
        assert.equal(lookup_mode_for_selection("苹果"), "dictionary",
            "two CJK characters should route to the dictionary")
    end),

    test("exactly eight CJK characters -> dictionary", function()
        assert.equal(lookup_mode_for_selection("苹果苹果苹果苹果"), "dictionary",
            "eight CJK characters is the inclusive dictionary threshold")
    end),

    test("nine CJK characters -> translate", function()
        assert.equal(lookup_mode_for_selection("苹果苹果苹果苹果苹"), "translate",
            "nine CJK characters exceeds the dictionary threshold")
    end),

    test("long CJK sentence -> translate", function()
        assert.equal(lookup_mode_for_selection("这是一个很长的中文句子用于测试"), "translate",
            "a full CJK sentence must not be mis-routed to the dictionary")
    end),

    test("dictionary mode, nil choice -> ask", function()
        assert.equal(resolve_translate_route(nil, "dictionary"), "ask",
            "never asked in dictionary mode should prompt the explainer")
    end),

    test("dictionary mode, true choice -> dictionary", function()
        assert.equal(resolve_translate_route(true, "dictionary"), "dictionary",
            "smart lookup enabled should route to the dictionary")
    end),

    test("dictionary mode, false choice -> translate", function()
        assert.equal(resolve_translate_route(false, "dictionary"), "translate",
            "smart lookup disabled should route to translate")
    end),

    test("translate mode, nil choice -> translate", function()
        assert.equal(resolve_translate_route(nil, "translate"), "translate",
            "long selections never prompt even when never asked")
    end),

    test("translate mode, true choice -> translate", function()
        assert.equal(resolve_translate_route(true, "translate"), "translate",
            "long selections never route to the dictionary")
    end),

    test("translate mode, false choice -> translate", function()
        assert.equal(resolve_translate_route(false, "translate"), "translate",
            "long selections never route to the dictionary")
    end),
}

return helper.runTests("lookup_mode", tests)
