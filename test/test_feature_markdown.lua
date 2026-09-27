-- test_feature_markdown.lua
-- Guards the feature dialog's sync to the div-carrier result shape:
--   * first round walks message_history (system/is_context skipped, header
--     once) through the shared assistant_text_utils pipeline, so
--     Search divs the querier appended in place actually render
--   * follow-ups append with the `---` separator through the shared
--     formatter (no `### ⮞` headings, no ad-hoc second suggestion pass)
--   * dialog and feature share one emitter: both require the module and
--     neither keeps a local formatSingleMessage fork
-- Headless-safe: the widget-heavy dialogs are never required here; the
-- pure formatter module loads under helper stubs and is exercised directly,
-- file shapes via source scan (the source-scan approach used across the
-- markdown test files).
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local TextUtils = require("assistant_text_utils")

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local dialog_src = read_source("assistant_dialog.lua")
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

local function make_msg(role, content)
    return { role = role, content = content }
end

local function make_history()
    return {
        make_msg("system", "system prompt"),
        make_msg("user", "Recap the story so far."),
    }
end

local function fmt_opts(history, idx, settings, default_config)
    return {
        title = nil,
        msg_idx = idx,
        settings = settings,
        default_config = default_config,
    }
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("shared emitter: dialog and feature require it, no local fork", function()
        assert.matches(dialog_src, 'require%("assistant_text_utils"%)', "dialog must require the shared module")
        assert.matches(feature_src, 'require%("assistant_text_utils"%)', "feature must require the shared module")
        assert.notMatches(dialog_src, 'local function formatSingleMessage', "dialog must not keep a local fork")
        assert.notMatches(feature_src, 'local function formatSingleMessage', "feature must not keep a local fork")
        assert.notMatches(feature_src, 'local function createResultText%(answer%)', "feature must not keep the answer-only renderer")
    end),

    test("feature follow-up: reuses existing context and passes the question through", function()
        assert.notMatches(feature_src, "I'm reading something titled", "feature follow-ups must not repeat the book context prefix")
        assert.notMatches(feature_src, "Only answer the following question", "feature follow-ups must not add a redundant instruction prefix")
        assert.matches(feature_src, 'content = user_question', "free follow-ups must pass the question through unchanged")
        assert.matches(feature_src, 'content = expanded_followup', "table follow-ups must pass the expanded prompt through unchanged")
        assert.notMatches(feature_src, 'user_question, title, author', "feature follow-up helpers must not accept redundant book metadata")
        assert.matches(dialog_src, "I'm reading something titled", "new-question context must retain its book metadata prefix")
    end),

    test("feature follow-up: preserves the web-search selection", function()
        assert.matches(feature_src, 'onSubmit = function%(viewer, user_question, use_websearch%)', "feature viewer must receive the search checkbox value")
        assert.matches(feature_src, 'prepareMessageHistoryForAdditionalQuestion%(message_history, user_question, use_websearch%)', "free follow-ups must forward the search value")
        assert.matches(feature_src, 'set_attr%(context, "use_websearch", use_websearch or false%)', "free follow-ups must tag the last user message")
        assert.matches(feature_src, 'set_attr%(followup_user, "use_websearch", user_question.use_websearch or false%)', "table follow-ups must tag the last user message")
    end),

    test("generic viewer: context follows the entry source", function()
        assert.matches(dialog_src, 'self:_showResultViewer%(highlightedText, message_history, viewer_title, true%)', "free-question viewers must keep follow-up context")
        assert.matches(dialog_src, 'self:_showResultViewer%(highlightedText, message_history, title, false%)', "built-in prompt viewers must not duplicate follow-up context")
    end),

    test("book identity rides inside the bubble, not above the transcript", function()
        -- The old shape was a markdown block prepended as the renderer's
        -- header; it now rides in the turn's bubble under the caption line.
        assert.matches(feature_src, 'set_attr%(context_message, "bubble_meta"', "meta must be tagged on the turn")
        assert.notMatches(feature_src, 'header = header_text', "the block header must be gone")
        assert.notMatches(feature_src, 'Reading progress: %%3%%', "the old block msgid must be gone")
        -- One template; only the labels are msgids, so each is a bare word that
        -- a target language can order as it likes. Plain find: a leading "-"
        -- would be read as a Lua pattern quantifier.
        for _, msgid in ipairs({ '"Title"', '"Author"', '"Reading progress"' }) do
            assert.isTrue(feature_src:find("_(" .. msgid .. ")", 1, true) ~= nil,
                "label must be its own msgid: " .. msgid)
        end
        assert.notMatches(feature_src, '_%(%- Title', "the label must not carry its punctuation")
        -- One <p> per line, no bullet prefix.
        assert.matches(feature_src, 'user%-bubble%-meta"><p><b>%%1</b>: %%2</p>',
            "each meta line must be a paragraph")
        assert.notMatches(feature_src, '<div>%- %%1', "no dash prefix on the meta lines")
        -- The percent must ride on the value: a bare "%" in a T template is a
        -- substitution escape, and "%%" would emit two of them.
        assert.isTrue(feature_src:find('formatted_progress_percent .. "%"', 1, true) ~= nil,
            "the percent sign must be appended to the value")

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

        local parts = {}
        for idx = 2, #history do
            if not ASUtils.get_attr(history[idx], "is_context") then
                table.insert(parts, TextUtils.formatSingleMessage(history, history[idx],
                    fmt_opts(history, idx, settings, { show_suggestions = false })))
            end
        end
        local out = table.concat(parts)
        local bubble = out:match('<div class="user%-bubble">(.-)</div>\n\n')
        assert.notNil(bubble, "a user bubble must be rendered")
        assert.matches(bubble, 'user%-bubble%-title">‹ Book Summary & Recs ›</div>',
            "the caption must come first")
        assert.isTrue(bubble:find('user%-bubble%-title') < bubble:find('user%-bubble%-meta'),
            "the meta must follow the caption line, not precede it")
        -- Plain find: a trailing "%" would be read as a dangling escape.
        assert.isTrue(bubble:find("<b>Reading progress</b>: 45%", 1, true) ~= nil,
            "the meta must carry the reading position")
        assert.notMatches(out, 'PROMPT TEMPLATE', "the prompt template must never reach the page")
    end),

    test("a turn without meta renders no meta block", function()
        local settings = make_settings(false)
        local ctx = make_msg("user", "Free question.")
        ASUtils.set_attr(ctx, "prompt_title", "Translate")
        local history = { make_msg("system", "system prompt"), ctx }
        local out = TextUtils.formatSingleMessage(history, ctx,
            fmt_opts(history, 2, settings, { show_suggestions = false }))
        assert.notMatches(out, 'user%-bubble%-meta', "no meta block without the attr")
    end),

    test("feature first round: history walk with header once, Search renders", function()
        local conv_src = read_source("assistant_conversation.lua")
        assert.matches(conv_src, 'for i = 2, #history do', "renderer must walk history from 2")
        assert.matches(conv_src, 'get_attr%(msg, "is_context"%)', "renderer must skip context messages")
        assert.notMatches(feature_src, '##### You may find', "feature must not pre-process suggestions itself")
        local settings = make_settings(true)
        local history = make_history()
        local search_msg = make_msg("assistant", "raw assistant turn")
        ASUtils.set_attr(search_msg, "search_keywords", "🌐 Frodo Baggins\n\n")
        table.insert(history, search_msg)
        local answer_msg = make_msg("assistant", "Frodo carries the Ring.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local parts = { "HEADER\n\n" }
        for idx = 2, #history do
            local message = history[idx]
            if not ASUtils.get_attr(message, "is_context") then
                table.insert(parts, TextUtils.formatSingleMessage(history, message, fmt_opts(history, idx, settings, { show_suggestions = false })))
            end
        end
        local out = table.concat(parts)
        assert.matches(out, '^HEADER', "header must lead once")
        assert.matches(out, '<div class="user%-bubble">', "user turn must render a bubble")
        assert.matches(out, '🌐 Frodo Baggins', "search keywords must render")
        assert.matches(out, 'Frodo carries the Ring', "answer body must survive")
        assert.notMatches(out, 'assistant%-label', "no carrier may survive")
        assert.notMatches(out, '### ', "no h3 container headings may appear")
    end),

    test("feature follow-up: --- separator, no old h3, single suggestion pass", function()
        local conv_src = read_source("assistant_conversation.lua")
        assert.matches(conv_src, '"%-%-%-\\n\\n"', "follow-up must join with ---")
        assert.notMatches(feature_src, '### ⮞', "old ### User/Assistant headings must be gone")
        assert.notMatches(feature_src, 'process_suggestions%(answer%)', "ad-hoc second suggestion pass must be gone")
        local settings = make_settings(true)
        local history = make_history()
        local followup = make_msg("user", "Who carries it?")
        ASUtils.set_attr(followup, "show_suggestions", true)
        table.insert(history, followup)
        local answer_msg = make_msg("assistant", "Frodo does.\n<suggestions>\n- Why him?\n</suggestions>\n")
        ASUtils.set_attr(answer_msg, "show_suggestions", true)
        table.insert(history, answer_msg)
        local out = "---\n\n"
            .. TextUtils.formatSingleMessage(history, history[#history - 1], fmt_opts(history, #history - 1, settings, { show_suggestions = true }))
            .. TextUtils.formatSingleMessage(history, history[#history], fmt_opts(history, #history, settings, { show_suggestions = true }))
        assert.matches(out, '^%-%-%-\n\n<div', "follow-up must start with the --- separator")
        assert.matches(out, '#q:', "suggestions must be processed exactly once by the pipeline")
        assert.notMatches(out, '<suggestions>', "suggestion tags must be consumed")
        assert.notMatches(out, '### ⮞', "no old headings in follow-up output")
    end),

    test("pipeline: the Reasoning Text switch decides the Thought div", function()
        local history = make_history()
        local answer_msg = make_msg("assistant", "```reasoning\nthinking here\n```\n\nThe Ring rules them all.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        -- Switch on: the stored fence becomes a Thought block above the answer.
        local on = make_settings(false, true)
        local out = TextUtils.formatSingleMessage(history, answer_msg, fmt_opts(history, 3, on, { show_suggestions = false }))
        assert.matches(out, '<div class="thought%-block">', "Thought block missing")
        assert.matches(out, 'thinking here', "reasoning body must be kept")
        assert.matches(out, 'The Ring rules them all', "answer body must survive")
        -- Switch off: a turn answered while it was on still carries its fence,
        -- and must not resurrect the thinking once the switch is off.
        local off = make_settings(false, false)
        local hidden = TextUtils.formatSingleMessage(history, answer_msg, fmt_opts(history, 3, off, { show_suggestions = false }))
        assert.notMatches(hidden, 'thought%-block', "no Thought block while the switch is off")
        assert.notMatches(hidden, '```reasoning', "no fence while the switch is off")
        assert.matches(hidden, 'The Ring rules them all', "answer body must survive")
    end),

    test("pipeline: suggestion inheritance follows dialog rules", function()
        local settings = make_settings(true)
        local history = make_history()
        ASUtils.set_attr(history[2], "show_suggestions", true)
        local answer_msg = make_msg("assistant", "Frodo does.\n<suggestions>\n- Why him?\n</suggestions>\n")
        table.insert(history, answer_msg)
        local out = TextUtils.formatSingleMessage(history, answer_msg, fmt_opts(history, 3, settings, { show_suggestions = false }))
        assert.matches(out, '#q:', "inherited show_suggestions must trigger processing")
        local cold_settings = make_settings(true)
        local cold_history = make_history()
        local cold_answer = make_msg("assistant", "Frodo does.\n<suggestions>\n- Why him?\n</suggestions>\n")
        ASUtils.set_attr(cold_answer, "show_suggestions", false)
        table.insert(cold_history, cold_answer)
        local cold_out = TextUtils.formatSingleMessage(cold_history, cold_answer, fmt_opts(cold_history, 3, cold_settings, { show_suggestions = false }))
        assert.notMatches(cold_out, '#q:', "explicit false must win over the fallback")
        assert.notMatches(cold_out, '<suggestions>', "the raw block must not reach the page")
        assert.matches(cold_out, 'Frodo does%.', "the answer body must survive")
    end),

    test("pipeline: tool-payload user messages render empty, never crash", function()
        local settings = make_settings(false)
        local history = make_history()
        local tool_user = { role = "user", content = { { type = "tool_result" } } }
        table.insert(history, tool_user)
        local out = TextUtils.formatSingleMessage(history, tool_user, fmt_opts(history, 3, settings, { show_suggestions = false }))
        assert.equal(out, "", "table content must not render a junk Question div")
        local parts_user = { role = "user" }
        table.insert(history, parts_user)
        local parts_out = TextUtils.formatSingleMessage(history, parts_user, fmt_opts(history, 4, settings, { show_suggestions = false }))
        assert.equal(parts_out, "", "content-free tool message must render empty")
    end),
}

return helper.runTests("feature_markdown.lua", tests)
