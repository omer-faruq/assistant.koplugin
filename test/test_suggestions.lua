-- test_suggestions.lua
-- Tests for TextUtils.process_suggestions with the ```reasoning fence:
--   * suggestions after a closed fence are converted to #q: links
--   * a <suggestions> literal inside the fence is ignored
--   * an unclosed fence means truncated reasoning: content untouched
--   * fenceless content keeps the plain behavior
--   * formatSingleMessage follows the Reasoning Text switch for a stored fence
local helper = require("test.helper")
local assert = helper.assert
local TextUtils = helper.TextUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Think-tag handling lives in TextUtils.strip_think_tags
-- (assistant_text_utils.lua, single source of truth); exercise it directly.
local function split_think(ret, show_reasoning, structured)
    return TextUtils.strip_think_tags(ret, structured, show_reasoning)
end

-- Inline mirror of the reasoning split in AssistantDialog:formatSingleMessage
-- (assistant_dialog.lua): the single bare-fence shape the querier emits.
-- Returns reasoning, body; nil when absent.
local function split_reasoning_block(content)
    local reasoning, body = content:match(
        "^```reasoning%s*([%s%S]-)%s*```%s*([%s%S]*)$")
    if reasoning and reasoning:find("%S") then
        return reasoning, body
    end
    return nil, content
end

local tests = {
    test("fence: trailing suggestions converted, fence kept", function()
        local input = "#### ❖ Deeply Thought\n\n```reasoning\nthinking here\n```\n\n---\n\nMain answer.\n<suggestions>\n- First question?\n- Second question?\n</suggestions>\n"
        local out = TextUtils.process_suggestions(input)
        assert.matches(out, "```reasoning\nthinking here\n```")
        assert.matches(out, "%[First question%?%]%(#q:")
        assert.matches(out, "%[Second question%?%]%(#q:")
        assert.notMatches(out, "<suggestions>")
    end),

    test("fence: literal tag inside reasoning ignored", function()
        local input = "```reasoning\nnote about <suggestions> format\n```\n\nBody.\n<suggestions>\n- Real question?\n</suggestions>\n"
        local out = TextUtils.process_suggestions(input)
        assert.matches(out, "%[Real question%?%]%(#q:")
        assert.matches(out, "note about <suggestions> format")
        assert.notMatches(out, "%[note about")
    end),

    test("fence: unclosed fence leaves content untouched", function()
        local input = "```reasoning\ntruncated thinking\n\nBody.\n<suggestions>\n- Lost question?\n</suggestions>\n"
        assert.equal(TextUtils.process_suggestions(input), input)
    end),

    test("plain: fenceless suggestions still converted", function()
        local input = "Main answer.\n<suggestions>\n- Plain question?\n</suggestions>\n"
        local out = TextUtils.process_suggestions(input)
        assert.matches(out, "%[Plain question%?%]%(#q:")
    end),

    test("plain: no tag leaves content untouched", function()
        local input = "Just an answer, nothing to do."
        assert.equal(TextUtils.process_suggestions(input), input)
    end),

    test("think: prefixed pair wraps with show on, strips with show off", function()
        local input = "<think>Let me think.</think>\n\nThe answer."
        assert.equal(split_think(input, true),
            "```reasoning\nLet me think.\n```\n\nThe answer.")
        assert.equal(split_think(input, false), "The answer.")
    end),

    test("think: missing opener still wraps with show on", function()
        local input = "Let me think.</think>\n\nThe answer."
        assert.matches(split_think(input, true), "```reasoning\nLet me think.\n```")
        assert.matches(split_think(input, true), "The answer%.$")
    end),

    test("think: mid-text splits at first close", function()
        local input = "Talk about <think>tags</think> here."
        assert.equal(split_think(input, true),
            "```reasoning\nTalk about <think>tags\n```\n\nhere.")
        assert.equal(split_think(input, false), "here.")
    end),

    test("think: unclosed tag leaves content untouched", function()
        local input = "<think>Never ending thought."
        assert.equal(split_think(input, true), input)
    end),

    test("think: single split only, later blocks left in place", function()
        local input = "<think>first</think> mid <think>second</think> answer"
        assert.equal(split_think(input, false), "mid <think>second</think> answer")
        assert.equal(split_think(input, true),
            "```reasoning\nfirst\n```\n\nmid <think>second</think> answer")
    end),

    test("think: uppercase tags pass through untouched", function()
        local input = "<THINK >loud thinking</THINK >\n\nThe answer."
        assert.equal(split_think(input, true), input)
        assert.equal(split_think(input, false), input)
    end),

    test("think: stray close splits at first close", function()
        local input = "Real answer prefix </think> <think>thinking</think> rest"
        assert.equal(split_think(input, false), "<think>thinking</think> rest")
        assert.equal(split_think(input, true),
            "```reasoning\nReal answer prefix \n```\n\n<think>thinking</think> rest")
    end),

    test("think: structured plus inline both stripped from answer", function()
        local input = "<think>inline thinking</think>\n\nThe answer."
        local out = split_think(input, true, "structured thinking")
        assert.matches(out, "structured thinking")
        assert.matches(out, "inline thinking")
        assert.matches(out, "The answer%.$")
        assert.notMatches(out, "<think>")
        assert.equal(split_think(input, false, "structured thinking"),
            "The answer.")
    end),

    test("split: bare fence splits", function()
        local reasoning, body = split_reasoning_block(
            "```reasoning\nthinking here\n```\n\nMain answer.")
        assert.equal(reasoning, "thinking here")
        assert.equal(body, "Main answer.")
    end),

    test("split: blank reasoning left alone", function()
        local reasoning, body = split_reasoning_block(
            "```reasoning\n   \n```\n\nMain answer.")
        assert.equal(reasoning, nil)
    end),

    test("strip: a leftover block is dropped, fence quoting is kept", function()
        assert.equal(TextUtils.stripSuggestions("Answer.\n<suggestions>\n- Next?\n</suggestions>\n"),
            "Answer.", "the block and everything after it must go")
        assert.equal(TextUtils.stripSuggestions("Just an answer."), "Just an answer.",
            "content without a block is untouched")
        -- A tag quoted inside the reasoning fence is not a real block.
        local quoted = "```reasoning\nnote about <suggestions> format\n```\n\nBody."
        assert.equal(TextUtils.stripSuggestions(quoted), quoted, "fence quoting must survive")
        assert.equal(TextUtils.stripSuggestions("```reasoning\ntruncated <suggestions>\n"),
            "```reasoning\ntruncated <suggestions>\n", "truncated reasoning is left alone")
    end),

    test("split: no fence left alone", function()
        local reasoning, body = split_reasoning_block("Just an answer.")
        assert.equal(reasoning, nil)
        assert.equal(body, "Just an answer.")
    end),

    test("split: the display switch decides Thought div vs answer only", function()
        local history = {
            { role = "system", content = "system prompt" },
            { role = "user", content = "Why?" },
            { role = "assistant",
                content = "```reasoning\nthinking here\n```\n\nThe answer." },
        }
        local function fmt(show_reasoning)
            return TextUtils.formatSingleMessage(history, history[3], {
                msg_idx = 3,
                settings = {
                    readSetting = function(dummy, key, def)
                        if key == "show_reasoning" then return show_reasoning end
                        return def
                    end,
                },
                default_config = { show_suggestions = false },
            })
        end
        -- On: the stored fence becomes a Thought block above the Response.
        local on = fmt(true)
        assert.matches(on, 'assistant%-label%-%-thought">❖ Deeply Thought</div>',
            "Thought div required while Reasoning Text is on")
        assert.matches(on, '```reasoning\nthinking here\n```', "fence must be kept")
        -- Off: a turn answered while it was on must not resurrect the thinking.
        local off = fmt(false)
        assert.notMatches(off, 'assistant%-label%-%-thought',
            "no Thought block while Reasoning Text is off")
        assert.notMatches(off, '```reasoning', "no fence while Reasoning Text is off")
        assert.matches(off, 'assistant%-label">✦ Response</div>', "Response div still required")
        assert.matches(off, 'The answer%.', "answer body must survive")
    end),
}

return helper.runTests("suggestions.lua", tests)
