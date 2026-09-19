-- test_prompt_title.lua
-- Guards the prompt_title display-name tag on preset user messages:
--   * a tagged message renders only the name line; the full template
--     text never reaches the viewer
--   * free questions carry no tag and keep the existing rendering (title
--     param, otherwise full content)
--   * the tag wins over the title param when both are present
--   * every preset user-message builder tags its message; free-question
--     builders set no tag
-- Headless-safe: the widget-heavy dialogs are never required here; the pure
-- formatter module loads under helper stubs and is exercised directly,
-- builder shapes via source scan.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local MsgFormat = require("assistant_message_format")

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
local dict_src = read_source("assistant_dictdialog.lua")
local format_src = read_source("assistant_message_format.lua")

local function make_settings()
    return {
        readSetting = function(dummy, key, def)
            return def
        end,
    }
end

local function fmt_opts(idx, settings, title)
    return {
        title = title,
        msg_idx = idx,
        settings = settings,
        default_config = { show_suggestions = false },
    }
end

local function count_plain(text, needle)
    local n = 0
    local init = 1
    while true do
        local hit = text:find(needle, init, true)
        if not hit then break end
        n = n + 1
        init = hit + 1
    end
    return n
end

local TEMPLATE = "You are a meticulous book summarizer. INPUTS: the full book text up to 45.20 percent. TASK: produce key points now."

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("builders: every preset user message is tagged, free ones are not", function()
        assert.matches(format_src, 'get_attr%(message, "prompt_title"%)', "formatter must read the tag")
        assert.equal(count_plain(dialog_src, 'set_attr(_user, "prompt_title"'), 2, "dialog must tag runPrompt and table-prompt messages")
        assert.matches(feature_src, 'set_attr%(context_message, "prompt_title", feature_title%)', "feature must tag its first-round message")
        assert.matches(feature_src, 'set_attr%(followup_user, "prompt_title", viewer_title%)', "feature must tag table follow-ups")
        assert.equal(count_plain(dict_src, 'set_attr(context_message, "prompt_title", title)'), 2, "dict must tag both prompt branches")
        assert.equal(count_plain(feature_src, '"prompt_title"'), 2, "feature string follow-ups (free questions) must stay untagged")
        assert.equal(count_plain(dialog_src, '"prompt_title"'), 2, "dialog free questions must stay untagged")
    end),

    test("tagged: full template text never leaks, only the name shows", function()
        local settings = make_settings()
        local history = {
            { role = "system", content = "system" },
            { role = "user", content = TEMPLATE },
        }
        ASUtils.set_attr(history[2], "prompt_title", "Book Info")
        local out = MsgFormat.formatSingleMessage(history, history[2], fmt_opts(2, settings, nil))
        assert.matches(out, '➤ ‹ Book Info ›', "display name must render")
        assert.notMatches(out, 'meticulous book summarizer', "template body must not leak")
        assert.notMatches(out, '45%.20', "template details must not leak")
    end),

    test("tagged: user_input still appends, title param loses to the tag", function()
        local settings = make_settings()
        local history = {
            { role = "system", content = "system" },
            { role = "user", content = TEMPLATE },
        }
        ASUtils.set_attr(history[2], "user_input", "focus on chapter 3")
        ASUtils.set_attr(history[2], "prompt_title", "Recap")
        local out = MsgFormat.formatSingleMessage(history, history[2], fmt_opts(2, settings, "Some Book Title"))
        assert.matches(out, '➤ ‹ Recap ›', "tag must win over the title param")
        assert.notMatches(out, 'Some Book Title', "title param must not render when tagged")
        assert.matches(out, 'focus on chapter 3', "user_input must still append")
        assert.notMatches(out, 'meticulous book summarizer', "template body must not leak")
    end),

    test("untagged: free questions keep full content rendering", function()
        local settings = make_settings()
        local history = {
            { role = "system", content = "system" },
            { role = "user", content = "Why does the Ring corrupt its bearer?" },
        }
        local out = MsgFormat.formatSingleMessage(history, history[2], fmt_opts(2, settings, nil))
        assert.matches(out, 'Why does the Ring corrupt its bearer%?', "free question text must render fully")
        local titled = MsgFormat.formatSingleMessage(history, history[2], fmt_opts(2, settings, "Some Book Title"))
        assert.matches(titled, '➤ ‹ Some Book Title ›', "title param path must keep working")
        assert.notMatches(titled, 'Why does the Ring', "titled path shows the title line, as before")
    end),
}

return helper.runTests("prompt_title.lua", tests)
