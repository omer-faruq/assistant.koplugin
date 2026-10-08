-- test_bubble_width.lua
-- Guards the user-bubble width class: the class is the bubble's share of the
-- page (assistant_css fills whatever margin-left leaves), and the formatter
-- picks it from the turn's display length. An action label alone hugs the
-- right edge (tiny-text), a question of a few chat lines keeps the chat shape
-- (short-text), and only a genuinely long turn takes the page (long-text).
-- Every threshold is paired with a perturbation of the same turn that flips
-- the class.
-- Headless-safe: the pure formatter module loads under helper stubs and is
-- exercised directly.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local TextUtils = require("assistant_text_utils")

local function fmt_opts(idx)
    return {
        title = nil,
        msg_idx = idx,
        settings = {
            readSetting = function(dummy, key, def)
                return def
            end,
        },
        default_config = { show_suggestions = false },
    }
end

-- A preset turn: the prompt name heads the bubble, user_input is the body.
local function preset_turn(title, body)
    local history = {
        { role = "system", content = "system" },
        { role = "user", content = "TEMPLATE THAT MUST NOT LEAK" },
    }
    ASUtils.set_attr(history[2], "prompt_title", title)
    ASUtils.set_attr(history[2], "user_input", body)
    return history
end

local function free_turn(body)
    return {
        { role = "system", content = "system" },
        { role = "user", content = body },
    }
end

local function class_of(history)
    local out = TextUtils.formatSingleMessage(history, history[2], fmt_opts(2))
    return out:match('<div class="user%-bubble ([%w%-]+)">')
end

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Body filler sized in display units: "word " is five.
local function latin_units(n)
    return (string.rep("word ", math.ceil(n / 5))):sub(1, n)
end

local tests = {
    test("an action label alone hugs the right edge", function()
        assert.equal(class_of(preset_turn("Book Info", "")), "tiny-text",
            "a prompt name with no question is a label")
        -- Perturbation: the same turn with a question under the label is a
        -- turn, not a label.
        assert.equal(class_of(preset_turn("Book Info", "summarize chapter 3")), "short-text",
            "a body under the label lifts the bubble to the chat shape")
    end),

    test("a keyword query keeps the chat shape", function()
        -- The web-search features turn a keyword query into the user body; a
        -- handful of keywords must not take the page.
        assert.equal(class_of(preset_turn("Book Information",
            "Tokyo Ink Ann Vremont book author publisher plot genre")), "short-text",
            "a keyword query is a chat-length turn")
        -- Perturbation: the same query repeated is a long turn.
        assert.equal(class_of(preset_turn("Book Information",
            string.rep("Tokyo Ink Ann Vremont book author publisher plot genre ", 3))),
            "long-text", "a tripled query takes the page")
    end),

    test("a question of a few chat lines keeps the chat shape", function()
        assert.equal(class_of(free_turn(latin_units(85))), "short-text",
            "three chat lines are still chat shape")
        -- Perturbation: past the threshold the turn takes the page.
        assert.equal(class_of(free_turn(latin_units(110))), "long-text",
            "four lines and more take the page")
    end),

    test("full-width glyphs cost two display units", function()
        -- 55 CJK glyphs are as wide as 110 Latin ones and must land on the
        -- same side of the threshold.
        assert.equal(class_of(free_turn(string.rep("墨", 55))), "long-text",
            "a long CJK turn takes the page")
        assert.equal(class_of(free_turn(latin_units(55))), "short-text",
            "the same count of Latin glyphs is a chat-length turn")
    end),

    test("the title/author meta block is a chat card", function()
        local meta = '<div class="user-bubble-meta"><p><b>Title</b>: The Lord of the Rings</p>'
            .. '<p><b>Author</b>: J.R.R. Tolkien</p><p><b>Reading progress</b>: 45%</p></div>\n'
        -- The meta renders at 0.75em and counts at 0.75: a card of small text
        -- is not a full-page band.
        local card = preset_turn("Book Summary & Recs", "")
        ASUtils.set_attr(card[2], "bubble_meta", meta)
        assert.equal(class_of(card), "short-text", "a meta card keeps the chat shape")
        -- Perturbation: a card's worth more meta is a long turn.
        local fat = preset_turn("Book Summary & Recs", "")
        ASUtils.set_attr(fat[2], "bubble_meta", meta .. meta)
        assert.equal(class_of(fat), "long-text", "a doubled meta card takes the page")
    end),
}

return helper.runTests("bubble_width.lua", tests)
