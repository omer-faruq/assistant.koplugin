-- test_dict_vocab_autoadd.lua
-- Guards the dictionary's "Auto Add Word to Vocabulary Builder" switch:
--   * the Dictionary Settings menu owns the setting key
--   * the dictionary dialog reads the same key, so menu and dialog cannot drift
--   * the Vocabulary Builder extra button only exists while the switch is off
--   * with the switch on the add fires silently right after the result window
--     is shown, through the same local the button uses
--   * the "no word to add" failure is reported on both paths, never gated on
--     the success notification
-- Headless-safe: the widget-heavy dialog is never required here, only scanned.
local helper = require("test.helper")
local assert = helper.assert

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local function count_plain(haystack, needle)
    local n, init = 0, 1
    while true do
        local hit = haystack:find(needle, init, true)
        if not hit then break end
        n = n + 1
        init = hit + 1
    end
    return n
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local menu_src = read_source("assistant_settings_menu.lua")
local dict_src = read_source("assistant_dictdialog.lua")

local tests = {
    test("the menu defines the switch", function()
        assert.matches(menu_src, 'readSetting%("dict_auto_add_vocab", false%)',
            "menu must read the switch with a false default")
        assert.matches(menu_src, 'toggle%("dict_auto_add_vocab"%)',
            "menu must toggle the switch")
        assert.matches(menu_src, 'text = _%("Auto Add Word to Vocabulary Builder"%)',
            "menu must carry the switch label")
    end),

    test("menu and dialog share one setting key", function()
        assert.isTrue(dict_src:find('readSetting("dict_auto_add_vocab", false)', 1, true) ~= nil,
            "the dialog must read the very same key as the menu")
    end),

    test("the Vocabulary Builder button is gated on the switch", function()
        local gate = dict_src:find("if not auto_add_vocab then", 1, true)
        local button = dict_src:find('text = _("Vocabulary Builder")', 1, true)
        assert.notNil(gate, "the button must sit behind an if not auto_add_vocab then")
        assert.notNil(button, "the Vocabulary Builder button must still exist")
        assert.isTrue(gate < button,
            "the gate must come before the button, or the button is never dropped")
        assert.matches(dict_src, 'extra_buttons = extra_buttons,',
            "the conditional table must be what the viewer receives")
    end),

    test("the switch fires the add silently after the window is shown", function()
        assert.isTrue(dict_src:find("add_word_to_vocabulary(false)", 1, true) ~= nil,
            "the auto path must not notify")
        local shown = dict_src:find("UIManager:show(chatgpt_viewer)", 1, true)
        local auto = dict_src:find("if auto_add_vocab then", 1, true)
        assert.notNil(shown, "the viewer must still be shown")
        assert.notNil(auto, "the auto-add block must exist")
        assert.isTrue(shown < auto,
            "the add must fire after the show, so its dialog stacks on top")
    end),

    test("a failure is reported on both paths, never gated", function()
        -- "No word to add" is an error, so the auto path must not swallow it:
        -- a silently skipped add is indistinguishable from a broken switch.
        -- The guard is the InfoMessage sitting outside any show_notification
        -- check, before the WordLookedUp event.
        local empty = dict_src:find('if not word or word == "" then', 1, true)
        local event = dict_src:find('Event:new("WordLookedUp"', 1, true)
        assert.notNil(empty, "the empty-word guard must exist")
        assert.notNil(event, "the add must still fire the event")
        local region = dict_src:sub(empty, event)
        assert.isTrue(region:find('_("No word to add")', 1, true) ~= nil,
            "the no-word error must be reported")
        assert.isTrue(region:find("show_notification", 1, true) == nil,
            "the error must not be gated on show_notification")
    end),

    test("one firing site, shared by both paths", function()
        assert.isTrue(dict_src:find("add_word_to_vocabulary(true)", 1, true) ~= nil,
            "the button must go through the shared local")
        assert.equal(count_plain(dict_src, 'Event:new("WordLookedUp"'), 1,
            "the WordLookedUp event must be fired from exactly one place")
        assert.isTrue(dict_src:find('Event:new("WordLookedUp", word, book_title, true)', 1, true) ~= nil,
            "the add must pass is_manual = true, or the capture-while-reading setting vetoes it")
        -- Only the success ack is optional, so show_notification must still
        -- guard exactly one thing: the "Added to vocabulary builder" dialog.
        assert.equal(count_plain(dict_src, "if show_notification then"), 1,
            "show_notification must gate the success ack only")
    end),
}

return helper.runTests("dict_vocab_autoadd.lua", tests)
