local json = require("rapidjson")
local _ = require("core/gettext")
local T = require("ffi/util").template

local M = {}
local MAX_CARDS = 50

local function trim(value)
    value = value:gsub("^%s+", "")
    value = value:gsub("%s+$", "")
    return value
end

local function normalizeCards(cards)
    if type(cards) ~= "table" or #cards == 0 then
        return nil, _("The AI response did not contain any flashcards.")
    end
    if #cards > MAX_CARDS then
        return nil, _("The AI response contained too many flashcards.")
    end

    local normalized = {}
    for index, card in ipairs(cards) do
        if type(card) ~= "table" then
            return nil, T(_("Flashcard %1 is not a valid question-and-answer card."), index)
        end
        if type(card.question) ~= "string" or type(card.answer) ~= "string" then
            return nil, T(_("Flashcard %1 is missing a question or answer."), index)
        end

        local question = trim(card.question)
        local answer = trim(card.answer)
        if question == "" or answer == "" then
            return nil, T(_("Flashcard %1 is missing a question or answer."), index)
        end

        normalized[#normalized + 1] = {
            question = question,
            answer = answer,
        }
    end

    return normalized
end

--- Decode and validate the JSON object returned by the flashcard prompt.
---@param response string|nil Model response
---@return table|nil cards
---@return string|nil err
function M.parseResponse(response)
    if type(response) ~= "string" or trim(response) == "" then
        return nil, _("The AI response did not contain valid flashcard data.")
    end

    local candidate = trim(response)
    candidate = candidate:gsub("^```[Jj][Ss][Oo][Nn]?%s*", "")
    candidate = candidate:gsub("%s*```$", "")

    local ok, decoded = pcall(json.decode, candidate)
    if not ok or type(decoded) ~= "table" then
        local first_brace = candidate:find("{", 1, true)
        local last_brace = candidate:match(".*()}")
        if first_brace and last_brace and last_brace >= first_brace then
            ok, decoded = pcall(json.decode, candidate:sub(first_brace, last_brace))
        end
    end
    if not ok or type(decoded) ~= "table" or type(decoded.cards) ~= "table" then
        return nil, _("The AI response contained invalid flashcard JSON.")
    end

    return normalizeCards(decoded.cards)
end

local function tsvCell(value)
    value = value:gsub("\r\n", " ")
    value = value:gsub("[\r\n\t]", " ")
    return trim(value)
end

--- Build Anki's two-field, tab-separated import data without a header row.
---@param cards table[] Question-and-answer cards
---@return string|nil tsv
---@return string|nil err
function M.buildTSV(cards)
    local normalized, err = normalizeCards(cards)
    if not normalized then
        return nil, err
    end

    local rows = {}
    for index, card in ipairs(normalized) do
        rows[index] = tsvCell(card.question) .. "\t" .. tsvCell(card.answer)
    end
    return table.concat(rows, "\n") .. "\n"
end

--- Write a uniquely named TSV file to the configured AI Notes folder.
---@param assistant table Assistant instance
---@param cards table[] Question-and-answer cards
---@return string|nil path
---@return string|nil err
function M.exportToAnkiDroid(assistant, cards)
    local content, err = M.buildTSV(cards)
    if not content then
        return nil, err
    end

    local Notebook = require("feature/notebook")
    local ASUtils = require("utils/base")
    local lfs = require("libs/libkoreader-lfs")
    local folder, folder_err, folder_warning = Notebook.getFolder(assistant, true)
    if not folder then
        return nil, folder_err or folder_warning or _("No folder is available for the flashcard export.")
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local path
    for suffix = 0, 99 do
        local extra = suffix == 0 and "" or "-" .. suffix
        local filename = "assistant-flashcards-" .. timestamp .. extra .. ".tsv"
        path = ASUtils.joinPath(folder, filename)
        if not lfs.attributes(path) then
            break
        end
    end
    if lfs.attributes(path) then
        return nil, _("Could not choose a unique filename for the flashcard export.")
    end

    local file, open_err = io.open(path, "wb")
    if not file then
        return nil, T(_("Could not create the TSV file: %1"), tostring(open_err))
    end

    local write_ok, write_err = file:write(content)
    local close_ok, close_err = file:close()
    if not write_ok or not close_ok then
        os.remove(path)
        return nil, T(_("Could not finish writing the TSV file: %1"), tostring(write_err or close_err))
    end

    return path, nil, folder_warning
