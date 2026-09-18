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

-- Inline copy of the <think> fallback branch in Querier:processStream
-- (assistant_querier.lua). The real method needs a subprocess mock, so only
-- its pure split/wrap logic is tested here, per AGENTS.md testing policy.
local function split_think(ret, show_reasoning)
    local think_open = ret:find("<think>", 1, true)
    local think_close = ret:find("</think>", 1, true)
    if think_open == 1 and think_close then
        local reasoning = ret:sub(8, think_close - 1)
        ret = ret:sub(think_close + 8):gsub("^%s+", "", 1)
        if show_reasoning then
            ret = "```reasoning\n" .. reasoning .. "\n```\n\n---\n\n" .. ret
        end
    elseif show_reasoning and not think_open and think_close then
        local reasoning = ret:sub(1, think_close - 1)
        ret = ret:sub(think_close + 8):gsub("^%s+", "", 1)
        ret = "```reasoning\n" .. reasoning .. "\n```\n\n---\n\n" .. ret
    end
    return ret
end

-- Inline mirror of the reasoning split in AssistantDialog:formatSingleMessage
-- (assistant_dialog.lua). The `---` separator is optional: `---`-requiring
-- shapes run first so fenced code inside legacy reasoning still splits at
-- the right closing fence. Returns reasoning, body; nil when absent.
local function split_reasoning_block(content)
    local reasoning, body = content:match(
        "^```reasoning%s*([%s%S]-)%s*```%s*%-%-%-%s*([%s%S]*)$")
    if not reasoning then
        reasoning, body = content:match(
            "^#### [^\n]*%s*```reasoning%s*([%s%S]-)%s*```%s*%-%-%-%s*([%s%S]*)$")
    end
    if not reasoning then
        reasoning, body = content:match(
            "^```reasoning%s*([%s%S]-)%s*```%s*([%s%S]*)$")
    end
    if not reasoning then
        reasoning, body = content:match(
            "^#### [^\n]*%s*```reasoning%s*([%s%S]-)%s*```%s*([%s%S]*)$")
    end
    if reasoning and reasoning:find("%S") then
        return reasoning, body
    end
    return nil, content
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

    test("think: prefixed pair wraps with show on, strips with show off", function()
        local input = "<think>Let me think.</think>\n\nThe answer."
        assert.equal(split_think(input, true),
            "```reasoning\nLet me think.\n```\n\n---\n\nThe answer.")
        assert.equal(split_think(input, false), "The answer.")
    end),

    test("think: missing opener still wraps with show on", function()
        local input = "Let me think.</think>\n\nThe answer."
        assert.matches(split_think(input, true), "```reasoning\nLet me think.\n```")
        assert.matches(split_think(input, true), "The answer%.$")
    end),

    test("think: mid-text tags left untouched", function()
        local input = "Talk about <think>tags</think> here."
        assert.equal(split_think(input, true), input)
        assert.equal(split_think(input, false), input)
    end),

    test("think: unclosed tag leaves content untouched", function()
        local input = "<think>Never ending thought."
        assert.equal(split_think(input, true), input)
    end),

    test("split: bare fence without separator splits", function()
        local reasoning, body = split_reasoning_block(
            "```reasoning\nthinking here\n```\n\nMain answer.")
        assert.equal(reasoning, "thinking here")
        assert.equal(body, "Main answer.")
    end),

    test("split: bare fence with separator splits cleanly", function()
        local reasoning, body = split_reasoning_block(
            "```reasoning\nthinking here\n```\n\n---\n\nMain answer.")
        assert.equal(reasoning, "thinking here")
        assert.equal(body, "Main answer.")
    end),

    test("split: legacy titled fence splits", function()
        local reasoning, body = split_reasoning_block(
            "#### X\n\n```reasoning\nthinking here\n```\n\nMain answer.")
        assert.equal(reasoning, "thinking here")
        assert.equal(body, "Main answer.")
    end),

    test("split: legacy fence with inner code splits at separator", function()
        local reasoning, body = split_reasoning_block(
            "#### X\n\n```reasoning\nthink ```code``` more\n```\n\n---\n\nMain answer.")
        assert.equal(reasoning, "think ```code``` more")
        assert.equal(body, "Main answer.")
    end),

    test("split: blank reasoning left alone", function()
        local reasoning, body = split_reasoning_block(
            "```reasoning\n   \n```\n\nMain answer.")
        assert.equal(reasoning, nil)
    end),

    test("split: no fence left alone", function()
        local reasoning, body = split_reasoning_block("Just an answer.")
        assert.equal(reasoning, nil)
        assert.equal(body, "Just an answer.")
    end),
}

return helper.runTests("suggestions.lua", tests)
