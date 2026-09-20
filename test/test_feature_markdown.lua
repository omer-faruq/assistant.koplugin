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

local function make_settings(suggest_on)
    return {
        readSetting = function(dummy, key, def)
            if key == "auto_prompt_suggest" then return suggest_on end
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

-- Strip helper for the viewer pipeline: titled div block first, then the
-- bare fence the querier stores; think-tag handling is the real
-- TextUtils.strip_think_tags (assistant_utils.lua, single source of truth).
local function strip_reasoning(text)
    text = text:gsub('<div class="assistant%-label[^"]*">[^\n]*</div>%s*```reasoning%s*[%s%S]-%s*```%s*%-%-%-%s*', "")
    text = text:gsub("```reasoning%s*[%s%S]-%s*```%s*", "")
    return TextUtils.strip_think_tags(text, nil, false)
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

    test("feature first round: history walk with header once, Search renders", function()
        assert.matches(feature_src, 'for idx = 2, #message_history do', "first round must walk history from 2")
        assert.matches(feature_src, 'get_attr%(message, "is_context"%)', "first round must skip context messages")
        assert.notMatches(feature_src, '##### You may find', "feature must not pre-process suggestions itself")
        local settings = make_settings(true)
        local history = make_history()
        local search_msg = make_msg("assistant", "raw assistant turn")
        ASUtils.set_attr(search_msg, "search_keywords", "⌗ Frodo Baggins\n\n")
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
        assert.matches(out, 'assistant%-label">☺ Question</div>', "user turn must render a Question div")
        assert.matches(out, 'assistant%-label">✦ Search</div>', "tool turn must render a Search div")
        assert.matches(out, '⌗ Frodo Baggins', "search keywords must render")
        assert.matches(out, 'assistant%-label">✦ Response</div>', "answer must render a Response div")
        assert.matches(out, 'Frodo carries the Ring', "answer body must survive")
        assert.notMatches(out, '### ', "no h3 container headings may appear")
    end),

    test("feature follow-up: --- separator, no old h3, single suggestion pass", function()
        assert.matches(feature_src, '"%-%-%-\\n\\n"%s*%.%.', "follow-up must join with ---")
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

    test("pipeline: reasoning splits into Thought div, strip restores body", function()
        local settings = make_settings(false)
        local history = make_history()
        local answer_msg = make_msg("assistant", "```reasoning\nthinking here\n```\n\nThe Ring rules them all.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = TextUtils.formatSingleMessage(history, answer_msg, fmt_opts(history, 3, settings, { show_suggestions = false }))
        assert.matches(out, 'assistant%-label%-%-thought">※ Deeply Thought</div>', "Thought div missing")
        assert.matches(out, '```reasoning\nthinking here\n```', "reasoning fence must be kept pre-strip")
        assert.matches(out, 'assistant%-label">✦ Response</div>', "Response div missing")
        local stripped = strip_reasoning(out)
        assert.notMatches(stripped, '```reasoning', "reasoning fence must be stripped")
        assert.notMatches(stripped, 'assistant%-label%-%-thought', "thought label must be stripped")
        assert.matches(stripped, 'The Ring rules them all', "answer body must survive the strip")
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
        assert.matches(cold_out, '<suggestions>', "untouched tags must stay when disabled")
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
