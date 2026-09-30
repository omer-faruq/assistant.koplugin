-- test_viewer_menu.lua
-- Static guards for ResultViewer:onShowMenu. This file is the single owner
-- of the result-window menu ground: the Minimalist Mode guards that used to
-- slice the same function live in test_minimalist_mode.lua, which only covers
-- the pure formatter.
-- Toggle items (RTL/Justify/Reasoning) must not close the menu: like the
-- upstream TextViewer toggles they save + rebuild in place, so the menu
-- close repaint cannot race the rebuild repaint and ghost the tapped item
-- on e-ink. Items opening another dialog (Text Size, Models) keep
-- their explicit close.
local helper = require("test.helper")
local assert = helper.assert

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function read_viewer()
    local f = io.open(project_root .. "assistant_viewer.lua", "r")
    assert.notNil(f, "could not read assistant_viewer.lua")
    local src = f:read("*a")
    f:close()
    return src
end

local function menu_body(src)
    local start = src:find("function ResultViewer:onShowMenu", 1, true)
    assert.notNil(start, "onShowMenu must exist")
    return src:sub(start)
end

local function count_plain(haystack, needle)
    local _, n = haystack:gsub(needle, "")
    return n
end

local tests = {
    test("toggles keep the menu open, openers close it", function()
        local menu = menu_body(read_viewer())
        -- Exactly two closes: Text Size (opens SpinWidget) and Models
        -- (opens settings). RTL/Justify/Reasoning must not. Counted by the
        -- call itself, not its argument list, so a repainting close with
        -- other arguments does not read as a third one.
        assert.equal(count_plain(menu, "UIManager:close"), 2,
            "only dialog-opening items may close the menu")
        local toggle_start = menu:find('text = _("RTL Layout")', 1, true)
        local toggle_end = menu:find('text = _("Models")', 1, true)
        assert.notNil(toggle_start, "RTL item must exist")
        assert.notNil(toggle_end, "Models item must exist")
        assert.notNil(menu:find('text = _("Show Follow-up Questions")', 1, true),
            "Follow-up item must exist")
        local toggle_region = menu:sub(toggle_start, toggle_end)
        assert.isTrue(toggle_region:find("UIManager:close", 1, true) == nil,
            "toggle items must not close the menu")
    end),
}

return helper.runTests("viewer_menu", tests)
