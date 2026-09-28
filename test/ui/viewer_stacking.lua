-- test/ui/viewer_stacking.lua
-- Viewers must STACK, not replace each other. A recursive query (select text
-- inside a result -> Dictionary / Wikipedia) opens its own result window on
-- top of the one it was asked from; closing the child must return the reader
-- to the parent conversation.
--
-- This used to be a module-level `active_chatgpt_viewer` singleton that
-- closed the previous viewer in init(), so the parent was destroyed the moment
-- the child was built.
--
-- Usage: ./test/runui.sh ui/viewer_stacking
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test/wbuilder")
local UIManager = wb.UIManager
local Geom = require("ui/geometry")
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
local cleared, reader_ui_closed = 0, 0
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
    -- A live book selection: the recursive flow must not strip it.
    ui = {
        doc_settings = true,
        highlight = {
            highlight_dialog = nil,
            clear = function() cleared = cleared + 1 end,
            onClose = function() reader_ui_closed = reader_ui_closed + 1 end,
        },
        dictionary = { dict_window = nil },
    },
    ui_language_is_rtl = false,
    showProviderDialog = function() end,
    assistant_dialog = {
        runPrompt = function() end,
    },
    querier = { provider_name = "test-provider", is_inited = function() return true end },
}

local function make_viewer(text)
    return ChatGPTViewer:new{ assistant = assistant, text = text }
end

-- UIManager:close dispatches "CloseWidget" -> onCloseWidget, which is what pops
-- the stack. Going through the real UIManager keeps the test honest about
-- which code path actually pops.
local function open_viewer(text)
    local viewer = make_viewer(text)
    UIManager:show(viewer)
    return viewer
end

local function is_open(viewer)
    return UIManager:isWidgetShown(viewer)
end

-- A tap at an absolute position, outside every window frame. onTapClose only
-- reads ges.pos, so the stand-in needs nothing else.
local function outside_tap()
    return { pos = Geom:new{ x = -50, y = -50 } }
end

print("\n== viewer_stacking ==")

-- 1. The core regression: a second viewer must NOT close the first.
do
    local parent = open_viewer("The parent answer mentions Mount Doom.")
    check("parent is open", is_open(parent))
    local child = open_viewer("The child answer explains the term.")
    check("parent survives the child", is_open(parent),
        "building a viewer closed its predecessor")
    check("child is open", is_open(child))
    check("both on the window stack at once", is_open(parent) and is_open(child))
    UIManager:close(child)
    UIManager:close(parent)
end

-- 2. Closing the TOP viewer leaves the parent open.
do
    local parent = open_viewer("Parent conversation.")
    local child = open_viewer("Nested lookup answer.")
    child:onClose()
    check("child closed", not is_open(child))
    check("parent still open after closing the child", is_open(parent))
    check("parent keeps its text", parent.text == "Parent conversation.")
    UIManager:close(parent)
    check("parent closes on its own afterwards", not is_open(parent))
end

-- 3. A non-topmost viewer ignores onTapClose; the topmost one handles it.
do
    local parent = open_viewer("Parent conversation.")
    local child = open_viewer("Nested lookup answer.")
    -- The parent is movable, so a dragged child can expose it: a tap on the
    -- exposed parent region must not dismiss the parent.
    local handled = parent:onTapClose(nil, outside_tap())
    eq("non-topmost onTapClose returns false", handled, false)
    check("parent stays open after the ignored tap", is_open(parent))

    local child_handled = child:onTapClose(nil, outside_tap())
    eq("topmost onTapClose handles the tap", child_handled, true)
    check("topmost closed by the tap", not is_open(child))
    check("parent untouched by the child's close", is_open(parent))
    UIManager:close(parent)
end

-- 3b. Once the child is gone the parent becomes topmost again, so its own
-- tap-outside affordance comes back.
do
    local parent = open_viewer("Parent conversation.")
    local child = open_viewer("Nested lookup answer.")
    child:onClose()
    eq("parent is topmost after the child closed", parent:onTapClose(nil, outside_tap()), true)
    check("parent closed by its own tap", not is_open(parent))
end

