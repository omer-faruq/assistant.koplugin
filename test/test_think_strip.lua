-- test_think_strip.lua
-- Regression tests for inline <think> reasoning separation when the model
-- drops the opening tag (only </think> present): reasoning must not leak
-- into the answer. Both helpers below are local in source, so the tests
-- inline copies per docs/TESTING.md: split_think mirrors the <think>
-- fallback at the end of Querier:processStream (assistant_querier.lua),
-- strip_reasoning mirrors the local in assistant_viewer.lua.
local helper = require("test.helper")
local assert = helper.assert

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Mirror of the querier fallback. The source wraps reasoning in a fenced
-- ```reasoning block when show_reasoning is on; the mirror returns both
-- parts so tests can assert the split. Branch structure is kept identical.
local function split_think(text, show_reasoning)
    local think_close = text:find("</think>", 1, true)
    if think_close then
        local think_open = text:find("<think>", 1, true)
        if not think_open or think_open < think_close then
            local rs = think_open and think_open + 7 or 1
            local reasoning = text:sub(rs, think_close - 1)
            local answer = text:sub(think_close + 8):gsub("^%s+", "", 1)
            if show_reasoning then
                return answer, reasoning
            end
            return answer, nil
        end
    end
    return text, nil
end

-- Exact copy of strip_reasoning (assistant_viewer.lua), used when the
-- viewer hides reasoning.
local function strip_reasoning(text)
    text = text:gsub("#### [^\n]*%s*```reasoning%s*[%s%S]-%s*```%s*%-%-%-%s*", "")
    text = text:gsub("<think>[%s%S]-</think>", "")
    if not text:find("<think>", 1, true) then
        local close = text:find("</think>", 1, true)
        if close then text = text:sub(close + 8):gsub("^%s+", "", 1) end
    end
    return text
end

local tests = {
    test("split_think: paired tags at start, hidden", function()
        local answer, reasoning = split_think("<think>chain of thought</think>\n\nFinal answer.", false)
        assert.equal(answer, "Final answer.")
        assert.equal(reasoning, nil)
    end),

    test("split_think: paired tags at start, shown", function()
        local answer, reasoning = split_think("<think>chain of thought</think>\n\nFinal answer.", true)
        assert.equal(answer, "Final answer.")
        assert.equal(reasoning, "chain of thought")
    end),

    test("split_think: lone closing tag, hidden (reported bug)", function()
        local answer, reasoning = split_think("some reasoning here</think>Final answer.", false)
        assert.equal(answer, "Final answer.")
        assert.equal(reasoning, nil)
    end),

    test("split_think: lone closing tag, shown", function()
        local answer, reasoning = split_think("some reasoning here</think>Final answer.", true)
        assert.equal(answer, "Final answer.")
        assert.equal(reasoning, "some reasoning here")
    end),

    test("split_think: opening tag padded with whitespace", function()
        local answer, reasoning = split_think("\n<think>padded</think>\nAnswer.", false)
        assert.equal(answer, "Answer.")
        assert.equal(reasoning, nil)
    end),

    test("split_think: unclosed opening tag left alone", function()
        local answer, reasoning = split_think("<think>never closed", false)
        assert.equal(answer, "<think>never closed")
        assert.equal(reasoning, nil)
    end),

    test("split_think: close before open left alone", function()
        local text = "Answer?</think> noise <think>late"
        local answer, reasoning = split_think(text, false)
        assert.equal(answer, text)
        assert.equal(reasoning, nil)
    end),

    test("split_think: no tags unchanged", function()
        local answer, reasoning = split_think("Just an answer.", true)
        assert.equal(answer, "Just an answer.")
        assert.equal(reasoning, nil)
    end),

    test("strip_reasoning: paired block removed", function()
        assert.equal(strip_reasoning("<think>hidden</think>Visible."), "Visible.")
    end),

    test("strip_reasoning: fenced reasoning block removed", function()
        assert.equal(
            strip_reasoning("#### X\n\n```reasoning\nthought\n```\n\n---\n\nVisible."),
            "Visible.")
    end),

    test("strip_reasoning: lone closing tag removed", function()
        assert.equal(strip_reasoning("wandering thought</think>\nVisible."), "Visible.")
    end),

    test("strip_reasoning: plain text unchanged", function()
        assert.equal(strip_reasoning("Just an answer."), "Just an answer.")
    end),
}

return helper.runTests("think_strip", tests)
