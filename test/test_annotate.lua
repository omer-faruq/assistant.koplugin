-- test_annotate.lua
-- Guards feature/annotate.lua: the shared highlight+note save behind the
-- viewer's Annotate button and the Auto-Annotate Translations setting.
--   * add_note: success shape (trimmed note, AnnotationsModified payload)
--     and every failure branch (no ui, empty note, save rejected).
--   * auto_save_translation: the note is the answer alone - no bubble
--     markup, no reasoning fence, no follow-up suggestions - and turns
--     without an assistant answer are not saved at all.
-- The dialog-side gate (prompt_id, the settings key, the origin flag)
-- sits in AssistantDialog:runPrompt behind the querier and is not
-- reachable headlessly: requiring dialogs/dialog pulls widget modules
-- the harness does not stub (verticalspan et al.), and bridging that
-- chain would outweigh the eight declarative lines it guards. The
-- static section below pins the gate's wiring facts instead: both the
-- toggle and the gate must use the same settings key, the gate must
-- default off, and only the built-in 'Translate' override may pass
-- the origin flag - the Assistant's own translate buttons keep the
-- result window.
local helper = require("test.helper")
local assert = helper.assert
local Annotate = require("feature/annotate")

-- Shared-process discipline: capture the stubbed UIManager's shows to
-- observe the warning InfoMessages, restore on cleanup.
local UIManager = require("ui/uimanager")
local real_show = UIManager.show
local shown_texts = {}
UIManager.show = function(_, widget)
    shown_texts[#shown_texts + 1] = widget and widget.text or nil
end
local function last_warning()
    return shown_texts[#shown_texts]
end
local function reset()
    shown_texts = {}
end

-- The harness stubs ui/event with a field-less new(); model the real
-- event shape (onName handler + args) so the AnnotationsModified payload
-- can be identified. Restored together with UIManager.show below.
local Event = require("ui/event")
local real_event_new = Event.new
Event.new = function(_, name, ...)
    return { handler = "on" .. name, args = { ... } }
end

local function make_ui()
    return {
        highlight = { saveHighlight = function() return 1 end },
        annotation = { annotations = { {} } },
        handleEvent = function() end,
    }
end

-- handleEvent recorder wrapping a ui table; records the modeled events.
local function record_events(ui)
    local events = {}
    ui.handleEvent = function(_, event)
        events[#events + 1] = event
    end
    return events
end

local function make_history(answer)
    return {
        { role = "system", content = "system prompt" },
        { role = "user", content = "translate this" },
        { role = "assistant", content = answer },
    }
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("add_note: saves a trimmed note and fires AnnotationsModified", function()
        reset()
        local ui = make_ui()
        local events = record_events(ui)
        assert.isTrue(Annotate.add_note(ui, "  \nThe Ring was forged. \n"),
            "successful save must return true")
        assert.equal(ui.annotation.annotations[1].note, "The Ring was forged.",
            "the note must be the trimmed text")
        assert.equal(#events, 1, "exactly one event must be fired")
        local payload = events[1].args[1]
        assert.equal(events[1].handler, "onAnnotationsModified",
            "the AnnotationsModified event must be fired")
        assert.equal(payload[1], ui.annotation.annotations[1],
            "the event payload must carry the annotation")
        assert.equal(payload.nb_highlights_added, -1,
            "the highlight count delta must be -1")
        assert.equal(payload.nb_notes_added, 1,
            "the note count delta must be 1")
    end),

    test("add_note: rejects a ui without a highlight module", function()
        reset()
        assert.isFalse(Annotate.add_note(nil, "note"))
        assert.matches(last_warning(), "Highlight functionality not available")
    end),

    test("add_note: rejects an empty note", function()
        reset()
        assert.isFalse(Annotate.add_note(make_ui(), "  \n\t "))
        assert.matches(last_warning(), "No text left to annotate")
    end),

    test("add_note: rejects a note that is not a string", function()
        reset()
        assert.isFalse(Annotate.add_note(make_ui(), nil))
        assert.matches(last_warning(), "No text left to annotate")
    end),

    test("add_note: falls back when saveHighlight refuses", function()
        reset()
        local ui = make_ui()
        ui.highlight.saveHighlight = function() return nil end
        assert.isFalse(Annotate.add_note(ui, "note"))
        assert.matches(last_warning(), "No highlight to annotate")
        assert.equal(ui.annotation.annotations[1].note, nil,
            "no note must be written on failure")
    end),

    test("add_note: falls back when the annotation lookup fails", function()
        reset()
        local ui = make_ui()
        ui.highlight.saveHighlight = function() return 9 end
        assert.isFalse(Annotate.add_note(ui, "note"))
        assert.matches(last_warning(), "No highlight to annotate")
    end),

    test("auto_save: the note is the answer alone, without chrome", function()
        reset()
        local ui = make_ui()
        local events = record_events(ui)
        local answer = "```reasoning\nthink think\n```\n\nThe Ring was forged in Mount Doom.\n\n<suggestions>\n- q1\n</suggestions>"
        assert.isTrue(Annotate.auto_save_translation(ui, make_history(answer)))
        assert.equal(ui.annotation.annotations[1].note, "The Ring was forged in Mount Doom.",
            "the note must carry only the answer body")
        assert.equal(#events, 1, "the save must fire its event")
    end),

    test("auto_save: markdown of the answer survives untouched", function()
        reset()
        local ui = make_ui()
        local answer = "**Forged** in *Mount Doom*.\n\n- to rule them all"
        assert.isTrue(Annotate.auto_save_translation(ui, make_history(answer)))
        assert.equal(ui.annotation.annotations[1].note, answer,
            "answer markdown is the note as-is")
    end),

    test("auto_save: a history without an assistant answer saves nothing", function()
        reset()
        local ui = make_ui()
        local refused = false
        ui.highlight.saveHighlight = function() refused = true end
        local history = {
            { role = "system", content = "system" },
            { role = "user", content = "translate this" },
        }
        assert.isFalse(Annotate.auto_save_translation(ui, history))
        assert.isFalse(refused, "no highlight may be attempted without an answer")
        assert.equal(ui.annotation.annotations[1].note, nil)
    end),

    test("auto_save: an empty answer is rejected as a note", function()
        reset()
        local ui = make_ui()
        assert.isFalse(Annotate.auto_save_translation(ui, make_history("  ")))
        assert.matches(last_warning(), "No text left to annotate")
    end),

    test("auto_save: a nil history is not saved", function()
        reset()
        assert.isFalse(Annotate.auto_save_translation(make_ui(), nil))
    end),
}

local result = helper.runTests("annotate", tests)

-- Static guard for the runPrompt gate: unreachable headlessly (see the
-- file header), so pin its wiring facts in the shipped sources instead.
local project_root = debug.getinfo(1).source:match("@(.*/)test/")
local function read(path)
    local f = io.open(project_root .. path, "r")
    assert.notNil(f, "could not read " .. path)
    local src = f:read("*a")
    f:close()
    return src
end

local gate = read("dialogs/dialog.lua")
local menu = read("dialogs/settings_menu.lua")
assert.matches(gate, 'readSetting%(%"auto_annotate_translation%"%, false%)',
    "the runPrompt gate must read the key with a false default")
assert.matches(menu, 'readSetting%(%"auto_annotate_translation%"%, false%)',
    "the settings toggle must use the same key, defaulting off")
assert.matches(gate, 'prompt_id == "translate"',
    "only translate turns may be auto-annotated")
assert.matches(gate, "and auto_annotate",
    "the gate must require the origin flag, so the Assistant's own translate buttons keep the result window")
assert.matches(gate, "highlight:onClose%(%)",
    "a successful auto-save must close the highlight menu and clear the selection")
assert.matches(read("core/hooks.lua"), "showTranslateOrDictionary%(assistant, text, true%)",
    "only the built-in 'Translate' override passes the origin flag")

-- The toggle is a sub-switch of the override: it sits directly under it
-- and is usable only while the override is on.
local override_pos = menu:find([=[text = _("Use AI Assistant for 'Translate'")]=], 1, true)
local toggle_pos = menu:find([=[text = _("'Translate' as Annotation")]=], 1, true)
local smart_pos = menu:find([=[text = _("Smart Dictionary Lookup for 'Translate'")]=], 1, true)
assert.notNil(override_pos, "the override item must exist")
assert.notNil(toggle_pos, "the annotation toggle must exist")
assert.isTrue(override_pos < toggle_pos,
    "the annotation toggle sits below the override")
assert.isTrue(toggle_pos < (smart_pos or math.huge),
    "the annotation toggle sits above the Smart Dictionary item")
assert.matches(menu, 'enabled_func = function %(%) return assistant%.settings:readSetting%(%"ai_translate_override%"%, false%)',
    "the annotation toggle is usable only while the override is on")

-- Shared-process cleanup: put the harness stubs back.
UIManager.show = real_show
Event.new = real_event_new
return result
