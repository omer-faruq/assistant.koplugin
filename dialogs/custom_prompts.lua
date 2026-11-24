--[[--
Settings -> Custom Prompts: create, edit and delete prompts from the UI.

Prompts are stored by `PromptRegistry` and show up in the highlight menu and
the Ask dialog like prompts defined in configuration.lua.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Notification = require("ui/widget/notification")
local koutil = require("util")
local _ = require("core/gettext")
local T = require("ffi/util").template
local PromptRegistry = require("core/prompt_registry")

local M = {}

local function menuKey(id, prompt)
    return string.format("assistant_%02d_%s", prompt.order or 1000, id)
end

--- Rebuild the highlight-menu buttons after a prompt changed. A deleted or
--- renamed prompt first loses its old button.
---@param assistant table plugin instance
---@param id string|nil prompt whose current button must be dropped first
---@param prompt table|nil that prompt's record (for its menu key)
local function refreshHighlightMenu(assistant, id, prompt)
    if not assistant.ui.document then return end
    if id and prompt then
        assistant.ui.highlight:removeFromHighlightDialog(menuKey(id, prompt))
    end
    require("core/hooks").rebuildShowOnMainButtons(assistant)
end

--- Two-step editor: name, then prompt text.
---@param assistant table plugin instance
---@param id string|nil prompt ID when editing, nil for a new prompt
---@param on_saved function called after the prompt is stored
local function showEditor(assistant, id, on_saved)
    local data = assistant._ui_prompt_data
    local existing = id and data.prompts[id] or nil
    local name_dialog, prompt_dialog

    local function showPromptDialog(name)
        prompt_dialog = InputDialog:new{
            title = _("Prompt Text"),
            input = existing and existing.user_prompt or "",
            input_hint = _("e.g. Explain this passage in simple words"),
            description = _("The selected text is added automatically. Optional placeholders: {highlight} {title} {author} {language} {progress} {chapter} {user_input}"),
            allow_newline = true,
            buttons = {{
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(prompt_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local text = prompt_dialog:getInputText()
                        local ok, err
                        if id then
                            ok, err = PromptRegistry.updatePrompt(assistant, id, { text = name, user_prompt = text })
                        else
                            ok, err = PromptRegistry.installPrompt(assistant, name, text)
                        end
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = err })
                            return
                        end
                        UIManager:close(prompt_dialog)
                        refreshHighlightMenu(assistant, id, existing)
                        Notification:notify(_("Prompt saved."), Notification.SOURCE_ALWAYS_SHOW)
                        on_saved()
                    end,
                },
            }},
        }
        UIManager:show(prompt_dialog)
        prompt_dialog:onShowKeyboard()
    end

    name_dialog = InputDialog:new{
        title = existing and _("Edit Custom Prompt") or _("Add Custom Prompt"),
        input = existing and existing.text or "",
        input_hint = _("Prompt name (shown on the button)"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(name_dialog)
                end,
            },
            {
                text = _("Next"),
                is_enter_default = true,
                callback = function()
                    local name = koutil.trim(name_dialog:getInputText())
                    if name == "" then
                        UIManager:show(InfoMessage:new{ text = _("Prompt name is required.") })
                        return
                    end
                    UIManager:close(name_dialog)
                    showPromptDialog(name)
                end,
            },
        }},
    }
    UIManager:show(name_dialog)
    name_dialog:onShowKeyboard()
end

--- Actions for one stored prompt.
---@param assistant table plugin instance
---@param id string prompt ID
---@param on_changed function called after the prompt changed
local function showPromptActions(assistant, id, on_changed)
    local prompt = assistant._ui_prompt_data.prompts[id]
    if not prompt then return end
    local with_context = prompt.use_book_context == true
    local dialog

    dialog = ButtonDialog:new{
        title = prompt.text,
        buttons = {
            {{
                text = _("Edit"),
                callback = function()
                    UIManager:close(dialog)
                    showEditor(assistant, id, on_changed)
                end,
            }},
            {{
                text = with_context and _("Send Book Context: On") or _("Send Book Context: Off"),
                callback = function()
                    UIManager:close(dialog)
                    PromptRegistry.updatePrompt(assistant, id, {
                        text = prompt.text,
                        user_prompt = prompt.user_prompt,
                        use_book_context = not with_context,
                    })
                    on_changed()
                end,
            }},
            {{
                text = _("Delete"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete the custom prompt [%1]?"), prompt.text),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            PromptRegistry.deletePrompt(assistant, id)
                            refreshHighlightMenu(assistant, id, prompt)
                            on_changed()
                        end,
                    })
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

--- Fill `items` in place so an open TouchMenu keeps pointing at the same table.
---@param assistant table plugin instance
---@param items table menu item list to (re)fill
---@param menu table { instance = TouchMenu|nil } the menu to repaint
local function fillItems(assistant, items, menu)
    for i = #items, 1, -1 do items[i] = nil end

    local function refresh()
        fillItems(assistant, items, menu)
        if menu.instance then menu.instance:updateItems() end
    end

    table.insert(items, {
        text = _("Add Custom Prompt"),
        keep_menu_open = true,
        separator = true,
        callback = function(touchmenu_instance)
            menu.instance = touchmenu_instance
            showEditor(assistant, nil, refresh)
        end,
    })

    local data = assistant._ui_prompt_data
    local ids = PromptRegistry.sortedIds(data)
    if #ids == 0 then
        table.insert(items, { text = _("No custom prompts yet"), enabled = false })
    end
    for i, id in ipairs(ids) do
        local prompt = data.prompts[id]
        table.insert(items, {
            text = prompt.text,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                menu.instance = touchmenu_instance
                showPromptActions(assistant, id, refresh)
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{ text = prompt.user_prompt })
            end,
        })
    end
end

--- Menu item for Settings -> Custom Prompts.
---@param assistant table plugin instance
---@return table menu item spec
function M.getMenuItem(assistant)
    return {
        text = _("Custom Prompts"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local items = {}
            fillItems(assistant, items, {})
            return items
        end,
    }
end

return M
