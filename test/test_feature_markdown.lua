-- test_feature_markdown.lua
-- The feature dialog's result shape, driven through the shipped renderer:
-- Conversation.Renderer.render / render_increment, which in turn call
-- assistant_text_utils.formatSingleMessage. No production function is copied
-- into this file and no production file is scanned for its own text: the only
-- source scan left is the web-search wiring, which is a property of the
-- dialog's own closures and cannot be observed from the renderer.
--
-- Headless-safe: the widget-heavy dialogs are never required here.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local Conversation = require("assistant_conversation")

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local feature_src = read_source("assistant_featuredialog.lua")

-- Settings stub: follow-ups and (optionally) Reasoning Text on.
local function make_settings(suggest_on, reasoning_on)
    return {
        readSetting = function(dummy, key, def)
            if key == "auto_prompt_suggest" then return suggest_on end
            if key == "show_reasoning" then return reasoning_on or false end
            return def
        end,
    }
end

-- The renderer reads minimalist_mode through the same settings object.
local function render(history, opts)
    opts = opts or {}
    return Conversation.Renderer.render(history, {
        header = opts.header,
        title = opts.title,
        settings = opts.settings or make_settings(false),
        default_config = opts.default_config or { show_suggestions = false },
    })
end

local function make_msg(role, content)
    return { role = role, content = content }
end

local function make_history()
    return {
        make_msg("system", "system prompt"),
        make_msg("user", "Recap the story so far."),
    }
end

