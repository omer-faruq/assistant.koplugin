-- test/ui/viewer_selection_clear.lua
-- Tapping inside the result viewer must dismiss a live text selection.
-- The highlight rects of the answer live on the ScrollHtmlWidget's
-- HtmlBoxWidget and nothing else ever cleared them, so after a long press the
-- picked text stayed darkened for the life of the window - most visibly after
-- a recursive query, when the child viewer closes and leaves the parent
-- holding a highlight that no longer means anything.
--
-- The tap is consumed on purpose: one tap must not deselect AND turn the page
-- or follow a link. A viewer without a selection must keep returning false so
-- those taps still reach the text widget.
--
-- Usage: ./test/runui.sh ui/viewer_selection_clear
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test.wbuilder")
local UIManager = wb.UIManager
local Geom = require("ui/geometry")
local Event = require("ui/event")
local ChatGPTViewer = require("assistant_viewer")

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
local settings = {
    readSetting = function(_, key, def)
        if key == "minimalist_mode" then return false end
        if key == "auto_save_to_notebook" then return false end
        return def
    end,
}

local config = {
    getFeature = function() return nil end,
    getActiveProviderId = function() return "test-provider" end,
}

local assistant = {
    settings = settings,
    config = config,
    ui = {
        doc_settings = true,
        highlight = {
            highlight_dialog = nil,
            clear = function() end,
            onClose = function() end,
        },
        dictionary = { dict_window = nil },
    },
    ui_language_is_rtl = false,
    showProviderDialog = function() end,
    assistant_dialog = { runPrompt = function() end },
    querier = { provider_name = "test-provider", is_inited = function() return true end },
}

-- ── Helpers ──
local ANSWER = "The Ring was forged in Mount Doom to rule the other Rings of Power."
local SELECTION = "forged in Mount Doom"

local function make_viewer(text)
    return ChatGPTViewer:new{ assistant = assistant, text = text or ANSWER }
end

-- Showing a widget does not lay it out: frame.dimen and the button dimens are
-- filled in on the first paint, and onTapClose hit-tests against exactly those.
local function open_viewer(text)
    local viewer = make_viewer(text)
    UIManager:show(viewer)
    UIManager:forceRePaint()
    return viewer
end

local function is_open(viewer)
    return UIManager:isWidgetShown(viewer)
end

-- Marks a live selection the way HtmlBoxWidget:updateHighlight does after a
-- hold+pan, and counts how often the widget was repainted.
local function select(viewer)
    local htmlbox = viewer.scroll_text_w.htmlbox_widget
    htmlbox.highlight_rects = { { x = 12, y = 34, w = 40, h = 8 } }
    htmlbox.highlight_text = SELECTION
    htmlbox.hold_start_pos = "start"
    htmlbox.hold_end_pos = "end"
    local real_redraw = htmlbox.redrawHighlight
    htmlbox._redraws = 0
    htmlbox.redrawHighlight = function(self)
        self._redraws = self._redraws + 1
        return real_redraw(self)
    end
    return htmlbox
end

-- A tap somewhere inside the window frame, on the text.
local function inside_tap(viewer)
    local pos = Geom:new{ x = viewer.frame.dimen.x + 4, y = viewer.frame.dimen.y + 4 }
    return { pos = pos }
end

local function outside_tap()
    return { pos = Geom:new{ x = -50, y = -50 } }
end

-- A tap on the Close button of the action row. The point is the button
-- center: a real tap pos is a zero-size Geom, and notIntersectWith treats a
-- point exactly on a rect edge as no intersection.
local function close_button_tap(viewer)
    local button = viewer.button_table:getButtonById("close")
    local dimen = button and button.dimen
    if not dimen then return nil end
    return {
        pos = Geom:new{
            x = dimen.x + math.floor(dimen.w / 2),
            y = dimen.y + math.floor(dimen.h / 2),
        },
    }
end

print("\n== viewer_selection_clear ==")

