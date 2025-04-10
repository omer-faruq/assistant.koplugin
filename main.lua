-- Determine plugin directory and adjust package.path
local script_path = debug.getinfo(1, "S").source
local plugin_dir = ""
if script_path and script_path:sub(1,1) == "@" then
    script_path = script_path:sub(2) -- Remove leading '@'
    plugin_dir = script_path:match("(.*/)") or "./" -- Extract directory, fallback to current
else
    -- Fallback if script path is not available (e.g., interactive mode)
    print("Warning: Could not reliably determine plugin script path. Assuming current directory.")
    plugin_dir = "./"
end

-- Add plugin directory and known subdirectories to package.path
-- This ensures modules are found regardless of the current working directory
package.path = package.path ..
               ";" .. plugin_dir .. "?.lua" ..
               ";" .. plugin_dir .. "?/init.lua" ..
               ";" .. plugin_dir .. "api_handlers/?.lua" ..
               ";" .. plugin_dir .. "ui/widget/container/?.lua" ..
               ";" .. plugin_dir .. "ui/widget/?.lua" ..
               ";" .. plugin_dir .. "ui/network/?.lua" ..
               ";" .. plugin_dir .. "ui/?.lua"

-- Now load modules, they should be found via the updated package.path
local logger = require("logger") -- Moved to top
local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")
local DataStorage = require("datastorage") -- Move require to top
local LuaSettings = require("luasettings") -- Add LuaSettings require
local UIManager = require("ui/uimanager") -- Move require to top
local InfoMessage = require("ui/widget/infomessage") -- Move require to top
local AssistantBrowser = require("assistant_browser") -- Move require to top

local Dialogs = require("dialogs") -- Load the exported table M
local UpdateChecker = require("update_checker")

local Assistant = InputContainer:new {
  name = "Assistant",
  is_doc_only = false, -- Allow menu item outside documents
}

-- Helper functions for managing assistant settings
local function getAssistantSettings()
    -- Use top-level DataStorage
    local path = DataStorage:getSettingsDir() .. "/assistant_settings.lua"
    local settings_store = LuaSettings:open(path)
    -- readSetting returns nil if key doesn't exist or file doesn't exist
    local settings = settings_store:readSetting("assistant_config") or {}
    if type(settings) == "table" then
        return settings
    end
    return {} -- Return empty table on error or if file doesn't exist
end

local function saveAssistantSettings(settings)
    -- Use global DataStorage loaded at the top
    local path = DataStorage:getSettingsDir() .. "/assistant_settings.lua"
    local settings_store = LuaSettings:open(path)
    local ok, err = pcall(function()
        settings_store:saveSetting("assistant_config", settings)
        settings_store:flush() -- IMPORTANT: Write changes to disk
    end)
    if not ok then
        if logger then logger.error("Failed to save assistant settings using LuaSettings:", err) end
    end
    return ok
end

local function getActiveProvider()
    local settings = getAssistantSettings()
    -- Fallback logic: Settings -> Global Config -> Default
    return settings.active_provider or (CONFIGURATION and CONFIGURATION.provider) or "gemini"
end

local function setActiveProvider(provider_name)
    -- Validate provider_name
    if not provider_name or type(provider_name) ~= "string" then
        UIManager:show(InfoMessage:new{ text = _("Error: Invalid provider name"), timeout = 2 })
        return false
    end

    local settings = getAssistantSettings()
    settings.active_provider = provider_name
    local ok = saveAssistantSettings(settings)
    if ok then
        -- Show feedback only on success
        local display_name = provider_name:gsub("^%l", string.upper)
        UIManager:show(InfoMessage:new{ text = _("Provider set to:") .. " " .. display_name, timeout = 1 })
        -- Menu will close automatically through the standard menu callback chain
    else
        -- Error message is handled within saveAssistantSettings (logs)
        -- Optionally show a generic error message here too
        UIManager:show(InfoMessage:new{ text = _("Error saving provider setting."), timeout = 2 })
    end
    return ok
end

-- Load Configuration
local CONFIGURATION = nil
-- Determine the full path to configuration.lua relative to the plugin directory
-- Try loading configuration using require, fallback to nil
local config_ok_main, config_result_main = pcall(require, "configuration")
if config_ok_main then
    CONFIGURATION = config_result_main
else
    if logger then
        local log_msg = config_result_main
        if type(log_msg) == "table" then log_msg = "(table data omitted for security)" end
        logger.info("Assistant main: configuration.lua not found or error loading via require:", log_msg)
    end
    CONFIGURATION = nil -- Ensure it's nil if loading failed
