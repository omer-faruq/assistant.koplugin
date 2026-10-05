-- test/ui/viewer_options_menu.lua
-- Headless UI test for the result viewer's options menu
-- (ResultViewer:onShowMenu): the Text Direction row cycles Auto -> RTL -> LTR
-- -> Auto, the menu stays open, and the row's own label follows the mode.
--
-- The label is built from text_func at construction, so without rebuilding the
-- dialog the row keeps showing the mode it was opened with -- reported on
-- discussion #213 ("the button's label itself does not refresh when clicked").
--
-- Usage: SDL_VIDEODRIVER=dummy ./test/runui.sh ui/viewer_options_menu
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test.wbuilder")
local UIManager = wb.UIManager
local T = require("ffi/util").template
local _ = require("assistant_gettext")
local TextUtils = require("assistant_text_utils")
local ResultViewer = require("assistant_viewer")

-- The viewer rebuilds its scroll widget through the plugin's own
-- ScrollHtmlWidget.scrollToPage patch, which main.lua installs at startup.
require("assistant_hooks").setupScrollHtmlWidget()

-- The label the row builds, in whatever language this run is set to.
local function label_for(mode)
    return T(_("Text Direction: %1"), TextUtils.direction_label(mode))
end

-- ── Minimal assertion helpers (this test runs outside test/helper.lua, which
-- stubs the very widgets the viewer needs) ──
local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        failed = failed + 1
        print("  FAIL: " .. name .. (detail and (" -- " .. detail) or ""))
    end
end
local function eq(name, actual, expected)
    check(name, actual == expected,
        string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

-- ── Fakes ──
local switches = { response_direction = "auto", minimalist_mode = false }

local assistant = {
    settings = {
        readSetting = function(_, key, def)
            local value = switches[key]
            if value ~= nil then return value end
            return def
        end,
        saveSetting = function(_, key, value)
            switches[key] = value
        end,
    },
    config = { getFeature = function() return nil end },
    ui = { doc_settings = true },
    ui_language_is_rtl = false,
    showProviderDialog = function() end,
    assistant_dialog = { runPrompt = function() end },
}

-- ── Show/close interception: the menu is found by what it pushed ──
local shown = {}
local real_show, real_close = UIManager.show, UIManager.close
function UIManager:show(widget, ...)
    shown[#shown + 1] = widget
    return real_show(self, widget, ...)
end
function UIManager:close(widget, ...)
    for idx = #shown, 1, -1 do
        if shown[idx] == widget then
            table.remove(shown, idx)
            break
        end
    end
    return real_close(self, widget, ...)
end

local function menu_row(menu, id)
    for i = 1, #menu.buttons do
        local row = menu.buttons[i]
        for j = 1, #row do
            if row[j].id == id then return row[j] end
        end
    end
    return nil
end

-- ── Tests ──
print("\n== viewer_options_menu ==")

do
    switches.response_direction = "auto"
    local viewer = ResultViewer:new{ assistant = assistant, text = "The answer." }
    UIManager:show(viewer)
    viewer:onShowMenu()

    local menu = shown[#shown]
    check("the options menu opens", menu ~= nil and menu ~= viewer)

    local row = menu and menu_row(menu, "text_direction")
    check("the Text Direction row exists", row ~= nil)
    if row then
        eq("the row shows the current mode", row.text_func(), label_for("auto"))

        row.callback()
        eq("a tap cycles auto -> rtl", switches.response_direction, "rtl")
        local after_one = menu:getButtonById("text_direction")
        check("the label follows the mode while the menu stays open",
            after_one ~= nil and after_one.text == label_for("rtl"),
            after_one and after_one.text)
        check("the menu did not close on the tap", shown[#shown] == menu)

        menu_row(menu, "text_direction").callback()
        eq("a second tap cycles rtl -> ltr", switches.response_direction, "ltr")
        local after_two = menu:getButtonById("text_direction")
        check("the label follows again",
            after_two ~= nil and after_two.text == label_for("ltr"),
            after_two and after_two.text)

        menu_row(menu, "text_direction").callback()
        eq("a third tap returns to auto", switches.response_direction, "auto")
        local after_three = menu:getButtonById("text_direction")
        check("Auto is reachable again from the menu",
            after_three ~= nil and after_three.text == label_for("auto"),
            after_three and after_three.text)
    end

    UIManager:close(menu)
end

print(string.format("\n%d passed, %d failed", passed, failed))
UIManager:unsetRunForeverMode()
UIManager:quit(failed > 0 and 1 or 0)
