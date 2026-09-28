-- test/ui/viewer_selection_menu.lua
-- Headless UI test for the selection action menu of the result viewer
-- (ChatGPTViewer:handleTextSelection): a long press in the answer text must
-- offer Dictionary / Wikipedia / Copy / Cancel in a 2x2 grid, Dictionary must
-- reach the shared dictionary dialog, and Wikipedia must reach
-- AssistantDialog:runPrompt with the selected text and its own prompt id.
--
-- Usage: ./test/runui.sh ui/viewer_selection_menu
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test.wbuilder")
local UIManager = wb.UIManager
local Device = require("device")
local NetUtils = require("assistant_net_utils")
local ChatGPTViewer = require("assistant_viewer")
local InfoMessage = require("ui/widget/infomessage")

local ANSWER = "The Ring was forged in Mount Doom to rule the other Rings of Power."
local SELECTION = "forged in Mount Doom"

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
local runprompt_calls = {}
local dict_calls = {}

local settings = {
    readSetting = function(_, key, def)
        if key == "minimalist_mode" then return false end
        return def
    end,
}

local config = {
    getFeature = function(_, key)
        if key == "prompts" then return nil end -- built-in prompts
        return nil
    end,
}

local assistant = {
    settings = settings,
    config = config,
    ui = { doc_settings = true },
    ui_language_is_rtl = false,
    showProviderDialog = function() end,
    assistant_dialog = {
        runPrompt = function(_, highlighted_text, prompt_id)
            runprompt_calls[#runprompt_calls + 1] =
                { text = highlighted_text, prompt_id = prompt_id }
        end,
    },
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

-- Offline, but the prompt path must run in the test.
local real_run_when_online = NetUtils.runWhenOnlineFast
NetUtils.runWhenOnlineFast = function(callback)
    callback()
end

-- The viewer pulls assistant_dictdialog in lazily; stand it in so the routing
-- is observable without a live querier behind the real dictionary dialog.
package.loaded["assistant_dictdialog"] = function(assistant_arg, highlighted_text)
    dict_calls[#dict_calls + 1] =
        { assistant = assistant_arg, text = highlighted_text }
end

-- The SDL clipboard goes through SDL; keep the copy observable.
local clipboard
Device.input.setClipboardText = function(text)
    clipboard = text
end

-- ── Helpers ──
local function make_viewer()
    runprompt_calls = {}
    dict_calls = {}
    shown = {}
    clipboard = nil
    return ChatGPTViewer:new{
        assistant = assistant,
        text = ANSWER,
    }
end

-- Marks the live selection on the widget the viewer renders its text with,
-- the way HtmlBoxWidget:updateHighlight does after a hold+pan.
local function select(viewer, rects)
    local htmlbox = viewer.scroll_text_w.htmlbox_widget
    htmlbox.highlight_rects = rects
    htmlbox.highlight_text = SELECTION
    return htmlbox
end

local function press(viewer, text, rects)
    select(viewer, rects)
    viewer:handleTextSelection(text, 0.6)
    return shown[#shown]
end

-- ── Tests ──
print("\n== viewer_selection_menu ==")

-- (a) the menu opens for a selection, with the expected 2x2 layout
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    local menu = press(viewer, SELECTION, { { x = 12, y = 34, w = 40, h = 8 } })
    check("menu opens on selection", menu ~= nil and menu ~= viewer)
    if menu then
        local rows = menu.buttons
        eq("menu has two rows", rows and #rows, 2)
        eq("four buttons total",
            #rows[1] + #rows[2], 4)
        local labels = {}
        for _, row in ipairs(rows or {}) do
            local row_labels = {}
            for _, btn in ipairs(row) do
                row_labels[#row_labels + 1] = btn.text
            end
            labels[#labels + 1] = table.concat(row_labels, " | ")
        end
        eq("row 1 is Dictionary | Wikipedia", labels[1], "Dictionary | Wikipedia")
        eq("row 2 is Copy | Cancel", labels[2], "Copy | Cancel")
    end
    UIManager:close(menu)
end

-- The dropped prompts must be gone from the menu, not merely reordered
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    local menu = press(viewer, SELECTION, { { x = 1, y = 2, w = 3, h = 4 } })
    local offered = {}
    for _, row in ipairs(menu.buttons) do
        for _, btn in ipairs(row) do
            offered[btn.text] = true
        end
    end
    for _, gone in ipairs({ "Explain", "Translate", "Simplify" }) do
        check(gone .. ": not offered", offered[gone] == nil)
    end
    UIManager:close(menu)
end

-- (b) Dictionary routes to the shared dictionary dialog
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    runprompt_calls = {}
    local menu = press(viewer, "  " .. SELECTION .. "  ", { { x = 1, y = 2, w = 3, h = 4 } })
    menu.buttons[1][1].callback()
    eq("dictionary: one showDictionaryDialog call", #dict_calls, 1)
    eq("dictionary: trimmed selected text", dict_calls[1] and dict_calls[1].text, SELECTION)
    eq("dictionary: assistant passed through", dict_calls[1] and dict_calls[1].assistant, assistant)
    eq("dictionary: no runPrompt", #runprompt_calls, 0)
    check("dictionary: menu closed", not UIManager:isWidgetShown(menu))
    UIManager:close(viewer)
end

-- (c) Wikipedia reaches runPrompt with its prompt id and the selected text
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    runprompt_calls = {}
    local menu = press(viewer, "  " .. SELECTION .. "  ", { { x = 1, y = 2, w = 3, h = 4 } })
    menu.buttons[1][2].callback()
    eq("wikipedia: one runPrompt call", #runprompt_calls, 1)
    eq("wikipedia: prompt id", runprompt_calls[1] and runprompt_calls[1].prompt_id, "wikipedia")
    eq("wikipedia: trimmed selected text", runprompt_calls[1] and runprompt_calls[1].text, SELECTION)
    eq("wikipedia: no showDictionaryDialog", #dict_calls, 0)
    check("wikipedia: menu closed", not UIManager:isWidgetShown(menu))
    UIManager:close(viewer)
end

-- (d) Cancel closes without side effects
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    local menu = press(viewer, SELECTION, { { x = 1, y = 2, w = 3, h = 4 } })
    menu.buttons[2][2].callback()
    eq("cancel: no runPrompt", #runprompt_calls, 0)
    eq("cancel: no clipboard write", clipboard, nil)
    eq("cancel: no showDictionaryDialog", #dict_calls, 0)
    check("cancel: menu closed", not UIManager:isWidgetShown(menu))
    UIManager:close(viewer)
end

-- (d) an empty (or whitespace-only) selection is rejected
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    -- Rejection is an InfoMessage (errors/acks are not Notifications), so the
    -- count of pushed widgets does grow: what must not appear is a menu.
    for label, blank in pairs({ whitespace = "", spaces = "   ", newlines = "\n\t " }) do
        shown = {}
        press(viewer, blank, { { x = 1, y = 2, w = 3, h = 4 } })
        local menus, messages = 0, 0
        for _, widget in ipairs(shown) do
            if widget.buttons then menus = menus + 1 end
            if getmetatable(widget) == InfoMessage then messages = messages + 1 end
        end
        eq(label .. ": no menu pushed", menus, 0)
        eq(label .. ": InfoMessage shown", messages, 1)
        if shown[#shown] then UIManager:close(shown[#shown]) end
    end
    eq("blank: no runPrompt", #runprompt_calls, 0)
    eq("blank: no showDictionaryDialog", #dict_calls, 0)
    UIManager:close(viewer)
end

-- Copy writes the selection to the clipboard
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    local menu = press(viewer, SELECTION, { { x = 1, y = 2, w = 3, h = 4 } })
    menu.buttons[2][1].callback()
    eq("copy: clipboard holds the selection", clipboard, SELECTION)
    eq("copy: no runPrompt", #runprompt_calls, 0)
    eq("copy: no showDictionaryDialog", #dict_calls, 0)
    UIManager:close(viewer)
end

-- The menu is anchored on the selection, translated through the widget dimen
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    local htmlbox = select(viewer, { { x = 12, y = 34, w = 40, h = 8 } })
    local anchor = viewer:_selectionAnchor()
    check("anchor present", anchor ~= nil)
    if anchor then
        eq("anchor x", anchor.x, htmlbox.dimen.x + 12)
        eq("anchor y", anchor.y, htmlbox.dimen.y + 34)
    end
    htmlbox.highlight_rects = nil
    eq("no rects: centered (no anchor)", viewer:_selectionAnchor(), nil)
    UIManager:close(viewer)
end

-- While the viewer is closing (or a follow-up input is up) no menu appears
do
    local viewer = make_viewer()
    UIManager:show(viewer)
    local rects = { { x = 1, y = 2, w = 3, h = 4 } }
    local before = #shown
    viewer.closing = true
    viewer:handleTextSelection(SELECTION, 0.6)
    eq("closing: no menu pushed", #shown, before)
    eq("closing: no showDictionaryDialog", #dict_calls, 0)
    viewer.closing = nil
    viewer.input_dialog = { is_shown = function() return true end }
    viewer:handleTextSelection(SELECTION, 0.6)
    eq("input dialog open: no menu pushed", #shown, before)
    viewer.input_dialog = nil
    UIManager:close(viewer)
end

NetUtils.runWhenOnlineFast = real_run_when_online
UIManager.show, UIManager.close = real_show, real_close
package.loaded["assistant_dictdialog"] = nil

print(string.format("\nviewer_selection_menu: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
