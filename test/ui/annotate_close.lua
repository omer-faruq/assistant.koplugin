-- test/ui/annotate_close.lua
-- Headless UI test for the viewer's Annotate button: a successful annotate
-- saves the highlight + note, fires AnnotationsModified, and closes the
-- viewer; the failure paths (no highlight saved, nothing left to annotate)
-- leave the viewer open.
--
-- Usage: ./test/runui.sh ui/annotate_close
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test.wbuilder")
local UIManager = wb.UIManager
local ResultViewer = require("dialogs/viewer")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("core/gettext")

local SELECTION = "forged in Mount Doom"
local ANSWER_BODY = "The Ring was forged in secret, and its master keeps it still."
local ANSWER = 'Highlighted text: "' .. SELECTION .. '"\n\n' .. ANSWER_BODY

-- ── Minimal assertion helpers (this test runs outside test/helper.lua,
-- which stubs the very widgets the viewer needs) ──
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
        return def
    end,
}
local config = {
    getFeature = function() return nil end,
}

local annotations = { {} }
local handle_events = {}
local highlight_clears = 0
local save_highlight_result = 1
local ui = {
    doc_settings = true,
    highlight = {
        highlight_dialog = nil,
        saveHighlight = function() return save_highlight_result end,
        clear = function() highlight_clears = highlight_clears + 1 end,
    },
    annotation = { annotations = annotations },
    dictionary = { dict_window = nil },
    handleEvent = function(_, event)
        handle_events[#handle_events + 1] = event
    end,
}
local assistant = {
    settings = settings,
    config = config,
    ui = ui,
    ui_language_is_rtl = false,
    assistant_dialog = {},
}

-- ── Show/close interception: InfoMessages and closes stay observable ──
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

local function count_infomessages()
    local n = 0
    for _, widget in ipairs(shown) do
        if getmetatable(widget) == InfoMessage then n = n + 1 end
    end
    return n
end

local function make_viewer()
    annotations[1] = {}
    handle_events = {}
    highlight_clears = 0
    save_highlight_result = 1
    shown = {}
    return ResultViewer:new{
        assistant = assistant,
        ui = ui,
        text = ANSWER,
        highlighted_text = SELECTION,
        is_show_addnote = true,
    }
end

-- Finds the Annotate button descriptor in the viewer's button table and
-- returns its callback.
local function annotate_button(viewer)
    for row_i = 1, #viewer.button_table.buttons do
        local row = viewer.button_table.buttons[row_i]
        for btn_i = 1, #row do
            local btn = row[btn_i]
            if btn.text == _("Annotate") then return btn end
        end
    end
    return nil
end

-- ── Tests ──
print("\n== annotate_close ==")

-- (a) success: note saved from the answer, viewer closed
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    local btn = annotate_button(viewer)
    check("annotate button present", btn ~= nil)
    btn.callback()
    eq("note text: echo stripped, answer kept", annotations[1].note, ANSWER_BODY)
    eq("AnnotationsModified fired", #handle_events, 1)
    eq("closing flag set", viewer.closing, true)
    check("viewer closed", not UIManager:isWidgetShown(viewer))
    eq("success InfoMessage shown", count_infomessages(), 1)
    eq("live selection cleared", highlight_clears, 1)
end

-- (b) saveHighlight fails: no annotation, viewer stays open
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    save_highlight_result = nil
    annotate_button(viewer).callback()
    eq("no note written", annotations[1].note, nil)
    eq("closing flag unset", viewer.closing, nil)
    check("viewer still shown", UIManager:isWidgetShown(viewer))
    eq("warning InfoMessage shown", count_infomessages(), 1)
    UIManager:close(viewer)
end

-- (c) answer carries only the highlighted echo: nothing to annotate
do
    local viewer = make_viewer()
    viewer.text = 'Highlighted text: "' .. SELECTION .. '"   '
    UIManager:show(viewer)
    annotate_button(viewer).callback()
    eq("no note written", annotations[1].note, nil)
    eq("closing flag unset", viewer.closing, nil)
    check("viewer still shown", UIManager:isWidgetShown(viewer))
    eq("warning InfoMessage shown", count_infomessages(), 1)
    UIManager:close(viewer)
end

UIManager.show, UIManager.close = real_show, real_close

print(string.format("\nannotate_close: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
