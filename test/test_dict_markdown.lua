-- test_dict_markdown.lua
-- The dictionary / term-xray result shape, driven through the shipped
-- renderer: Conversation.Renderer.render, which walks the history from index 2
-- and skips the turns the dialog marked as context.
--
-- The widget-heavy dialog is never required here, so the one property that
-- lives in the dialog's own branches (both the plain and the term_xray turn
-- must be tagged as context) is read where it lives.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local Conversation = require("assistant_conversation")
local T = require("ffi/util").template
local koutil = require("util")

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

-- Dict/term_xray prompt configs both keep suggestions off.
local NO_SUGGEST = { show_suggestions = false }

local function render(history, header, settings)
    return Conversation.Renderer.render(history, {
        header = header,
        title = nil,
        settings = settings or make_settings(false),
        default_config = NO_SUGGEST,
    })
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
    test("excerpt: book text is escaped, not eaten as markup", function()
        -- A raw HTML block is passed through verbatim, so unescaped "<" in the
        -- surrounding sentence would be swallowed as a tag.
        local history = {
            make_msg("system", "system prompt"),
            make_msg("user", "Define the word."),
        }
        local header = T('<div class="dict-excerpt">... %1 <b>%2</b> %3 ...</div>\n\n',
            koutil.htmlEscape("he said <b>no</b> & left"),
            koutil.htmlEscape("word"),
            koutil.htmlEscape("then >stopped<"))
        local out = render(history, header)
        assert.matches(out, '&lt;b&gt;no&lt;', "angle brackets in the book text must be escaped")
        assert.matches(out, '&amp; left', "ampersands in the book text must be escaped")
        assert.matches(out, 'then &gt;stopped&lt;', "the trailing context must be escaped too")
        assert.matches(out, '<b>word</b>', "the word itself stays bold")
        -- The escape is what protects it: without it the renderer eats the tag.
        assert.notMatches(out, '<b>no', "raw book text must not become real markup")
    end),

    test("excerpt: the header leads once, then the history, with no user bubble", function()
        local settings = make_settings(true)
        local history = { make_msg("system", "system prompt") }
        local ctx = make_msg("user", "Defineories: the word in context.")
        ASUtils.set_attr(ctx, "is_context", true) -- as the dict dialog marks it
        table.insert(history, ctx)
        local search_msg = make_msg("assistant", "raw assistant turn")
        ASUtils.set_attr(search_msg, "search_keywords", "\u{1F310} xray term context\n\n")
        table.insert(history, search_msg)
        local answer_msg = make_msg("assistant", "The term names a ship.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = render(history, '<div class="dict-excerpt">... prev <b>word</b> next ...</div>\n\n', settings)
        assert.matches(out, '^<div class="dict%-excerpt">%.%.%. prev <b>word</b> next %.%.%.</div>',
            "the excerpt header must lead once, as a styled div")
        assert.matches(out, '\u{1F310} xray term context', "search keywords must render")
        assert.matches(out, 'The term names a ship', "answer body must survive")
        assert.notMatches(out, '<div class="user%-bubble">', "dict must not draw a user bubble")
        assert.notMatches(out, '### ⮞', "no old container headings may appear")
    end),

    test("the dict turn is context, so the renderer skips it", function()
        -- The user never typed it: the excerpt header carries the word instead.
        local history = { make_msg("system", "system prompt") }
        local ctx = make_msg("user", "PROMPT TEMPLATE THAT MUST NOT LEAK")
        ASUtils.set_attr(ctx, "is_context", true)
        table.insert(history, ctx)
        local answer_msg = make_msg("assistant", "The term names a ship.")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = render(history, '<div class="dict-excerpt">... <b>word</b> ...</div>\n\n')
        assert.notMatches(out, 'PROMPT TEMPLATE', "the prompt template must never reach the page")
        assert.equal(count_plain(out, '<div class="user-bubble">'), 0,
            "a context turn must not draw a bubble")
        assert.matches(out, 'The term names a ship', "the answer still renders")
        -- Without the tag the renderer would walk straight into the prompt
        -- template, so the same history with the tag removed is the control.
        local untagged = { make_msg("system", "system prompt"),
            make_msg("user", "PROMPT TEMPLATE THAT MUST NOT LEAK"), answer_msg }
        assert.matches(render(untagged, '<div class="dict-excerpt">x</div>\n\n'), 'PROMPT TEMPLATE',
            "an untagged prompt turn would leak, which is what the tag prevents")
    end),

    test("dialog: both prompt branches tag the turn as context", function()
        -- Plain dictionary and term_xray build the turn in two separate
        -- branches; missing the tag in either one leaks the prompt template.
        assert.equal(count_plain(dict_src, 'set_attr(context_message, "is_context"'), 2,
            "both dict and term_xray turns must be marked as context")
    end),

    test("suggestions stay off under dict/term_xray configs", function()
        local history = {
            make_msg("system", "system prompt"),
            make_msg("user", "Define the word."),
        }
        local answer_msg = make_msg("assistant", "A word.\n<suggestions>\n- Follow up?\n</suggestions>\n")
        ASUtils.set_attr(answer_msg, "show_suggestions", false)
        table.insert(history, answer_msg)
        local out = render(history, "... prev **word** next ...\n\n", make_settings(true))
        assert.notMatches(out, '#q:', "no suggestion links when the prompt keeps them off")
        assert.notMatches(out, '<suggestions>', "the raw block must not reach the page")
        assert.matches(out, 'A word%.', "the answer body must survive")
    end),
}

return helper.runTests("dict_markdown.lua", tests)