-- 4. HoldClose unwinds the whole stack, not just the top viewer.
do
    local first = open_viewer("First.")
    local second = open_viewer("Second.")
    local third = open_viewer("Third.")
    third:HoldClose()
    check("HoldClose closed the top viewer", not is_open(third))
    check("HoldClose closed the middle viewer", not is_open(second))
    check("HoldClose closed the bottom viewer", not is_open(first))
end

-- 4b. HoldClose still tears down the reader-side dialogs it always did, with
--     the same "both are optional" guards (FileManager has no book).
do
    local dict_closed = false
    assistant.ui.dictionary.dict_window = { onClose = function() dict_closed = true end }
    local before = reader_ui_closed
    local top = open_viewer("First.")
    local child = open_viewer("Second.")
    child:HoldClose()
    check("HoldClose closed dict_window", dict_closed)
    check("HoldClose closed ui.highlight", reader_ui_closed > before)
    assistant.ui.dictionary.dict_window = nil
    UIManager:close(top)
end

-- 4b-bis. With no dict_window and no highlight (FileManager: dictionary only
--        registered, no book), HoldClose must not error.
do
    local saved_dict, saved_highlight = assistant.ui.dictionary, assistant.ui.highlight
    assistant.ui.dictionary, assistant.ui.highlight = {}, nil
    local only = open_viewer("No book open.")
    local ok = pcall(function() only:HoldClose() end)
    check("HoldClose survives a missing ui.highlight", ok)
    check("viewer still closed", not is_open(only))
    assistant.ui.dictionary, assistant.ui.highlight = saved_dict, saved_highlight
end

-- 4c. HoldClose with no stack of its own (only the caller) still closes it.
do
    local only = open_viewer("Only viewer.")
    only:HoldClose()
    check("HoldClose closes a lone viewer", not is_open(only))
end

-- 5. A closing child must not strip the book selection its parent still needs:
--    a later query from the parent resolves the page number from it.
do
    cleared = 0
    local parent = open_viewer("Parent conversation.")
    local child = open_viewer("Nested lookup answer.")
    child:onClose()
    eq("closing a child leaves the selection alone", cleared, 0)
    check("parent still open", is_open(parent))
    -- The last viewer out does clear it, as before.
    parent:onClose()
    eq("closing the last viewer clears the selection", cleared, 1)
end

-- 5b. The highlight_dialog / dict_window guard is unchanged.
do
    cleared = 0
    assistant.ui.highlight.highlight_dialog = { is_shown = function() return true end }
    local only = open_viewer("Only viewer.")
    only:onClose()
    eq("highlight_dialog present: selection kept", cleared, 0)
    assistant.ui.highlight.highlight_dialog = nil

    assistant.ui.dictionary.dict_window = { is_shown = function() return true end }
    local other = open_viewer("Only viewer.")
    other:onClose()
    eq("dict_window present: selection kept", cleared, 0)
    assistant.ui.dictionary.dict_window = nil
end

-- 6. Stacking does not disturb the per-viewer selection-menu guards.
do
    local parent = open_viewer("Parent conversation.")
    local child = open_viewer("Nested lookup answer.")
    eq("fresh child accepts a selection", child.closing, nil)
    eq("parent accepts a selection too", parent.closing, nil)
    -- Closing the child must not mark the parent as closing.
    child:onClose()
    eq("parent not marked closing by the child's close", parent.closing, nil)
    check("parent still open", is_open(parent))
    UIManager:close(parent)
end

-- 7. A deep chain unwinds cleanly, leaving no residue in the stack: after
--    everything is closed, a brand new viewer is topmost and alone.
do
    local viewers = {}
    for i = 1, 5 do
        viewers[i] = open_viewer("Answer " .. i)
    end
    check("all five open at once", is_open(viewers[1]) and is_open(viewers[5]))
    viewers[5]:HoldClose()
    for i, viewer in ipairs(viewers) do
        check("chain viewer " .. i .. " closed", not is_open(viewer))
    end
    -- A leftover entry would make this parent non-topmost, so its own
    -- tap-outside would be ignored.
    local fresh = open_viewer("Fresh answer.")
    eq("fresh viewer is alone and topmost", fresh:onTapClose(nil, outside_tap()), true)
    check("fresh viewer closed", not is_open(fresh))
end

print(string.format("\nviewer_stacking: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