end

local function showInfo(UIManager, InfoMessage, text, warning)
    UIManager:show(InfoMessage:new{
        text = text,
        icon = warning and "notice-warning" or nil,
    })
end

--- Show generated cards with per-card editing/removal and AnkiDroid export.
---@param assistant table Assistant instance
---@param response string|nil Model response
function M.showPreview(assistant, response)
    local cards, parse_err = M.parseResponse(response)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    if not cards then
        showInfo(UIManager, InfoMessage, parse_err, true)
        return
    end

    local Menu = require("ui/widget/menu")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local DocUtils = require("utils/doc")
    local open_preview

    local function open_editor(card_index, preview_menu)
        local card = cards[card_index]
        local dialog
        dialog = MultiInputDialog:new{
            title = T(_("Edit Card %1"), card_index),
            fields = {
                {
                    description = _("Question"),
                    hint = _("Write a question"),
                    text = card.question,
                },
                {
                    description = _("Answer"),
                    hint = _("Write an answer"),
                    text = card.answer,
                },
            },
            buttons = {{
                {
                    id = "cancel",
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    id = "remove",
                    text = _("Remove"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Remove Card %1?"), card_index),
                            ok_text = _("Remove"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                UIManager:close(dialog)
                                UIManager:close(preview_menu)
                                table.remove(cards, card_index)
                                open_preview()
                            end,
                        })
                    end,
                },
                {
                    id = "save",
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = DocUtils.trimDialogFields(dialog)
                        if fields[1] == "" or fields[2] == "" then
                            showInfo(UIManager, InfoMessage, _("Both Question and Answer are required."), true)
                            return
                        end

                        cards[card_index] = {
                            question = fields[1],
                            answer = fields[2],
                        }
                        UIManager:close(dialog)
                        UIManager:close(preview_menu)
                        open_preview()
                    end,
                },
            }},
        }
        UIManager:show(dialog)
    end

    open_preview = function()
        local menu
        local items = {}
        if #cards == 0 then
            items[1] = {
                text = _("No cards remain. Close this preview."),
                enabled = false,
            }
        else
            items[#items + 1] = {
                text = _("Export to AnkiDroid"),
                callback = function()
                    UIManager:close(menu)
                    local path, export_err, export_warning = M.exportToAnkiDroid(assistant, cards)
                    if not path then
                        showInfo(UIManager, InfoMessage, export_err, true)
                        return
                    end

                    local Notification = require("ui/widget/notification")
                    Notification:notify(
                        T(_("Flashcards exported to %1"), path),
                        Notification.SOURCE_ALWAYS_SHOW
                    )
                    local instructions = T(
                        _("To import in AnkiDroid, select the TSV file at:\n%1\n\nSet the separator to Tab, choose the Basic note type, map field 1 to Front and field 2 to Back, then choose a deck and import. The file has no header row; each row is one card."),
                        path
                    )
                    if export_warning then
                        instructions = export_warning .. "\n\n" .. instructions
                    end
                    showInfo(UIManager, InfoMessage, instructions)
                end,
            }

            for card_index, card in ipairs(cards) do
                local index = card_index
                items[#items + 1] = {
                    text = T(_("Card %1\nQuestion: %2\nAnswer: %3"),
                        index, card.question, card.answer),
                    callback = function()
                        open_editor(index, menu)
                    end,
                }
            end
        end

        menu = Menu:new{
            title = _("Flashcards"),
            subtitle = _("Tap a card to edit or remove it."),
            item_table = items,
        }
        UIManager:show(menu)
    end

    open_preview()
end

return M
