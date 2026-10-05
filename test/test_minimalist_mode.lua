-- test_minimalist_mode.lua
-- Guards the Response Settings "Minimalist Mode" switch:
--   * the reply is assembled answer-only (a separate emitter shape, not a
--     filter over the labelled one): no Question/Thought/Response/Search
--     carrier, no prompt name, and nothing to cut because the querier already
--     drops reasoning and the follow-up switch keeps suggestions out
--   * the standard shape is untouched when the switch is off
-- The result window's own Minimalist Mode behavior (nav row, chrome actions,
-- page-button feedback, greyed-out sub-switches) is not reachable headlessly
-- and is owned by test/test_viewer_menu.lua.
-- Headless-safe: the pure formatter is exercised directly; the widget-heavy
-- viewer/dialog sources are not required here.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local TextUtils = require("assistant_text_utils")

local function make_msg(role, content)
    return { role = role, content = content }
end

-- Settings stub: follow-ups on (so the labelled shape would render them).
local function make_settings(suggest_on)
    return {
        readSetting = function(dummy, key, def)
            if key == "auto_prompt_suggest" then return suggest_on end
            return def
        end,
    }
end

local function fmt(message, opts)
    return TextUtils.formatSingleMessage({}, message, opts)
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("minimal: prompt turn shows the answer only", function()
        local user = make_msg("user", "TEMPLATE TEXT THAT MUST NOT LEAK")
        ASUtils.set_attr(user, "prompt_title", "Explain")
        local answer = make_msg("assistant", "Gandalf is a Maia.")
        local out = fmt(user, { minimal = true }) .. fmt(answer, { minimal = true })
        assert.equal(out, "Gandalf is a Maia.\n\n", "only the answer may be emitted")
        assert.notMatches(out, "assistant-label", "no carrier may survive")
        assert.notMatches(out, "Explain", "the prompt name is a title and must go")
        assert.notMatches(out, "TEMPLATE TEXT", "the prompt template must not leak")
    end),

    test("minimal: typed question survives without its label", function()
        local user = make_msg("user", "TEMPLATE")
        ASUtils.set_attr(user, "prompt_title", "Translate")
        ASUtils.set_attr(user, "user_input", "hello world")
        local out = fmt(user, { minimal = true })
        assert.equal(out, "hello world\n\n", "only the typed text may be emitted")
        assert.notMatches(out, "➤", "the question marker is chrome")
    end),

    test("minimal: free question keeps its text, book blocks compacted", function()
        local user = make_msg("user", "Why this?[BOOK TEXT BEGIN]lots of text[BOOK TEXT END]")
        local out = fmt(user, { minimal = true })
        assert.equal(out, "Why this?[BOOK TEXT]\n\n", "book text must collapse to the placeholder")
        assert.notMatches(out, "☺", "no Question label")
    end),

    test("minimal: answer is emitted as produced, nothing filtered", function()
        -- With Reasoning Text and Follow-up Questions off, the querier already
        -- hands over the bare answer, so the template only adds block spacing.
        local produced = TextUtils.strip_think_tags(
            "<think>thinking hard</think>\n\nThe answer.", nil, false)
        local out = fmt(make_msg("assistant", produced), { minimal = true })
        assert.equal(out, "The answer.\n\n", "the answer must pass through unchanged")
    end),

    test("minimal: search turn keeps the keyword line, loses the label", function()
        local search = make_msg("assistant", "raw")
        ASUtils.set_attr(search, "search_keywords", "🌐 Frodo Baggins\n\n")
        local out = fmt(search, { minimal = true })
        assert.equal(out, string.format("%s\n\n", "🌐 Frodo Baggins\n\n"),
            "keyword line must survive as content")
        assert.notMatches(out, "user%-bubble", "minimalist mode must not wrap the answer")
    end),

    test("minimal: a fence from before the mode was switched on is cut", function()
        -- Answer-only is the mode's contract, so a leftover fence must not
        -- reach the page even if the turn was produced with reasoning on.
        local answer = make_msg("assistant", "```reasoning\nthinking hard\n```\n\nThe answer.")
        local out = fmt(answer, { minimal = true })
        assert.equal(out, "The answer.\n\n", "only the answer body may be emitted")
    end),

    test("minimal: answer block ends so the next turn starts a new block", function()
        -- Without the trailing blank line a list item and the following
        -- question merge into one line once the labels are gone.
        local answer = make_msg("assistant", "- first point\n- second point")
        local question = make_msg("user", "And who forged it?")
        local out = fmt(answer, { minimal = true }) .. fmt(question, { minimal = true })
        assert.equal(out, "- first point\n- second point\n\nAnd who forged it?\n\n",
            "blocks must stay separated")
    end),

    test("standard shape still renders the bubbles", function()
        local user = make_msg("user", "Why this?")
        local answer = make_msg("assistant", "Because.")
        local out = fmt(user, { settings = make_settings(false) })
            .. fmt(answer, { settings = make_settings(false) })
        assert.matches(out, '<div class="user%-bubble[^"]*">Why this%?</div>', "user bubble required")
        assert.matches(out, "Because%.", "answer body required")
        -- The carriers the minimalist mode removes are gone from the standard
        -- shape too: the bubble replaces the Question label outright.
        assert.notMatches(out, "assistant%-label", "no carrier may survive")
        assert.notMatches(out, "➤", "the question marker is chrome")
    end),
}

return helper.runTests("minimalist_mode", tests)
