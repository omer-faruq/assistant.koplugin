--- Annotation saving shared by the viewer's Annotate button and the
--- Translate-as-Annotation setting.
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Event = require("ui/event")
local TextUtils = require("utils/text")
local _ = require("core/gettext")

local M = {}

local function warn(text)
    UIManager:show(InfoMessage:new{
        icon = "notice-warning",
        text = text,
        timeout = 2
    })
end

--- Attach note_text as the note of a new highlight for the current
--- selection. Failures show their own InfoMessage; the caller owns the
--- success UI.
---@param ui table ReaderUI-like: needs ui.highlight:saveHighlight,
---       ui.annotation.annotations and ui:handleEvent
---@param note_text string note body; whitespace-only is rejected
---@return boolean true when the highlight and its note were saved
function M.add_note(ui, note_text)
    if not (ui and ui.highlight) then
        warn(_("Highlight functionality not available"))
        return false
    end

    if type(note_text) ~= "string" then note_text = "" end
    note_text = note_text:gsub("^%s+", ""):gsub("%s+$", "")
    if note_text == "" then
        warn(_("No text left to annotate"))
        return false
    end

    local index = ui.highlight:saveHighlight(true)
    local a = index and ui.annotation and ui.annotation.annotations[index]
    if not a then
        warn(_("No highlight to annotate"))
        return false
    end
    a.note = note_text
    ui:handleEvent(Event:new("AnnotationsModified",
        { a, nb_highlights_added = -1, nb_notes_added = 1 }))
    return true
end

--- Save the last assistant turn, rendered answer-only, as the note of a
--- fresh highlight - the Translate-as-Annotation flow.
---@param ui table ReaderUI-like, as add_note
---@param message_history table[] conversation history; the last message
---       is the answer to save
---@return boolean false when there is no answer to save or the save failed;
---        the caller then shows the result window
---@return string|nil note_text when the save succeeded, so the caller can
---        show exactly what was saved
function M.auto_save_translation(ui, message_history)
    local last = message_history and message_history[#message_history]
    if type(last) ~= "table" or last.role ~= "assistant" then
        return false
    end
    local note_text = TextUtils.formatAnswerOnly(last, {})
    note_text = note_text:gsub("^%s+", ""):gsub("%s+$", "")
    if not M.add_note(ui, note_text) then return false end
    return true, note_text
end

return M
