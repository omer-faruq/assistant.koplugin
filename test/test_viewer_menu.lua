-- test_viewer_menu.lua
-- Static guards for ChatGPTViewer:onShowMenu refresh behavior.
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
    local start = src:find("function ChatGPTViewer:onShowMenu", 1, true)
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
        -- (opens settings). RTL/Justify/Reasoning must not.
        assert.equal(count_plain(menu, "UIManager:close%(dialog%)"), 2,
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

    test("rebuild forces a viewer repaint", function()
        local src = read_viewer()
        assert.isTrue(src:find('UIManager:setDirty("all", "partial", self.frame.dimen)', 1, true) ~= nil,
            "_refreshScrollWidget must repaint like TextViewer:reinit")
    end),
}

return helper.runTests("viewer_menu", tests)
