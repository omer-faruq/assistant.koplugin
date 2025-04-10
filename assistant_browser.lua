local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage") -- Used for paths
local LuaSettings = require("luasettings") -- Used for reading/writing settings
local ChatGPTViewer = require("chatgptviewer") -- To show the selected conversation
local ConfirmBox = require("ui/widget/confirmbox") -- For delete confirmation
local InfoMessage = require("ui/widget/infomessage") -- For feedback messages
local _ = require("gettext")
local logger = require("logger")

local AssistantBrowser = Menu:extend{
    no_title = false,
    is_borderless = true,
    is_popout = false,
    parent = nil,
    title = _("Conversation History"), -- Title reflects content
    covers_full_screen = true,
    return_arrow_propagation = false,
}

function AssistantBrowser:init()
    Menu.init(self)
    -- History is now loaded in onShow to ensure it's always up-to-date
end

function AssistantBrowser:loadHistory()
    local conversation_store_path = nil
    local history = {}

    -- Safely get settings directory
    if DataStorage and type(DataStorage.getSettingsDir) == "function" then
        local ok, path_or_err = pcall(DataStorage.getSettingsDir, DataStorage)
        if ok then
            conversation_store_path = path_or_err .. "/assistant_conversations.lua"
        else
            if logger then logger.error("AssistantBrowser: Failed to get settings dir:", path_or_err) end
        end
    else
        if logger then logger.error("AssistantBrowser: DataStorage or getSettingsDir not available") end
    end

    -- Safely read history file using LuaSettings
    if conversation_store_path then
        local settings_store = LuaSettings:open(conversation_store_path)
        local loaded_history = settings_store:readSetting("conversations") -- Key used in chatgptviewer
        if type(loaded_history) == "table" then
            history = loaded_history
        else
            if logger then logger.info("AssistantBrowser: No history found or invalid format in:", conversation_store_path) end
        end
    end

    local items = {}
    if #history > 0 then
        for i, entry in ipairs(history) do
            -- Title: Use AI-generated topic or fallback to timestamp
            local item_title = entry.topic or os.date("%Y-%m-%d %H:%M", entry.save_timestamp or entry.created_timestamp or os.time())
            -- Limit title length visually if needed (Menu might handle this)
            -- if #item_title > 40 then item_title = item_title:sub(1, 40) .. "..." end

            table.insert(items, {
                text = item_title,
                -- Remove subtitle related fields
                -- sub_text_font_face = "smallfont",
                -- sub_text = subtitle,
                callback = function()
                    -- Show the selected conversation in ChatGPTViewer
                    local viewer = ChatGPTViewer:new{
                        ui = self.ui,
                        title = item_title,
                        message_history = entry.message_history,
                        highlighted_text = entry.highlighted_text,
                        created_timestamp = entry.created_timestamp,
                        save_timestamp = entry.save_timestamp,
                        original_entry = entry, -- Pass the complete entry for reference
                        is_saved = true -- Mark as saved since it's loaded from history
                    }
                    UIManager:show(viewer)
                end,
                hold_callback = function()
                    self:deleteEntry(entry)
                end,
                original_entry = entry -- Store entry data for deletion
            })
        end
    else
        table.insert(items, { text = _("No conversations saved yet."), is_label = true })
    end

    self:switchItemTable(self.title, items) -- Use switchItemTable instead of setItems
end

function AssistantBrowser:onShow()
    self:loadHistory() -- Reload history every time the browser is shown
end

-- Handle back gesture/button
function AssistantBrowser:onReturn()
    UIManager:close(self)
    return true -- Event handled
end

function AssistantBrowser:deleteEntry(entry_to_delete)
    local confirm_box = ConfirmBox:new{
        text = _("Delete this conversation?"),
        ok_text = _("Delete"),
        ok_callback = function()
            -- Get settings path
            local settings_dir = DataStorage:getSettingsDir()
            if not settings_dir then
                if logger then logger.error("AssistantBrowser:deleteEntry: Could not get settings directory") end
                UIManager:show(InfoMessage:new{ text = _("Error: Could not get settings directory."), timeout = 3 })
                return
            end
            local conversation_store_path = settings_dir .. "/assistant_conversations.lua"
            local settings_store = LuaSettings:open(conversation_store_path)
            local history = settings_store:readSetting("conversations") or {}

            -- Find and remove the entry
            local found_index = nil
            for i, entry in ipairs(history) do
                if entry.created_timestamp == entry_to_delete.created_timestamp then
                    found_index = i
                    break
                end
            end

            if found_index then
                table.remove(history, found_index)
                local ok, err = pcall(function()
                    settings_store:saveSetting("conversations", history)
                    settings_store:flush()
                end)
                if ok then
                    UIManager:show(InfoMessage:new{ text = _("Conversation deleted"), timeout = 2 })
                    UIManager:close(self) -- Close the current browser
                    -- Schedule opening a new browser instance slightly later
                    UIManager:scheduleIn(0.2, function() -- Increased delay slightly
                        local AssistantBrowser = require("assistant_browser") -- Require locally
                        UIManager:show(AssistantBrowser:new{})
                    end)
                else
                    if logger then logger.error("AssistantBrowser:deleteEntry: Failed to save updated history:", err) end
                    UIManager:show(InfoMessage:new{ text = _("Error deleting conversation"), timeout = 2 })
                end
            else
                if logger then logger.warn("AssistantBrowser:deleteEntry: Entry not found in history file.") end
                UIManager:show(InfoMessage:new{ text = _("Error: Conversation not found"), timeout = 2 })
            end
        end,
    }
    UIManager:show(confirm_box)
end

return AssistantBrowser