-- test/ui/quick_translate.lua
-- Headless UI test for dialogs/translate_quick.lua, the floating panel
-- that shows an auto-annotated translation:
--   * anchor_region: above the selection when the panel fits, below when
--     only the bottom has room, centered when neither side does
--   * the widget paints, and a tap dismisses it
--
-- Usage: ./test/runui.sh ui/quick_translate
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test.wbuilder")
local UIManager = wb.UIManager
local Screen = require("device").screen
local QT = require("dialogs/translate_quick")

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

print("\n== quick_translate ==")

-- ── anchor_region geometry ──
local W, H = Screen:getWidth(), Screen:getHeight()

-- Selection low on the screen: the panel goes above it.
local r = QT.anchor_region({ { y = H - 40, h = 20 } }, 100, W, H, 10)
eq("low selection: panel above", r.align, "bottom")
eq("low selection: region height reaches the selection top", r.h, H - 40 - 10)

-- Selection high on the screen: the panel goes below it.
r = QT.anchor_region({ { y = 10, h = 20 } }, 100, W, H, 10)
eq("high selection: panel below", r.align, "top")
eq("high selection: region starts under the selection", r.y, 10 + 20 + 10)
eq("high selection: region height is the rest of the screen", r.h, H - 40)

-- Panel taller than either side: fall back to the screen center.
r = QT.anchor_region({ { y = math.floor(H / 2) - 10, h = 20 } }, H, W, H, 10)
eq("no room on either side: centered", r.align, "center")

-- No selection boxes at all: centered.
r = QT.anchor_region(nil, 100, W, H, 10)
eq("no boxes: centered", r.align, "center")
r = QT.anchor_region({}, 100, W, H, 10)
eq("empty boxes: centered", r.align, "center")

-- Multiple boxes: the union of their vertical extents decides.
r = QT.anchor_region({ { y = 100, h = 10 }, { y = H - 60, h = 30 } }, 50, W, H, 10)
eq("multi boxes: union drives the layout", r.align, "bottom")
eq("multi boxes: height from the topmost box", r.h, 100 - 10)

-- ── widget smoke: paints, dismisses ──
local settings = {
    readSetting = function(_, key, def)
        if key == "response_direction" then return "auto" end
        return def
    end,
}
local assistant = { settings = settings }

local panel = QT.QuickTranslate:new{
    text = "魔戒是在末日火山中锻成的。",
    boxes = { { y = math.floor(H * 0.8), h = 20 } },
    assistant = assistant,
}
UIManager:show(panel)
UIManager:forceRePaint()
check("panel paints without error", true)

-- The widget routes its child through a WidgetContainer with the
-- computed align; the panel itself spans the screen for touch capture.
eq("touch-capture spans the screen", panel:getSize().w, W)

panel:onTapClose()
UIManager:forceRePaint()
check("tap dismisses the panel", not UIManager:isWidgetShown(panel))

print(string.format("\nquick_translate: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
