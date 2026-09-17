-- test_suggestions.lua
-- Tests for ASUtils.process_suggestions with the ```reasoning fence:
--   * suggestions after a closed fence are converted to #q: links
--   * a <suggestions> literal inside the fence is ignored
--   * an unclosed fence means truncated reasoning: content untouched
--   * fenceless content keeps the plain behavior
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("fence: trailing suggestions converted, fence kept", function()
        local input = "#### ※ Deeply Thought\n\n```reasoning\nthinking here\n```\n\n---\n\nMain answer.\n<suggestions>\n- First question?\n- Second question?\n</suggestions>\n"
        local out = ASUtils.process_suggestions(input)
        assert.matches(out, "```reasoning\nthinking here\n```")
        assert.matches(out, "%[First question%?%]%(#q:")
        assert.matches(out, "%[Second question%?%]%(#q:")
        assert.notMatches(out, "<suggestions>")
    end),

    test("fence: literal tag inside reasoning ignored", function()
        local input = "```reasoning\nnote about <suggestions> format\n```\n\nBody.\n<suggestions>\n- Real question?\n</suggestions>\n"
        local out = ASUtils.process_suggestions(input)
        assert.matches(out, "%[Real question%?%]%(#q:")
        assert.matches(out, "note about <suggestions> format")
        assert.notMatches(out, "%[note about")
    end),

    test("fence: unclosed fence leaves content untouched", function()
        local input = "```reasoning\ntruncated thinking\n\nBody.\n<suggestions>\n- Lost question?\n</suggestions>\n"
        assert.equal(ASUtils.process_suggestions(input), input)
    end),

    test("plain: fenceless suggestions still converted", function()
        local input = "Main answer.\n<suggestions>\n- Plain question?\n</suggestions>\n"
        local out = ASUtils.process_suggestions(input)
        assert.matches(out, "%[Plain question%?%]%(#q:")
    end),

    test("plain: no tag leaves content untouched", function()
        local input = "Just an answer, nothing to do."
        assert.equal(ASUtils.process_suggestions(input), input)
    end),
}

return helper.runTests("suggestions.lua", tests)
