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
local T = require("ffi/util").template

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local dict_src = read_source("assistant_dictdialog.lua")

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
    test("excerpt: book text is escaped, not eaten as markup", function()
        -- A raw HTML block is passed through verbatim, so unescaped "<" in the
        -- surrounding sentence would be swallowed as a tag.
        local history = {
            make_msg("system", "system prompt"),
            make_msg("user", "Define the word."),
        }
        local koutil = require("util")
        local header = T('<div class="dict-excerpt">... %1 <b>%2</b> %3 ...</div>\n\n',
            koutil.htmlEscape("he said <b>no</b> & left"),
            koutil.htmlEscape("word"),
            koutil.htmlEscape("then >stopped<"))
        local out = build_result(history, header, make_settings(false), NO_SUGGEST)
        assert.matches(out, '&lt;b&gt;no&lt;', "angle brackets in the book text must be escaped")
        assert.matches(out, '&amp; left', "ampersands in the book text must be escaped")
        assert.matches(out, 'then &gt;stopped&lt;', "the trailing context must be escaped too")
        assert.matches(out, '<b>word</b>', "the word itself stays bold")
        -- The escape is what protects it: without it the renderer eats the tag.
        assert.notMatches(out, '<b>no', "raw book text must not become real markup")
    end),

    test("shared emitter: dict requires it, header msgid intact, no fork", function()
        assert.matches(dict_src, 'require%("assistant_text_utils"%)', "dict must require the shared module")
        assert.notMatches(dict_src, '<div class="user%-bubble">', "dict must not copy div templates")
        assert.notMatches(dict_src, 'local function formatSingleMessage', "dict must not keep a local fork")
        -- Header no longer carries %4; history is rendered by the shared Renderer.
        assert.isTrue(dict_src:find('T(\'<div class="dict-excerpt">', 1, true) ~= nil,
            "excerpt header must stay a styled div")
        assert.matches(dict_src, 'koutil%.htmlEscape%(prev_context_limited%)',
            "the surrounding text must be escaped")
        assert.matches(dict_src, 'koutil%.htmlEscape%(koutil%.cleanupSelectedText',
            "the word must be escaped")
        assert.matches(dict_src, 'Conversation%.Renderer%.render', "dict must use the shared renderer")
        local conv_src = read_source("assistant_conversation.lua")
        assert.matches(conv_src, 'for i = 2, #history do', "renderer must walk history from 2")
        assert.matches(conv_src, 'get_attr%(msg, "is_context"%)', "renderer must skip context messages")
        assert.matches(dict_src, 'Conversation%.append_answer%(message_history, ret', "answer must be appended to history")
        assert.matches(dict_src, 'Conversation%.append_answer%(message_history, ret,%s*Prompts%.isSuggestionsEnabled%(assistant.settings, prompt_config%)', "answer must pin this prompt's switch")
        assert.notMatches(dict_src, 'process_suggestions', "no ad-hoc suggestion pass may remain")
    end),

    test("render: excerpt header, then the answer, with no user bubble", function()
        local settings = make_settings(true)
        local ctx = make_msg("user", "Defineories: the word in context.")
        ASUtils.set_attr(ctx, "is_context", true) -- as the dict dialog marks it
        local history = { make_msg("system", "system prompt"), ctx }
        local search_msg = make_msg("assistant", "raw assistant turn")
        ASUtils.set_attr(search_msg, "search_keywords", "🌐 xray term context\n\n")
        table.insert(history, search_msg)
        local answer_msg = make_msg("assistant", "The term names a ship.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = build_result(history, '<div class="dict-excerpt">... prev <b>word</b> next ...</div>\n\n', settings, NO_SUGGEST)
        assert.matches(out, '^<div class="dict%-excerpt">%.%.%. prev <b>word</b> next %.%.%.</div>',
            "excerpt header must lead once, as a styled div")
        assert.matches(out, '🌐 xray term context', "search keywords must render")
        assert.matches(out, 'The term names a ship', "answer body must survive")
        assert.notMatches(out, '<div class="user%-bubble">', "dict must not draw a user bubble")
        assert.notMatches(out, 'assistant%-label', "no carrier may survive")
        assert.notMatches(out, '### ⮞', "no old container headings may appear")
    end),

    test("the dict turn is context, so the renderer skips it", function()
        -- The user never typed it: the excerpt header carries the word instead.
        local settings = make_settings(false)
        local history = { make_msg("system", "system prompt") }
        local ctx = make_msg("user", "PROMPT TEMPLATE THAT MUST NOT LEAK")
        ASUtils.set_attr(ctx, "is_context", true)
        table.insert(history, ctx)
        local answer_msg = make_msg("assistant", "The term names a ship.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = build_result(history, "<div class=\"dict-excerpt\">... <b>word</b> ...</div>\n\n",
            settings, NO_SUGGEST)
        assert.notMatches(out, 'PROMPT TEMPLATE', "the prompt template must never reach the page")
        assert.matches(out, 'The term names a ship', "the answer still renders")
        -- Both prompt branches must be marked, or one of them leaks a bubble.
        assert.equal(count_plain(dict_src, 'set_attr(context_message, "is_context"'), 2,
            "both dict and term_xray turns must be marked as context")
        assert.notMatches(dict_src, '"prompt_title"', "dict must no longer tag a prompt name")
        assert.notMatches(dict_src, '"highlight_text"', "dict must no longer tag a selection")
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
        assert.notMatches(out, '<suggestions>', "the raw block must not reach the page")
        assert.matches(out, 'A word%.', "the answer body must survive")
    end),

    test("pipeline: the Reasoning Text switch decides the Thought div", function()
        local history = {
            make_msg("system", "system prompt"),
            make_msg("user", "Define the word."),
        }
        local answer_msg = make_msg("assistant", "```reasoning\nthinking here\n```\n\nThe term names a ship.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        -- Switch on: the stored fence becomes a Thought block above the answer.
        local on = build_result(history, "... prev **word** next ...\n\n", make_settings(false, true), NO_SUGGEST)
        assert.matches(on, '<div class="thought%-block">', "Thought block missing")
        assert.matches(on, 'thinking here', "reasoning body must be kept")
        assert.matches(on, 'The term names a ship', "answer body must survive")
        -- Switch off: a turn answered while it was on still carries its fence,
        -- and must not resurrect the thinking once the switch is off.
        local off_settings = make_settings(false, false)
        local off = build_result(history, "... prev **word** next ...\n\n", off_settings, NO_SUGGEST)
        assert.notMatches(off, 'thought%-block', "no Thought block while the switch is off")
        assert.notMatches(off, '```reasoning', "no fence while the switch is off")
        assert.matches(off, '%.%.%. prev %*%*word%*%* next %.%.%.', "excerpt header must survive")
        assert.matches(off, 'The term names a ship', "answer body must survive")
    end),
}

return helper.runTests("dict_markdown.lua", tests)