end

-- Flag to ensure the update message is shown only once per session
  -- Removed old logging block that used non-existent variables
local updateMessageShown = false


function Assistant:init()
    -- Initialization that does NOT require self.ui can go here
    -- For example, setting up non-UI related properties or loading data
    -- NOTE: self.ui might not be available here yet, but Koreader should
    -- still call addToMainMenu when the menu is built.
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        if logger then logger.info("Assistant: Attempting immediate registration to main menu in init.") end
        self.ui.menu:registerToMainMenu(self)
    else
        if logger then logger.warn("Assistant: Could not register immediately in init (self.ui or self.ui.menu not available yet). Relying on Koreader to call addToMainMenu later.") end
        -- No explicit registration needed here if self.ui isn't ready,
        -- Koreader's menu building process should find the addToMainMenu method.
        -- We might need to ensure self is added to a list UIManager checks?
        -- For now, assume standard widget behavior.
    end

end

-- This function is called when the reader UI is ready
function Assistant:onReaderReady(readerui)
  -- Now self.ui should be available (it's typically readerui)
  if not self.ui then
      logger.warn("Assistant: self.ui not available in onReaderReady")
      -- Attempt to assign readerui if self.ui is nil, common pattern
      self.ui = readerui
      if not self.ui then
         logger.error("Assistant: Failed to assign self.ui in onReaderReady")
         return
      end
  end

  -- Assistant button
  self.ui.highlight:addToHighlightDialog("assistant", function(_reader_highlight_instance)
    return {
      text = _("Assistant"),
      enabled = Device:hasClipboard(),
      callback = function() -- Remove instance parameter
        -- _reader_highlight_instance:onClose() -- Removed onClose call
        if not CONFIGURATION then
          local UIManager = require("ui/uimanager")
          local InfoMessage = require("ui/widget/infomessage")
          UIManager:show(InfoMessage:new{
            text = _("Configuration not found. Please set up configuration.lua first.")
          })
          return
        end
        NetworkMgr:runWhenOnline(function()
          if not updateMessageShown then
            UpdateChecker.checkForUpdates()
            updateMessageShown = true
          end
          local Dialogs = require("dialogs") -- Re-require locally
          Dialogs.showChatGPTDialog(self.ui, _reader_highlight_instance.selected_text.text, nil) -- Use table access
        end)
      end,
    }
  end)
  -- Dictionary button
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.dictionary_translate_to and CONFIGURATION.features.show_dictionary_button_in_main_popup then
    self.ui.highlight:addToHighlightDialog("dictionary", function(_reader_highlight_instance)
      local suffix = (CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.ai_button_suffix) or ""
      return {
          text = _("Dictionary") .. suffix,
          enabled = Device:hasClipboard(),
          callback = function() -- Remove instance parameter
              -- _reader_highlight_instance:onClose() -- Removed onClose call
              NetworkMgr:runWhenOnline(function()
                  local showDictionaryDialog = require("dictdialog")
                  showDictionaryDialog(self.ui, _reader_highlight_instance.selected_text.text)
              end)
          end,
      }
    end)
  end

  -- Add Custom buttons (ones with show_on_main_popup = true)
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.prompts then
    local _ = require("gettext")  -- Ensure gettext is available in this scope
    -- Create a sorted list of prompts
    local sorted_prompts = {}
    for prompt_type, prompt in pairs(CONFIGURATION.features.prompts) do
      if prompt.show_on_main_popup then
        table.insert(sorted_prompts, {type = prompt_type, config = prompt})
      end
    end

    -- Sort by order value, default to 1000 if not specified
    table.sort(sorted_prompts, function(a, b)
      local order_a = a.config.order or 1000
      local order_b = b.config.order or 1000
      return order_a < order_b
    end)

    -- Add buttons in sorted order
    for i, prompt_data in ipairs(sorted_prompts) do -- Use 'i' instead of '_'
      local prompt_type = prompt_data.type
      local prompt = prompt_data.config
      -- Use order in the index for proper sorting (pad with zeros for consistent sorting)
      local order_str = string.format("%02d", prompt.order or 1000)
      self.ui.highlight:addToHighlightDialog("assistant_" .. order_str .. "_" .. prompt_type, function(_reader_highlight_instance)
        local suffix = (CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.ai_button_suffix) or ""
        return {
          text = _(prompt.text) .. suffix,
          enabled = Device:hasClipboard(),
          callback = function() -- Remove instance parameter
            -- _reader_highlight_instance:onClose() -- Removed onClose call
            NetworkMgr:runWhenOnline(function()
              local Dialogs = require("dialogs") -- Re-require locally
              Dialogs.showChatGPTDialog(self.ui, _reader_highlight_instance.selected_text.text, prompt_type) -- Use table access
            end)
          end,
        }
      end)
    end
  end
end -- End of Assistant:onReaderReady


-- Function called by UIManager to add items to the main menu
function Assistant:addToMainMenu(menu_items)
    if logger then logger.info("Assistant: addToMainMenu function called.") end
    local _ = require("gettext") -- Load gettext for this scope
    local UIManager = require("ui/uimanager")
    local AssistantBrowser = require("assistant_browser")
    -- Use top-level DataStorage
    local InfoMessage = require("ui/widget/infomessage")
    -- local Separator = require("ui/widget/separator") -- Keep commented out

    -- --- Provider Selection Submenu ---
    local provider_submenu_items = {}
    local assistant_settings_path = nil
    local assistant_settings = {}

    -- Safely get settings path and read settings
    if DataStorage and DataStorage.getSettingsDir then
        local settings_dir = DataStorage:getSettingsDir()
        if settings_dir then
              -- DIAGNOSTIC log removed as we switch to LuaSettings
              assistant_settings_path = settings_dir .. "/assistant_settings.lua"
              local settings_store_menu = LuaSettings:open(assistant_settings_path)
              -- readSetting returns nil if key doesn't exist or file doesn't exist
              local settings_data = settings_store_menu:readSetting("assistant_config") or {}
              local ok = (type(settings_data) == "table") -- Simulate 'ok' status based on successful read
             if ok and type(settings_data) == "table" then assistant_settings = settings_data
             elseif not ok and logger then logger.warn("addToMainMenu: Failed to read assistant settings:", settings_data) end
        elseif logger then logger.warn("addToMainMenu: Could not get settings directory.") end
    elseif logger then logger.warn("addToMainMenu: DataStorage or getSettingsDir not available.") end

    if CONFIGURATION and CONFIGURATION.provider_settings then
        local provider_names = {}
        for name, _ in pairs(CONFIGURATION.provider_settings) do table.insert(provider_names, name) end
        table.sort(provider_names)

        for _, name in ipairs(provider_names) do
            table.insert(provider_submenu_items, {
                text = name:gsub("^%l", string.upper),
                radio = true,
                checked_func = function()
                    -- Use the helper function to get the current provider
                    return name == getActiveProvider()
                end,
                callback = function()
                    -- Use the helper function to set the provider
                    if name ~= getActiveProvider() then
                        local ok = setActiveProvider(name)
                        if ok then
                            -- Use global/upvalue UIManager, InfoMessage, _
                            -- Use global/upvalue UIManager and InfoMessage
                            local display_name = name and name:gsub("^%l", function(c) return string.upper(c) end) or "Unknown"
                            UIManager:show(InfoMessage:new{ text = "Provider set to: " .. display_name, timeout = 1 }) -- Use top-level UIManager/InfoMessage
                            -- Menu closes automatically
                        else
                            -- Use global/upvalue UIManager, InfoMessage, _
                            -- Error message is handled within setActiveProvider's saveAssistantSettings call
                            -- Use global/upvalue UIManager and InfoMessage
                            UIManager:show(InfoMessage:new{ text = "Error saving provider setting.", timeout = 2 }) -- Use top-level UIManager/InfoMessage
                        end
                    end
                end,
                keep_menu_open = false,
            })
        end
    end

    -- --- Build the main Assistant menu ---
    menu_items.assistant = {
        text = _("Assistant"),
        sub_item_table = {
            {
                text = _("Select Provider"),
                sub_item_table = provider_submenu_items, -- Add radio buttons here
                keep_menu_open = true, -- Keep main menu open when entering submenu
            },
            {
                text = _("Conversation History"),
                callback = function()
                    local browser = AssistantBrowser:new{ ui = self.ui } -- Use global AssistantBrowser
                    UIManager:show(browser)
                end,
            },
            {
                text = _("DEBUG: Clear History"),
                callback = function()
                    local ConfirmBox = require("ui/widget/confirmbox") -- Require locally
                    local UIManager = require("ui/uimanager") -- Require locally
                    local InfoMessage = require("ui/widget/infomessage") -- Require locally
                    local DataStorage = require("datastorage") -- Require locally
                    local LuaSettings = require("luasettings") -- Require locally
                    local logger = require("logger") -- Require locally
                    local _ = require("gettext") -- Require locally

                    local confirm_box = ConfirmBox:new{
                        text = _("Delete ALL saved conversations? This cannot be undone."),
                        ok_text = _("Delete All"),
                        ok_callback = function()
                            local settings_dir = DataStorage:getSettingsDir()
                            if not settings_dir then
                                if logger then logger.error("DEBUG Clear History: Could not get settings directory") end
                                UIManager:show(InfoMessage:new{ text = _("Error: Could not get settings directory."), timeout = 3 })
                                return
                            end
                            local conversation_store_path = settings_dir .. "/assistant_conversations.lua"
                            local settings_store = LuaSettings:open(conversation_store_path)
                            
                            local ok, err = pcall(function()
                                settings_store:saveSetting("conversations", {}) -- Save empty table
                                settings_store:flush()
                            end)

                            if ok then
                                UIManager:show(InfoMessage:new{ text = _("All conversations deleted."), timeout = 2 })
                            else
                                if logger then logger.error("DEBUG Clear History: Failed to clear history:", err) end
                                UIManager:show(InfoMessage:new{ text = _("Error clearing history."), timeout = 2 })
                            end
                        end,
                    }
                    UIManager:show(confirm_box)
                end,
            },
        }
    }
end

-- Also register when FileManager UI is ready
function Assistant:onFilemanagerReady(filemanager_ui)
    -- Use filemanager_ui if self.ui is not set yet, or stick to self.ui if already set by reader
    local current_ui = self.ui or filemanager_ui
    if current_ui and current_ui.menu and current_ui.menu.registerToMainMenu then
         if logger then logger.info("Assistant: Attempting to register to main menu in onFilemanagerReady.") end
         current_ui.menu:registerToMainMenu(self)
         -- If reader already set self.ui, we don't need to overwrite it
         if not self.ui then self.ui = filemanager_ui end
    else
        if logger then logger.error("Assistant: Could not register to main menu in onFilemanagerReady.") end
    end
end

function Assistant:onDictButtonsReady(dict_popup, buttons)
    -- Ensure config is loaded before proceeding
    if not CONFIGURATION or not CONFIGURATION.features then return false end -- Return false as event not handled

    if CONFIGURATION.features.replace_default_dictionary_popup then
        -- Prevent default dictionary view (more robustly)
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage") -- Needed for error message
        local lookupword = dict_popup.lookupword -- Store word before closing

        -- Try to close the original popup immediately
        UIManager:close(dict_popup)

        -- Schedule the AI dictionary dialog to open after a very short delay
        UIManager:scheduleIn(0.05, function()
            NetworkMgr:runWhenOnline(function()
                -- Check if dictdialog exists before requiring
                local ok_dict, showDictionaryDialog = pcall(require, "dictdialog")
                if ok_dict then
                    showDictionaryDialog(self.ui, lookupword)
                else
                    if logger then logger.error("onDictButtonsReady: Failed to load dictdialog.lua:", showDictionaryDialog) end
                    UIManager:show(InfoMessage:new{ text = _("Error opening AI Dictionary."), timeout = 2 })
                end
            end)
        end)
        return true -- Indicate we handled the event and potentially stopped propagation

    elseif CONFIGURATION.features.show_dictionary_button_in_dictionary_popup then
        -- Add AI Dictionary button to the existing popup
        local suffix = CONFIGURATION.features.ai_button_suffix or ""
        table.insert(buttons, 1, {{
            id = "assistant_dictionary",
            text = _("Dictionary") .. suffix,
            font_bold = false,
            callback = function()
                -- Close the current dict_popup before showing the new one
                local UIManager = require("ui/uimanager")
                local InfoMessage = require("ui/widget/infomessage") -- Needed for error message
                local lookupword = dict_popup.lookupword
                UIManager:close(dict_popup)

                NetworkMgr:runWhenOnline(function()
                     -- Check if dictdialog exists before requiring
                    local ok_dict, showDictionaryDialog = pcall(require, "dictdialog")
                    if ok_dict then
                        showDictionaryDialog(self.ui, lookupword)
                    else
                        if logger then logger.error("onDictButtonsReady Callback: Failed to load dictdialog.lua:", showDictionaryDialog) end
                        UIManager:show(InfoMessage:new{ text = _("Error opening AI Dictionary."), timeout = 2 })
                    end
                end)
            end,
        }})
    end
    -- Return false if we didn't handle the event (i.e., didn't replace the popup)
    return false
end

return Assistant
