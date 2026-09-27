-- test_prompt_title.lua
-- Guards the prompt_title display-name tag on preset user messages:
--   * a tagged message heads its bubble with the name in single angle quotes
--     (‹ Name ›), marking it as an invoked function rather than typed text;
--     the full template text never reaches the viewer
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
local dict_src = read_source("assistant_dictdialog.lua")
local format_src = read_source("assistant_text_utils.lua")

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
        assert.equal(count_plain(feature_src, '"prompt_title"'), 2, "feature string follow-ups (free questions) must stay untagged")
        assert.equal(count_plain(dialog_src, '"prompt_title"'), 2, "dialog free questions must stay untagged")
        -- Dict and Term X-Ray are context, not user turns: they tag nothing, and
        -- the renderer skips them, so no bubble is drawn for either.
        assert.equal(count_plain(dict_src, '"prompt_title"'), 0, "dict must not tag a prompt name")
        assert.equal(count_plain(dict_src, '"is_context"'), 2, "both dict branches must be marked as context")
    end),

    test("tagged: the name is wrapped in angle quotes, outside _()", function()
        -- The quotes are U+2039/U+203A, verified glyphs (test/unicode_icons.lua).
        -- They mark the bubble as an invoked function, so they must stay glued
        -- to the name in the formatter, never inside a msgid.
        assert.matches(format_src, 'user%-bubble%-title">\226\128\185 %%1 \226\128\186%%2<',
            "the name must render as < name >, with a slot for the selection")
        assert.notMatches(format_src, '_%("‹', "the angle quotes must not enter a msgid")
    end),

    test("tagged: full template text never leaks, only the name shows", function()
        local settings = make_settings()
        local history = {
            { role = "system", content = "system" },
            { role = "user", content = TEMPLATE },
        }
        ASUtils.set_attr(history[2], "prompt_title", "Book Info")
        local out = TextUtils.formatSingleMessage(history, history[2], fmt_opts(2, settings, nil))
        assert.matches(out, '<div class="user%-bubble%-title">‹ Book Info ›</div>', "display name must render in angle quotes")
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
        local out = TextUtils.formatSingleMessage(history, history[2], fmt_opts(2, settings, "Some Book Title"))
        assert.matches(out, '<div class="user%-bubble%-title">‹ Recap ›</div>', "tag must win over the title param")
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
        local out = TextUtils.formatSingleMessage(history, history[2], fmt_opts(2, settings, nil))
        assert.matches(out, 'Why does the Ring corrupt its bearer%?', "free question text must render fully")
        local titled = TextUtils.formatSingleMessage(history, history[2], fmt_opts(2, settings, "Some Book Title"))
        assert.matches(titled, '<div class="user%-bubble%-title">‹ Some Book Title ›</div>', "title param path must keep working")
        assert.notMatches(titled, 'Why does the Ring', "titled path shows the title, as before")
    end),
    test("tagged: the selection follows the quotes, space separated", function()
        local settings = make_settings()
        local history = { { role = "system", content = "system" } }
        local msg = { role = "user", content = "TEMPLATE" }
        ASUtils.set_attr(msg, "prompt_title", "Translate")
        ASUtils.set_attr(msg, "user_input", "how do you say this")
        ASUtils.set_attr(msg, "highlight_text", "mount Doom")
        table.insert(history, msg)
        local out = TextUtils.formatSingleMessage(history, msg, fmt_opts(2, settings, nil))
        assert.matches(out, '<div class="user%-bubble%-title">‹ Translate › mount Doom</div>',
            "the selection must follow the quotes, separated by a space")
        assert.notMatches(out, '›:', "no colon may separate the quotes from the selection")
    end),

    test("no selection: the caption stops at the quotes", function()
        local settings = make_settings()
        local history = { { role = "system", content = "system" } }
        local msg = { role = "user", content = "TEMPLATE" }
        ASUtils.set_attr(msg, "prompt_title", "Book Info")
        table.insert(history, msg)
        local out = TextUtils.formatSingleMessage(history, msg, fmt_opts(2, settings, nil))
        assert.matches(out, '<div class="user%-bubble%-title">‹ Book Info ›</div>',
            "an absent selection must leave no trailing separator")
    end),

    test("caption: whitespace collapses and long selections are cut", function()
        assert.equal(TextUtils.caption_highlight("a\n\n  b\tc"), " a b c",
            "a multi-line selection must flatten onto one line")
        assert.equal(TextUtils.caption_highlight(""), "", "empty selection appends nothing")
        assert.equal(TextUtils.caption_highlight(nil), "", "missing selection appends nothing")
        assert.equal(TextUtils.caption_highlight("   \n  "), "", "whitespace-only appends nothing")
        -- The caption is the only display of a selection, so a full paragraph
        -- fits; only a runaway one is cut.
        local fits = TextUtils.caption_highlight(string.rep("a", 500))
        assert.notMatches(fits, '%.%.%.$', "a selection within the budget must not be cut")
        assert.equal(#fits, 501, "a 500-byte selection passes through whole")
        local long = TextUtils.caption_highlight(string.rep("a", 900))
        assert.isTrue(#long <= 501, "a runaway selection must be cut to the budget")
        assert.matches(long, '%.%.%.$', "a cut selection ends with an ellipsis")
        -- Cutting must not split a character. Note that a *valid* multi-byte
        -- character ends on a continuation byte, so "ends on 0x80-0xBF" is not
        -- the test; walk the string and check every sequence is well formed.
        local cjk = TextUtils.caption_highlight(string.rep("中", 200))
        local cut = cjk:sub(1, -4) -- drop the trailing ellipsis
        local PREFIX = 1 -- the caption's single ASCII space separator
        assert.equal(cjk:sub(1, PREFIX), " ", "the caption keeps its space separator")
        local i, bad = 1, nil
        while i <= #cut do
            local b = cut:byte(i)
            local len = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
            for k = i + 1, i + len - 1 do
                local cb = cut:byte(k)
                if not cb or cb < 0x80 or cb >= 0xC0 then bad = i; break end
            end
            if bad then break end
            i = i + len
        end
        assert.isTrue(bad == nil, "a cut selection must not split a UTF-8 character")
        assert.equal((#cut - PREFIX) % 3, 0, "the cut must hold whole 3-byte characters")
    end),

    test("the top highlight block and its feature flags are gone", function()
        local conv_src = read_source("assistant_conversation.lua")
        local css_src = read_source("assistant_css.lua")
        local sample_src = read_source("configuration.sample.lua")
        for name, src in pairs({ conv = conv_src, css = css_src, sample = sample_src }) do
            assert.notMatches(src, 'hide_highlighted_text', name .. " must not read hide_highlighted_text")
            assert.notMatches(src, 'hide_long_highlights', name .. " must not read hide_long_highlights")
            assert.notMatches(src, 'long_highlight_threshold', name .. " must not read long_highlight_threshold")
        end
        -- The renderer no longer takes the selection: the turn's bubble owns it.
        assert.notMatches(conv_src, 'opts%.highlighted_text', "render must not take a selection")
        assert.notMatches(conv_src, 'Highlighted text:', "the top block is gone")
        assert.notMatches(css_src, 'highlight%-block', "its styling is gone too")
    end),

    test("builders: the dialogs tag the turn with their selection", function()
        -- The feature dialogs work on the book's whole highlight/notes set,
        -- not one selection, so they carry no highlight_text on purpose. Dict
        -- and Term X-Ray are context turns the renderer skips, so they neither.
        assert.equal(count_plain(dialog_src, 'set_attr(_user, "highlight_text"'), 2,
            "dialog must tag both the preset-prompt and follow-up turns")
        assert.equal(count_plain(dict_src, '"highlight_text"'), 0,
            "dict must not tag a selection")
        assert.equal(count_plain(feature_src, '"highlight_text"'), 0,
            "feature dialogs must not claim a single selection")
    end),
}

return helper.runTests("prompt_title.lua", tests)
