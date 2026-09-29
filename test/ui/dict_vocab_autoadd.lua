-- test/ui/dict_vocab_autoadd.lua
-- The dictionary's "Auto Add Word to Vocabulary Builder" switch is a runtime
-- ordering property: the add must fire AFTER the result window is shown, or
-- the Vocabulary Builder dialog opens underneath it, out of sight. Both the
-- real UIManager:show and the fake ui:handleEvent append to one log, so the
-- order of the two calls is observed, not inferred from the source.
--
-- Usage: ./test/runui.sh ui/dict_vocab_autoadd
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test.wbuilder")
local UIManager = wb.UIManager
local InfoMessage = require("ui/widget/infomessage")
local ResultViewer = require("assistant_viewer")
local _ = require("assistant_gettext")
local showDictionaryDialog = require("assistant_dictdialog")

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

-- ── Call log ──
-- One log per scenario, appended to by the two real hooks below, so the
-- relative order of the calls is the property under test.
local current

-- Wrapping the real show keeps the viewer genuinely on the window stack: the
-- "was it up when the event fired" check below reads that stack.
local real_show = UIManager.show
UIManager.show = function(self, widget, ...)
    local mt = getmetatable(widget)
    local kind = "show:other"
    if mt == ResultViewer then kind = "show:viewer"
    elseif mt == InfoMessage then kind = "show:message" end
    if current then
        current.log[#current.log + 1] = kind
        current.shown[#current.shown + 1] = widget
    end
    return real_show(self, widget, ...)
end

-- ── Fakes ──
local ANSWER = "Smaug was forged in Mount Doom to guard the treasure there."

local function make_assistant(auto_add_vocab)
    local log, events, shown = {}, {}, {}
    current = { log = log, events = events, shown = shown }

    local settings = {
        readSetting = function(_, key, def)
            if key == "dict_auto_add_vocab" then return auto_add_vocab end
            if key == "minimalist_mode" then return false end
            if key == "auto_save_to_notebook" then return false end
            if key == "use_websearch" then return "none" end
            return def
        end,
    }

    local ui = {
        doc_settings = true,
        dictionary = { dict_window = nil },
        -- No getSelectedWordContext, so the excerpt context stays empty.
        highlight = { clear = function() end, onClose = function() end },
        document = {
            getProps = function() return { title = "The Hobbit", authors = "Tolkien" } end,
        },
        handleEvent = function(_, ev)
            log[#log + 1] = "event:" .. tostring(ev and ev.handler)
            events[#events + 1] = ev
            -- The dialog this event opens must land on top of the result
            -- window, so the window has to be up by the time the event fires.
            for i = #shown, 1, -1 do
                if getmetatable(shown[i]) == ResultViewer then
                    current.viewer_up_at_event = UIManager:isWidgetShown(shown[i])
                    break
                end
            end
        end,
    }

    local assistant = {
        settings = settings,
        config = {
            getFeature = function() return nil end,
            getActiveProviderId = function() return "test-provider" end,
        },
        ui = ui,
        ui_language = "en",
        ui_language_is_rtl = false,
        showProviderDialog = function() end,
        assistant_dialog = { runPrompt = function() end },
        querier = {
            provider_name = "test-provider",
            is_inited = function() return true end,
            load_model = function() return true end,
            query = function() return ANSWER, nil end,
            showError = function(_, err) error("unexpected query error: " .. tostring(err)) end,
        },
    }
    return assistant
end

-- ── Helpers ──
local function shown_viewers(rec)
    local viewers = {}
    for i = 1, #rec.shown do
        if getmetatable(rec.shown[i]) == ResultViewer then
            viewers[#viewers + 1] = rec.shown[i]
        end
    end
    return viewers
end

local function messages(rec)
    local n = 0
    for i = 1, #rec.log do
        if rec.log[i] == "show:message" then n = n + 1 end
    end
    return n
end

-- Every button label the viewer actually built, action row included.
local function button_labels(viewer)
    local labels = {}
    local rows = viewer.button_table and viewer.button_table.buttons or {}
    for i = 1, #rows do
        for j = 1, #rows[i] do
            local btn = rows[i][j]
            if type(btn) == "table" and btn.text then
                labels[#labels + 1] = btn
            end
        end
    end
    return labels
end

local function find_button(viewer, text)
    for _, btn in ipairs(button_labels(viewer)) do
        if btn.text == text then return btn end
    end
    return nil
end

-- The real production entry point, with the same arguments a caller uses for
-- the plain dictionary (no prompt_type, so the dict branch is taken).
local function look_up(auto_add_vocab, word)
    local assistant = make_assistant(auto_add_vocab)
    showDictionaryDialog(assistant, word or "Smaug")
    return current
end

local function cleanup(rec)
    for _, viewer in ipairs(shown_viewers(rec)) do
        if UIManager:isWidgetShown(viewer) then UIManager:close(viewer) end
    end
end

local function position_of(rec, entry)
    for i = 1, #rec.log do
        if rec.log[i] == entry then return i end
    end
    return nil
end

print("\n== dict_vocab_autoadd ==")

-- 1. Switch off: the window opens and nothing is added behind the reader's
--    back; the button is the only way in.
do
    local rec = look_up(false)
    local viewers = shown_viewers(rec)
    eq("switch off: the result window opened", #viewers, 1)
    eq("switch off: no WordLookedUp event fired", #rec.events, 0)
    UIManager:forceRePaint()

    local btn = viewers[1] and find_button(viewers[1], _("Vocabulary Builder"))
    check("switch off: the Vocabulary Builder button is in the action row", btn ~= nil)

    -- The button must go through the same shared add, so prove it by using it.
    if btn and btn.callback then
        btn.callback()
        eq("the button fires exactly one WordLookedUp event", #rec.events, 1)
        eq("the button passes is_manual = true", rec.events[1].args[3], true)
        eq("the button reports the success", messages(rec), 1)
    else
        check("the button fires exactly one WordLookedUp event", false,
            "no Vocabulary Builder callback to press")
        check("the button passes is_manual = true", false, "no callback")
        check("the button reports the success", false, "no callback")
    end
    cleanup(rec)
end

-- 2. Switch on: the add fires itself, silently, and only after the show.
do
    local rec = look_up(true)
    local viewers = shown_viewers(rec)
    eq("switch on: the result window opened", #viewers, 1)
    eq("switch on: exactly one WordLookedUp event fired", #rec.events, 1)

    local ev = rec.events[1]
    if ev then
        -- is_manual = true, or the Vocabulary Builder's own capture-while-
        -- reading setting vetoes an add the user already opted into.
        eq("switch on: the event carries the looked-up word", ev.args[1], "Smaug")
        eq("switch on: the event passes is_manual = true", ev.args[3], true)
    end

    local show_at = position_of(rec, "show:viewer")
    local event_at = position_of(rec, "event:onWordLookedUp")
    check("switch on: the show is logged before the event", show_at ~= nil and event_at ~= nil
        and show_at < event_at,
        string.format("show at %s, event at %s", tostring(show_at), tostring(event_at)))
    eq("switch on: the result window was already up when the event fired",
        rec.viewer_up_at_event, true)

    -- The add is silent: a confirmation on top of the result window would be
    -- the first thing the reader sees.
    eq("switch on: the success notification is suppressed", messages(rec), 0)

    UIManager:forceRePaint()
    check("switch on: no Vocabulary Builder button, nothing left to press",
        viewers[1] and find_button(viewers[1], _("Vocabulary Builder")) == nil)
    cleanup(rec)
end

print(string.format("\ndict_vocab_autoadd: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