-- 1. The regression: a tap inside the window with a live selection clears it,
--    and the tap is consumed.
do
    local viewer = open_viewer()
    local htmlbox = select(viewer)
    eq("selection is live before the tap", htmlbox.highlight_text, SELECTION)
    eq("handle: tap inside frame with selection", viewer:onTapClose(nil, inside_tap(viewer)), true)
    eq("selection text cleared", htmlbox.highlight_text, nil)
    eq("selection rects cleared", htmlbox.highlight_rects, nil)
    eq("hold positions cleared", htmlbox.hold_start_pos, nil)
    check("highlight repainted", htmlbox._redraws > 0)
    check("viewer still open", is_open(viewer))
    UIManager:close(viewer)
end

-- 1b. A selection with no hold positions (the state after the plugin built the
--     widget) is cleared and repainted just the same.
do
    local viewer = open_viewer()
    local htmlbox = viewer.scroll_text_w.htmlbox_widget
    htmlbox.highlight_rects = { { x = 1, y = 2, w = 3, h = 4 } }
    htmlbox.highlight_text = SELECTION
    eq("handle: rects only", viewer:onTapClose(nil, inside_tap(viewer)), true)
    eq("rects-only: cleared", htmlbox.highlight_rects, nil)
    eq("rects-only: text cleared", htmlbox.highlight_text, nil)
    UIManager:close(viewer)
end

-- 1c. _clearTextSelection reports honestly, and does not repaint when there
--     was nothing to erase.
do
    local viewer = open_viewer()
    eq("no selection: helper returns false", viewer:_clearTextSelection(), false)
    local htmlbox = select(viewer)
    eq("live selection: helper returns true", viewer:_clearTextSelection(), true)
    eq("live selection: repainted once", htmlbox._redraws, 1)
    eq("second clear: nothing left", viewer:_clearTextSelection(), false)
    eq("second clear: no extra repaint", htmlbox._redraws, 1)
    UIManager:close(viewer)
end

-- 2. The regression guard for page turns and link taps: no selection means the
--    tap must keep propagating.
do
    local viewer = open_viewer()
    local htmlbox = viewer.scroll_text_w.htmlbox_widget
    eq("handle: tap inside frame without selection", viewer:onTapClose(nil, inside_tap(viewer)), false)
    check("no repaint without a selection", (htmlbox._redraws or 0) == 0)
    check("viewer still open after an ignored tap", is_open(viewer))
    UIManager:close(viewer)
end

-- 3. Stacking rules are unchanged: a non-topmost viewer ignores the tap even
--    with a live selection, while the topmost one answers.
do
    local parent = open_viewer("Parent conversation.")
    local child = open_viewer("Nested lookup answer.")
    local parent_htmlbox = select(parent)
    local child_htmlbox = select(child)
    eq("non-topmost ignores the tap", parent:onTapClose(nil, inside_tap(parent)), false)
    eq("non-topmost keeps its selection", parent_htmlbox.highlight_text, SELECTION)
    check("parent stays open", is_open(parent))
    -- The topmost viewer is the one that answers: it deselects, it does not
    -- close, because the tap was inside its frame.
    eq("topmost clears the selection", child:onTapClose(nil, inside_tap(child)), true)
    eq("topmost selection cleared", child_htmlbox.highlight_text, nil)
    check("topmost stays open", is_open(child))
    UIManager:close(child)
    UIManager:close(parent)
end

-- 3b. A tap outside the frame still closes, selection or not.
do
    local with_selection = open_viewer()
    select(with_selection)
    eq("tap outside closes with a selection", with_selection:onTapClose(nil, outside_tap()), true)
    check("closed by the outside tap", not is_open(with_selection))

    local without = open_viewer()
    eq("tap outside closes without a selection", without:onTapClose(nil, outside_tap()), true)
    check("closed by the outside tap (no selection)", not is_open(without))
end

-- 4. The Close button wins over the dismissal: a tap on it closes the window
--    instead of silently deselecting.
do
    local viewer = open_viewer()
    local htmlbox = select(viewer)
    local tap = close_button_tap(viewer)
    if tap then
        eq("handle: tap on the Close button", viewer:onTapClose(nil, tap), true)
        check("Close button tap closed the window", not is_open(viewer))
        check("Close button tap did not just deselect", htmlbox.highlight_text == SELECTION)
    else
        -- The button layout is not available headless: the branch is then
        -- untestable here, not broken.
        print("  SKIP: close button tap (no button dimen)")
        UIManager:close(viewer)
    end