local function count_plain(text, needle)
    local n, init = 0, 1
    while true do
        local hit = text:find(needle, init, true)
        if not hit then break end
        n = n + 1
        init = hit + 1
    end
    return n
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("render: the header leads once, then the history", function()
        local history = make_history()
        local answer_msg = make_msg("assistant", "Frodo carries the Ring.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = render(history, { header = "HEADER\n\n" })
        assert.matches(out, '^HEADER', "the header must lead exactly once")
        assert.equal(count_plain(out, "HEADER"), 1, "the header must not be repeated per turn")
        assert.matches(out, '<div class="user%-bubble[^"]*">', "the user turn must render a bubble")
        assert.matches(out, 'Frodo carries the Ring', "the answer body must survive")
        assert.notMatches(out, 'system prompt', "the system prompt must never reach the page")
    end),

    test("render: no header, no leading newline", function()
        local history = make_history()
        local out = render(history)
        assert.matches(out, '^<div class="user%-bubble[^"]*">', "the first thing on the page must be the bubble")
    end),

    test("render: a context message is skipped, a free turn is not", function()
        -- The feature dialog tags its prompt turn as context, so it must not
        -- draw a bubble; the follow-up it appends is a real turn.
        local history = { make_msg("system", "system prompt") }
        local prompt = make_msg("user", "PROMPT TEMPLATE THAT MUST NOT LEAK")
        ASUtils.set_attr(prompt, "is_context", true)
        table.insert(history, prompt)
        local followup = make_msg("user", "Who carries it?")
        table.insert(history, followup)
        local answer_msg = make_msg("assistant", "Frodo does.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = render(history, { header = "HEADER\n\n" })
        assert.notMatches(out, 'PROMPT TEMPLATE', "the prompt template must never reach the page")
        assert.equal(count_plain(out, '<div class="user-bubble'), 1, "only the free follow-up may draw a bubble")
        assert.matches(out, 'Who carries it', "the free turn must render")
        assert.matches(out, 'Frodo does', "the answer must render")
    end),

    test("render: book identity rides inside the bubble, after the caption", function()
        local settings = make_settings(false)
        local ctx = make_msg("user", "PROMPT TEMPLATE THAT MUST NOT LEAK")
        ASUtils.set_attr(ctx, "prompt_title", "Book Summary & Recs")
        ASUtils.set_attr(ctx, "bubble_meta",
            '<div class="user-bubble-meta"><p><b>Title</b>: The Lord of the Rings</p>'
            .. '<p><b>Author</b>: J.R.R. Tolkien</p><p><b>Reading progress</b>: 45%</p></div>\n')
        local history = { make_msg("system", "system prompt"), ctx }
        local answer_msg = make_msg("assistant", "Frodo carries the Ring.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)

        local out = render(history)
        local bubble = out:match('<div class="user%-bubble[^"]*">(.-)</div>\n\n')
        assert.notNil(bubble, "a user bubble must be rendered")
        local title_pos = bubble:find("user%-bubble%-title")
        local meta_pos = bubble:find("user%-bubble%-meta")
        assert.notNil(title_pos, "the bubble must carry its caption")
        assert.notNil(meta_pos, "the bubble must carry its meta block")
        assert.isTrue(title_pos < meta_pos,
            "the caption must come first, the meta must follow it")
        assert.matches(bubble, 'user%-bubble%-title">‹ Book Summary & Recs ›</div>',
            "the caption must name the prompt")
        -- Plain find: a trailing "%" would be read as a dangling escape.
        assert.isTrue(bubble:find("<b>Reading progress</b>: 45%", 1, true) ~= nil,
            "the meta must carry the reading position")
        assert.notMatches(out, 'PROMPT TEMPLATE', "the prompt template must never reach the page")
    end),

    test("render: a turn without meta renders no meta block", function()
        local ctx = make_msg("user", "Free question.")
        ASUtils.set_attr(ctx, "prompt_title", "Translate")
        local history = { make_msg("system", "system prompt"), ctx }
        local out = render(history)
        assert.matches(out, '<div class="user%-bubble[^"]*">', "the turn must still draw a bubble")
        assert.notMatches(out, 'user%-bubble%-meta', "no meta block without the attr")
    end),

    test("render: the search keyword line and the answer share one turn", function()
        -- The querier appends its Search div in place in the history, so walking
        -- the history is what makes it render at all.
        local settings = make_settings(true)
        local history = make_history()
        local search_msg = make_msg("assistant", "raw assistant turn")
        ASUtils.set_attr(search_msg, "search_keywords", "\u{1F310} Frodo Baggins\n\n")
        table.insert(history, search_msg)
        local answer_msg = make_msg("assistant", "Frodo carries the Ring.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = render(history, { header = "HEADER\n\n", settings = settings })
        assert.matches(out, '^HEADER', "the header must lead once")
        assert.matches(out, '<div class="user%-bubble[^"]*">', "the user turn must render a bubble")
        assert.matches(out, '\u{1F310} Frodo Baggins', "the search keywords must render")
        assert.matches(out, 'Frodo carries the Ring', "the answer body must survive")
        assert.notMatches(out, '### ', "no h3 container headings may appear")
        assert.isTrue(out:find("Frodo Baggins") < out:find("Frodo carries the Ring"),
            "the search line must come before the answer it belongs to")
    end),

    test("render_increment: --- separator, then the two new turns", function()
        local settings = make_settings(true)
        local history = make_history()
        local followup = make_msg("user", "Who carries it?")
        ASUtils.set_attr(followup, "show_suggestions", true)
        table.insert(history, followup)
        local answer_msg = make_msg("assistant", "Frodo does.\n<suggestions>\n- Why him?\n</suggestions>\n")
        ASUtils.set_attr(answer_msg, "show_suggestions", true)
        table.insert(history, answer_msg)
        -- The page as it stood before the follow-up was asked.
        local before = render(make_history(), { header = "HEADER\n\n" })
        assert.equal(count_plain(before, '<div class="user-bubble'), 1, "one turn on the page so far")

        local inc = Conversation.Renderer.render_increment(history, {
            title = nil,
            settings = settings,
            default_config = { show_suggestions = true },
        })
        assert.matches(inc, '^%-%-%-\n\n<div', "the increment must start with the --- separator")
        assert.matches(inc, 'Who carries it', "the follow-up question must render")
        assert.matches(inc, 'Frodo does', "the answer must render")
        assert.matches(inc, '#q:', "suggestions must be processed exactly once by the pipeline")
        assert.notMatches(inc, '<suggestions>', "the suggestion tags must be consumed")
        assert.notMatches(inc, '### ⮞', "no old container headings may appear")
        -- The increment is appended to what is already on the page, so it must
        -- add the new turns and not repeat the earlier ones.
        local full = before .. inc
        assert.equal(count_plain(full, '<div class="user-bubble'), 2,
            "appending the increment must add exactly one more bubble")
        assert.equal(count_plain(full, 'Recap the story so far'), 1,
            "the increment must not repeat the earlier turn")
    end),

    test("render_increment: the Reasoning Text switch decides the Thought div", function()
        local history = make_history()
        local answer_msg = make_msg("assistant", "```reasoning\nthinking here\n```\n\nThe Ring rules them all.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local on = Conversation.Renderer.render_increment(history, {
            settings = make_settings(false, true),
            default_config = { show_suggestions = false },
        })
        assert.matches(on, '<div class="thought%-block">', "Thought block missing while the switch is on")
        assert.matches(on, 'thinking here', "reasoning body must be kept")
        assert.matches(on, 'The Ring rules them all', "answer body must survive")
        -- Switch off: a turn answered while it was on still carries its fence,
        -- and must not resurrect the thinking once the switch is off.
        local off = Conversation.Renderer.render_increment(history, {
            settings = make_settings(false, false),
            default_config = { show_suggestions = false },
        })
        assert.notMatches(off, 'thought%-block', "no Thought block while the switch is off")
        assert.notMatches(off, '```reasoning', "no fence while the switch is off")
        assert.matches(off, 'The Ring rules them all', "answer body must survive")
    end),

    test("render: suggestion inheritance follows the dialog rules", function()
        local history = make_history()
        ASUtils.set_attr(history[2], "show_suggestions", true)
        local answer_msg = make_msg("assistant", "Frodo does.\n<suggestions>\n- Why him?\n</suggestions>\n")
        table.insert(history, answer_msg)
        local out = render(history, { settings = make_settings(true) })
        assert.matches(out, '#q:', "inherited show_suggestions must trigger processing")
        local cold_history = make_history()
        local cold_answer = make_msg("assistant", "Frodo does.\n<suggestions>\n- Why him?\n</suggestions>\n")
        ASUtils.set_attr(cold_answer, "show_suggestions", false)
        table.insert(cold_history, cold_answer)
        local cold_out = render(cold_history, { settings = make_settings(true) })
        assert.notMatches(cold_out, '#q:', "explicit false must win over the fallback")
        assert.notMatches(cold_out, '<suggestions>', "the raw block must not reach the page")
        assert.matches(cold_out, 'Frodo does%.', "the answer body must survive")
    end),

    test("render: tool-payload user messages render empty, never crash", function()
        local history = { make_msg("system", "system prompt") }
        table.insert(history, { role = "user", content = { { type = "tool_result" } } })
        table.insert(history, { role = "user" })
        local answer_msg = make_msg("assistant", "Done.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = render(history)
        assert.equal(count_plain(out, '<div class="user-bubble'), 0,
            "tool-payload user messages must not render a junk bubble")
        assert.matches(out, 'Done%.', "the answer must still render")
    end),

    test("render: the minimalist switch produces the answer-only shape", function()
        local settings = {
            readSetting = function(dummy, key, def)
                if key == "minimalist_mode" then return true end
                if key == "auto_prompt_suggest" then return true end
                if key == "show_reasoning" then return true end
                return def
            end,
        }
        local history = make_history()
        ASUtils.set_attr(history[2], "prompt_title", "Book Summary")
        local answer_msg = make_msg("assistant",
            "```reasoning\nthinking here\n```\n\nFrodo carries the Ring.\n<suggestions>\n- Why him?\n</suggestions>\n")
        table.insert(history, answer_msg)
        local out = render(history, { settings = settings })
        assert.notMatches(out, '<div class="user%-bubble[^"]*">', "no bubble in minimalist mode")
        assert.notMatches(out, '<div class="thought%-block">', "no Thought block in minimalist mode")
        assert.notMatches(out, '#q:', "no follow-up suggestions in minimalist mode")
        assert.notMatches(out, 'Book Summary', "no prompt name in minimalist mode")
        assert.matches(out, 'Frodo carries the Ring', "the answer body must survive")
    end),

    test("feature follow-up: preserves the web-search selection", function()
        -- The renderer has no view of the dialog's checkboxes: the follow-up
        -- path forwards the value into the history it appends, so the wiring is
        -- read where it lives.
        assert.matches(feature_src, 'onSubmit = function%(viewer, user_question, use_websearch%)', "feature viewer must receive the search checkbox value")
        assert.matches(feature_src, 'prepareMessageHistoryForAdditionalQuestion%(message_history, user_question, use_websearch%)', "free follow-ups must forward the search value")
        assert.matches(feature_src, 'set_attr%(context, "use_websearch", use_websearch or false%)', "free follow-ups must tag the last user message")
        assert.matches(feature_src, 'set_attr%(followup_user, "use_websearch", user_question.use_websearch or false%)', "table follow-ups must tag the last user message")
    end),
}

return helper.runTests("feature_markdown.lua", tests)
