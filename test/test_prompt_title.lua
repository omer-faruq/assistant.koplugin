-- test_prompt_title.lua
-- Guards the prompt_title display-name tag on preset user messages:
--   * a tagged message heads its bubble with the name in single angle quotes
--     (‹ Name ›), marking it as an invoked function rather than typed text;
--     the full template text never reaches the viewer
--   * free questions carry no tag and keep the existing rendering (title
--     param, otherwise full content)
--   * the tag wins over the title param when both are present, and the
--     selected text follows the quotes, space separated
-- Headless-safe: the pure formatter module loads under helper stubs and is
-- exercised directly; the widget-heavy dialogs that tag the turns are never
-- required here.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local TextUtils = require("assistant_text_utils")

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

local TEMPLATE = "You are a meticulous book summarizer. INPUTS: the full book text up to 45.20 percent. TASK: produce key points now."

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
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
}

return helper.runTests("prompt_title.lua", tests)