end

-- 4b. The same through a real gesture. A Button is an InputContainer that
--     matches its own GestureRange ("TapSelectButton") in onGesture, so on a
--     device the button is asked before the plain onTap propagation reaches
--     the viewer's onTapClose: the Close button keeps closing the window even
--     with a live selection that the viewer would otherwise swallow.
do
    local viewer = open_viewer()
    local htmlbox = select(viewer)
    local tap = close_button_tap(viewer)
    if tap then
        UIManager:sendEvent(Event:new("Gesture", { ges = "tap", pos = tap.pos }))
        check("real tap gesture on Close closed the window", not is_open(viewer))
        check("real tap gesture on Close did not deselect", htmlbox.highlight_text == SELECTION)
    else
        print("  SKIP: real tap on the Close button (no button dimen)")
        UIManager:close(viewer)
    end
end

-- 5. Nil-safety: the widget tree is rebuilt wholesale by update() and can be
--    mid-teardown when a late tap arrives.
do
    local viewer = open_viewer()
    local saved_widget = viewer.scroll_text_w
    viewer.scroll_text_w = nil
    eq("no scroll widget: tap is ignored", viewer:onTapClose(nil, inside_tap(viewer)), false)
    eq("no scroll widget: helper returns false", viewer:_clearTextSelection(), false)
    check("viewer survived the missing widget", is_open(viewer))

    viewer.scroll_text_w = saved_widget
    saved_widget.htmlbox_widget = nil
    eq("no htmlbox widget: tap is ignored", viewer:onTapClose(nil, inside_tap(viewer)), false)
    eq("no htmlbox widget: helper returns false", viewer:_clearTextSelection(), false)
    check("viewer survived the missing htmlbox", is_open(viewer))
    UIManager:close(viewer)
end

-- 6. The dismissal leaves the surrounding selection machinery alone: the
--    follow-up input dialog and the closing flag are untouched.
do
    local viewer = open_viewer()
    select(viewer)
    viewer.input_dialog = { is_shown = function() return true end }
    eq("input dialog up: tap still clears", viewer:onTapClose(nil, inside_tap(viewer)), true)
    check("input dialog not closed by the tap", viewer.input_dialog ~= nil)
    viewer.input_dialog = nil
    viewer.closing = true
    select(viewer)
    eq("closing: tap still clears", viewer:onTapClose(nil, inside_tap(viewer)), true)
    eq("closing flag untouched", viewer.closing, true)
    viewer.closing = nil
    UIManager:close(viewer)
end

-- 7. End to end, through a real gesture, on an answer long enough to span
--    pages. The scroll widget claims the tap first when it can turn the page,
--    and the htmlbox clears the highlight on a page change; when it cannot
--    (first page, right half), the tap reaches the viewer and is consumed by
--    the dismissal. Either way the stale highlight must be gone and the window
--    must stay open.
do
    local viewer = open_viewer(string.rep(ANSWER .. " ", 60))
    local htmlbox = viewer.scroll_text_w.htmlbox_widget
    local mid_y = viewer.frame.dimen.y + math.floor(viewer.frame.dimen.h / 2)
    for label, x in pairs({ right_half = viewer.frame.dimen.x + viewer.frame.dimen.w - 20,
                            left_half = viewer.frame.dimen.x + 20 }) do
        htmlbox.highlight_rects = { { x = 12, y = 34, w = 40, h = 8 } }
        htmlbox.highlight_text = SELECTION
        UIManager:sendEvent(Event:new("Gesture", { ges = "tap", pos = Geom:new{ x = x, y = mid_y } }))
        eq(label .. ": no stale highlight after a real tap", htmlbox.highlight_text, nil)
        check(label .. ": window stayed open", is_open(viewer))
    end
    UIManager:close(viewer)
end

print(string.format("\nviewer_selection_clear: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
