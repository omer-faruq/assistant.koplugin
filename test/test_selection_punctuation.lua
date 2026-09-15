-- test_selection_punctuation.lua
-- Tests for ASUtils.strip_selection_punctuation in assistant_utils.lua.
--
-- Context: a KOReader word selection can carry the sentence punctuation
-- ("Docile."), which the AI Dictionary then looked up and bolded as the
-- headword. The helper trims whitespace/punctuation from the selection edges
-- before the word is passed to the prompt.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

local function assertStripped(input, expected)
    assert.equal(ASUtils.strip_selection_punctuation(input), expected,
        "unexpected stripped value for " .. tostring(input))
end

local tests = {
    test("trailing period is stripped", function()
        assertStripped("Docile.", "Docile")
    end),

    test("bare word is returned unchanged", function()
        assertStripped("Docile", "Docile")
    end),

    test("surrounding quote and comma are stripped", function()
        assertStripped('"Docile,"', "Docile")
    end),

    test("internal apostrophe is preserved", function()
        assertStripped("don't", "don't")
    end),

    test("internal hyphen is preserved", function()
        assertStripped("well-known", "well-known")
    end),

    test("CJK trailing mark is stripped", function()
        assertStripped("他说。", "他说")
    end),

    test("guillemets are stripped", function()
        assertStripped("«mot»", "mot")
    end),

    test("surrounding whitespace is stripped", function()
        assertStripped("  Docile  ", "Docile")
    end),

    test("punctuation-only selection is returned unchanged", function()
        assertStripped("...", "...")
    end),

    test("non-string is returned unchanged", function()
        assert.equal(ASUtils.strip_selection_punctuation(nil), nil)
    end),
}

return helper.runTests("selection_punctuation", tests)
