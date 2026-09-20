-- test_dict_markdown.lua
-- Guards the dictionary/term_xray result shape:
--   * the excerpt header (`... %1 **%2** %3 ...`) is emitted once, then the
--     history past the system prompt renders through
--     assistant_text_utils (Search/Thought/Response divs)
--   * the answer is appended to the history with this prompt's suggestion
--     switch pinned, so no ad-hoc suggestion pass exists (both dict and
--     term_xray configs keep suggestions off)
--   * no div template is copied into the dialog; no old container headings
-- Headless-safe: the widget-heavy dialog is never required here; the pure
-- formatter module loads under helper stubs and is exercised directly,
-- file shapes via source scan.
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

local dict_src = read_source("assistant_dictdialog.lua")

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

local function fmt_opts(history, idx, settings, default_config)
    return {
        title = nil,
        msg_idx = idx,
        settings = settings,
        default_config = default_config,
    }
end

-- Dict/term_xray prompt configs both keep suggestions off.
local NO_SUGGEST = { show_suggestions = false }

-- Strip helper for the viewer pipeline: titled div block first, then the
-- bare fence the querier stores; think-tag handling is the real
-- TextUtils.strip_think_tags (assistant_utils.lua, single source of truth).
local function strip_reasoning(text)
    text = text:gsub('<div class="assistant%-label[^"]*">[^\n]*</div>%s*```reasoning%s*[%s%S]-%s*```%s*%-%-%-%s*', "")
    text = text:gsub('<div class="assistant%-label[^"]*">[^\n]*</div>%s*```reasoning%s*[%s%S]-%s*```%s*', "")
    text = text:gsub("```reasoning%s*[%s%S]-%s*```%s*", "")
    return TextUtils.strip_think_tags(text, nil, false)
end

-- Header-plus-history assembly exercised by the tests below; the
-- widget-heavy dialog is never required headlessly.
local function build_result(history, excerpt, settings, default_config)
    local parts = { excerpt }
    for idx = 2, #history do
        local message = history[idx]
        if not ASUtils.get_attr(message, "is_context") then
            table.insert(parts, TextUtils.formatSingleMessage(history, message, fmt_opts(history, idx, settings, default_config)))
        end
    end
    return table.concat(parts)
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("shared emitter: dict requires it, header msgid intact, no fork", function()
        assert.matches(dict_src, 'require%("assistant_text_utils"%)', "dict must require the shared module")
        assert.notMatches(dict_src, '<div class="assistant%-label">%%1', "dict must not copy div templates")
        assert.notMatches(dict_src, 'local function formatSingleMessage', "dict must not keep a local fork")
        assert.matches(dict_src, '%.%.%. %%1 %*%*%%2%*%* %%3 %.%.%.\\n\\n%%4', "excerpt header msgid must stay intact")
        assert.matches(dict_src, 'for idx = 2, #message_history do', "result must walk history from 2")
        assert.matches(dict_src, 'get_attr%(message, "is_context"%)', "result must skip context messages")
        assert.matches(dict_src, 'table.insert%(message_history, assistant_msg%)', "answer must be appended to history")
        assert.matches(dict_src, 'show_suggestions", Prompts.isSuggestionsEnabled%(assistant.settings, prompt_config%)', "answer must pin this prompt's switch")
        assert.notMatches(dict_src, 'process_suggestions', "no ad-hoc suggestion pass may remain")
    end),

    test("render: excerpt header plus Question/Search/Response divs", function()
        local settings = make_settings(true)
        local history = {
            make_msg("system", "system prompt"),
            make_msg("user", "Defineories: the word in context."),
        }
        local search_msg = make_msg("assistant", "raw assistant turn")
        ASUtils.set_attr(search_msg, "search_keywords", "⌗ xray term context\n\n")
        table.insert(history, search_msg)
        local answer_msg = make_msg("assistant", "The term names a ship.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = build_result(history, "... prev **word** next ...\n\n", settings, NO_SUGGEST)
        assert.matches(out, '^%.%.%. prev %*%*word%*%* next %.%.%.', "excerpt header must lead once")
        assert.matches(out, 'assistant%-label">☺ Question</div>', "user turn must render a Question div")
        assert.matches(out, 'assistant%-label">✦ Search</div>', "tool turn must render a Search div")
        assert.matches(out, '⌗ xray term context', "search keywords must render")
        assert.matches(out, 'assistant%-label">✦ Response</div>', "answer must render a Response div")
        assert.matches(out, 'The term names a ship', "answer body must survive")
        assert.notMatches(out, '### ⮞', "no old container headings may appear")
    end),

    test("suggestions stay off under dict/term_xray configs", function()
        local settings = make_settings(true)
        local history = {
            make_msg("system", "system prompt"),
            make_msg("user", "Define the word."),
        }
        local answer_msg = make_msg("assistant", "A word.\n<suggestions>\n- Follow up?\n</suggestions>\n")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = build_result(history, "... prev **word** next ...\n\n", settings, NO_SUGGEST)
        assert.notMatches(out, '#q:', "no suggestion links when the prompt keeps them off")
        assert.matches(out, '<suggestions>', "untouched tags must stay when disabled")
    end),

    test("pipeline: reasoning splits into Thought div, strip restores body", function()
        local settings = make_settings(false)
        local history = {
            make_msg("system", "system prompt"),
            make_msg("user", "Define the word."),
        }
        local answer_msg = make_msg("assistant", "```reasoning\nthinking here\n```\n\nThe term names a ship.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = build_result(history, "... prev **word** next ...\n\n", settings, NO_SUGGEST)
        assert.matches(out, 'assistant%-label%-%-thought">※ Deeply Thought</div>', "Thought div missing")
        assert.matches(out, '```reasoning\nthinking here\n```', "reasoning fence must be kept pre-strip")
        local stripped = strip_reasoning(out)
        assert.notMatches(stripped, '```reasoning', "reasoning fence must be stripped")
        assert.notMatches(stripped, 'assistant%-label%-%-thought', "thought label must be stripped")
        assert.matches(stripped, 'The term names a ship', "answer body must survive the strip")
        assert.matches(stripped, '%.%.%. prev %*%*word%*%* next %.%.%.', "excerpt header must survive the strip")
    end),
}

return helper.runTests("dict_markdown.lua", tests)
