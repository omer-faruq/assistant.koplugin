local Device = require("device")
local logger = require("logger")
local Event = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local Trapper = require("ui/trapper")
local Language = require("ui/language")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local ConfirmBox  = require("ui/widget/confirmbox")
local T 		      = require("ffi/util").template
local FrontendUtil = require("util")
local ButtonDialog = require("ui/widget/buttondialog")
local ffiutil = require("ffi/util")

local _ = require("owngettext")
local AssistantDialog -- will be loaded after helpers; avoid module name collisions
local UpdateChecker = require("update_checker")
local Prompts = require("prompts")
local SettingsDialog = require("settingsdialog")
local showDictionaryDialog = require("dictdialog")
local meta = require("_meta")

local Assistant = InputContainer:new {
  name = "assistant",
  is_doc_only = true,   -- only available in doc model
  settings_file = DataStorage:getSettingsDir() .. "/assistant.lua",
  settings = nil,
  querier = nil,
  updated = false, -- flag to track if settings were updated
  assistant_dialog = nil, -- reference to the main dialog instance
  ui_language = nil,
  ui_language_is_rtl = nil,
  CONFIGURATION = nil,  -- reference to the main configuration
}

local function loadConfigFile(filePath)
    local env = {}
    setmetatable(env, {__index = _G})
    local chunk, err = loadfile(filePath, "t", env) -- test mode to loadfile, check syntax errors
    if not chunk then return nil, err end
    local success, result = pcall(chunk) -- run the code, checks runtime errors
    if not success then return nil, result end
    -- configuration.lua returns the CONFIGURATION table; return that directly
    return result
end
 
-- Load a Lua module file by absolute path and return its chunk return value.
-- This differs from loadConfigFile by not sandboxing the environment, which some modules may rely on.
local function loadModuleByPath(filePath)
  local chunk, err = loadfile(filePath)
  if not chunk then return nil, err end
  local ok, ret = pcall(chunk)
  if not ok then return nil, ret end
  return ret
end

-- Determine the directory of this file (main.lua)
local function getCurrentDir()
  local info = debug and debug.getinfo and debug.getinfo(1, "S")
  local src = info and info.source or nil
  if src and src:sub(1, 1) == '@' then
    return src:match("^@(.+)[/\\][^/\\]+$")
  end
  return nil
end

-- Load assistant-local modules by absolute path to avoid collisions with other plugins
do
  local cur_dir = getCurrentDir()
  if cur_dir then
    -- Preload our ChatGPTViewer so dialogs.lua resolves to the correct module
    local viewer_mod = select(1, loadModuleByPath(cur_dir .. "/chatgptviewer.lua"))
    if type(viewer_mod) == "table" then
      package.loaded["chatgptviewer"] = viewer_mod
    end

    -- Load our own dialogs.lua
    local dlg_mod, dlg_err = loadModuleByPath(cur_dir .. "/dialogs.lua")
    if type(dlg_mod) == "table" then
      AssistantDialog = dlg_mod
      package.loaded["dialogs"] = dlg_mod
    else
      logger.warn("Assistant: failed to path-load dialogs.lua: " .. tostring(dlg_err))
      AssistantDialog = require("dialogs")
    end
  else
    -- Fallback to normal require if we cannot detect current dir
    AssistantDialog = require("dialogs")
  end
end

-- configuration locations
local CONFIG_FILE_PATH = string.format("%s/plugins/%s.koplugin/configuration.lua",
                                      DataStorage:getDataDir(), meta.name)
local CONFIG_LOAD_ERROR = nil
local CONFIGURATION = nil

-- 1) Try user override at DataStorage path
local user_conf, user_err = loadConfigFile(CONFIG_FILE_PATH)
if user_conf then
  CONFIGURATION = user_conf
else
  CONFIG_LOAD_ERROR = user_err
end

-- 2) Fallback to plugin-local configuration.lua, avoiding global require collisions
if not CONFIGURATION then
  local cur_dir = getCurrentDir()
  if cur_dir then
    local plugin_conf_path = cur_dir .. "/configuration.lua"
    local plugin_conf, plugin_err = loadConfigFile(plugin_conf_path)
    if plugin_conf then
      CONFIGURATION = plugin_conf
      CONFIG_LOAD_ERROR = nil
    else
      -- Keep first error if present; otherwise use plugin-local error
      CONFIG_LOAD_ERROR = CONFIG_LOAD_ERROR or plugin_err
    end
  end
end

if CONFIG_LOAD_ERROR then logger.warn(CONFIG_LOAD_ERROR) end

-- Flag to ensure the update message is shown only once per session
local updateMessageShown = false

function Assistant:onDispatcherRegisterActions()
  -- Register main AI ask action
  Dispatcher:registerAction("ai_ask_question", {
    category = "none", 
    event = "AskAIQuestion", 
    title = _("Ask the AI a question"), 
    general = true
  })
  
  -- Register AI recap action
  if self.settings:readSetting("enable_recap", false) then
    Dispatcher:registerAction("ai_recap", {
      category = "none", 
      event = "AskAIRecap", 
      title = _("AI Recaps"), 
      general = true
    })
  end
  
  -- Register AI X-Ray action (available for gesture binding)
  Dispatcher:registerAction("ai_xray", {
    category = "none",
    event = "AskAIXRay",
    title = _("AI X-Ray"),
    general = true,
    separator = true
  })
end

function Assistant:addToMainMenu(menu_items)
    menu_items.assistant_provider_switch = {
        text = _("AI Assistant Settings"),
        sorting_hint = "more_tools",
        callback = function ()
          self:showSettings()
        end
    }
end

function Assistant:showSettings()

  if self._settings_dialog then
    -- If settings dialog is already open, just show it again
    UIManager:show(self._settings_dialog)
    return
  end

  local settingDlg = SettingsDialog:new{
      assistant = self,
      CONFIGURATION = CONFIGURATION,
      settings = self.settings,
  }

  self._settings_dialog = settingDlg -- store reference to the dialog
  UIManager:show(settingDlg)
end

function Assistant:getModelProvider()

  local provider_settings = CONFIGURATION.provider_settings -- provider settings table from configuration.lua
  local setting_provider = self.settings:readSetting("provider")

  local function is_provider_valid(key)
    if not key then return false end
    local provider = FrontendUtil.tableGetValue(CONFIGURATION, "provider_settings", key)
    return provider and FrontendUtil.tableGetValue(provider, "model") and
        FrontendUtil.tableGetValue(provider, "base_url") and
        FrontendUtil.tableGetValue(provider, "api_key")
  end

  local function find_setting_provider(filter_func)
    for key, tab in pairs(provider_settings) do
      if is_provider_valid(key) then
        if filter_func and filter_func(key, tab) then return key end
        if not filter_func then return key end
      end
    end
    return nil
  end

  if is_provider_valid(setting_provider) then
    -- If the setting provider is valid, use it
    return setting_provider
  else
    -- If the setting provider is invalid, delete this selection
    self.settings:delSetting("provider")

    local conf_provider = CONFIGURATION.provider -- provider name from configuration.lua
    if is_provider_valid(conf_provider) then
      -- if the configuration provider is valid, use it
      setting_provider = conf_provider
    else
      -- try to find the one defined with `default = true`
      setting_provider = find_setting_provider(function(key, tab)
        return FrontendUtil.tableGetValue(tab, "default") == true
      end)
      
      -- still invalid (none of them defined `default`)
      if not setting_provider then
        setting_provider = find_setting_provider()
        logger.warn("Invalid provider setting found, using a random one: ", setting_provider)
      end
    end

    if not setting_provider then
      CONFIG_LOAD_ERROR = _("No valid model provider is found in the configuration.lua")
      return nil
    end -- if still not found, the configuration is wrong
    self.settings:saveSetting("provider", setting_provider)
    self.updated = true -- mark settings as updated
  end
  return setting_provider
end

-- Flush settings to disk, triggered by koreader
function Assistant:onFlushSettings()
    if self.updated then
        self.settings:flush()
        self.updated = nil
    end
end

function Assistant:init()
  -- init settings
  self.settings = LuaSettings:open(self.settings_file)

  -- Register actions with dispatcher for gesture assignment
  self:onDispatcherRegisterActions()

  -- Register model switch to main menu (under "More tools")
  self.ui.menu:registerToMainMenu(self)

  -- Assistant button
  self.ui.highlight:addToHighlightDialog("assistant", function(_reader_highlight_instance)
    return {
      text = _("AI Assistant"),
      enabled = Device:hasClipboard(),
      callback = function()
        
        -- handle error message during loading
        if CONFIG_LOAD_ERROR and type(CONFIG_LOAD_ERROR) == "string" then
          local err_text = _("Configuration Error.\nPlease set up configuration.lua.")
          -- keep the error message clean
          local cut = CONFIG_LOAD_ERROR:find("configuration.lua")
          err_text = string.format("%s\n\n%s", err_text, 
                  (cut > 0) and CONFIG_LOAD_ERROR:sub(cut) or CONFIG_LOAD_ERROR)
          UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err_text })
          return
        end

        NetworkMgr:runWhenOnline(function()
          if not updateMessageShown then
            UpdateChecker.checkForUpdates(self.CONFIGURATION)
            updateMessageShown = true
          end
          UIManager:nextTick(function()
            -- Ensure dialog exists before showing
            if not self.assistant_dialog then
              UIManager:show(InfoMessage:new{ icon = "notice-warning", text = _("Assistant not initialized. Please check configuration and try again.") })
              return
            end
            -- Show the main AI dialog with highlighted text
            self.assistant_dialog:show(_reader_highlight_instance.selected_text.text)
          end)
        end)
      end,
      hold_callback = function()
        local info_text = string.format("%s %s\n\n", meta.fullname, meta.version) .. _([[Useful Tips:

Long Press:
- On a Prompt Button: Add to the highlight menu.
- On a highlight menu button to remove it.

Very-Long Press (over 3 seconds):
On a single word in the book to show the highlight menu (instead of the dictionary).

Multi-Swipe (e.g., ⮠, ⮡, ↺):
On the result dialog to close (as the Close button is far to reach).
]])
        UIManager:show(ConfirmBox:new{
            text = info_text,
            no_ok_button = true, other_buttons_first = true,
            other_buttons = {{
              {
                text = _("Settings"),
                callback = function()
                  self:showSettings()
                end
              },
              {
                text = _("Purge Settings"),
                callback = function()
                  UIManager:show(ConfirmBox:new{
                    text = _([[Are you sure to purge the assistant plugin settings? 
This resets the assistant plugin to the status the first time you installed it.

configuration.lua is safe, only the settings in the dialog are purged.]]),
                    ok_text = _("Purge"),
                    ok_callback = function()
                      self.settings:reset({})
                      self.settings:flush()
                      UIManager:askForRestart()
                    end
                  })
                end
              },
            }}
        })
      end,
    }
  end)

  -- skip initialization if configuration.lua is not found
  if not CONFIGURATION then return end
  self.CONFIGURATION = CONFIGURATION

  -- Sync provider selection from configuration if configuration provider changed
  self:syncProviderSelectionFromConfig()

  local model_provider = self:getModelProvider()
  if not model_provider then
    CONFIG_LOAD_ERROR = _("configuration.lua: model providers are invalid.")
    return
  end

  -- Load the model provider from settings or default configuration
  -- Load assistant-local gpt_query.lua to avoid collision with askgpt's gpt_query
  local QuerierModule
  do
    local cur_dir = getCurrentDir()
    if cur_dir then
      local qpath = cur_dir .. "/gpt_query.lua"
      local qm, qerr = loadModuleByPath(qpath)
      if qm then
        QuerierModule = qm
      else
        logger.warn("Failed to load gpt_query.lua: " .. tostring(qerr))
      end
    end
  end
  if type(QuerierModule) ~= "table" or type(QuerierModule.new) ~= "function" then
    CONFIG_LOAD_ERROR = _("Failed to load assistant's gpt_query.lua (invalid module type)")
    return
  end
  self.querier = QuerierModule:new({
    assistant = self,
    settings = self.settings,
  })

  local ok, err = self.querier:load_model(model_provider)
  if not ok then
    CONFIG_LOAD_ERROR = err
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
    return
  end

  -- Create dialog as soon as core init succeeds
  self.assistant_dialog = AssistantDialog:new(self, CONFIGURATION)

  -- store the UI language (non-critical; guard to avoid aborting init)
  pcall(function()
    local ui_locale = (G_reader_settings and G_reader_settings.readSetting and G_reader_settings:readSetting("language")) or "en"
    self.ui_language = Language:getLanguageName(ui_locale) or "English"
    self.ui_language_is_rtl = Language:isLanguageRTL(ui_locale)
  end)

  -- Conditionally override translate method based on user setting (guarded)
  local ok_override, err_override = pcall(function() self:syncTranslateOverride() end)
  if not ok_override then
    logger.warn("Assistant: syncTranslateOverride failed: " .. tostring(err_override))
  end
  
  -- Ensure custom prompts from configuration are merged before building menus
  -- so that `show_on_main_popup` and `visible` overrides take effect.
  Prompts.getMergedCustomPrompts(FrontendUtil.tableGetValue(CONFIGURATION, "features", "prompts"))
  
  -- Recap Feature
  if self.settings:readSetting("enable_recap", false) then
    self:_hookRecap()
  end

  -- Add Custom buttons to main select popup menu
  local showOnMain = Prompts.getSortedCustomPrompts(function (prompt, idx)
    if prompt.visible == false then
      return false
    end

    --  set in runtime settings (by holding the prompt button)
    local menukey = string.format("assistant_%02d_%s", prompt.order, idx)
    local settingkey = "showOnMain_" .. menukey
    if self.settings:has(settingkey) then
      return self.settings:isTrue(settingkey)
    end

    -- set in configure file
    if prompt.show_on_main_popup then
      return true
    end

    return false -- only show if `show_on_main_popup` is true
  end) or {}

  -- Add buttons in sorted order
  for _, tab in ipairs(showOnMain) do
    self:addMainButton(tab.idx, tab)
  end
end

function Assistant:addMainButton(prompt_idx, prompt)
  local menukey = string.format("assistant_%02d_%s", prompt.order, prompt_idx)
  self.ui.highlight:removeFromHighlightDialog(menukey) -- avoid duplication
  self.ui.highlight:addToHighlightDialog(menukey, function(_reader_highlight_instance)
    local btntext = prompt.text .. " (AI)"  -- append "(AI)" to identify as our function
    return {
      text = btntext,
      callback = function()
        NetworkMgr:runWhenOnline(function()
          Trapper:wrap(function()
            if prompt.order == -10 and prompt_idx == "dictionary" then
              -- Dictionary prompt, show dictionary dialog
              showDictionaryDialog(self, _reader_highlight_instance.selected_text.text)
            else
              -- For other prompts, show the custom prompt dialog
              self.assistant_dialog:showCustomPrompt(_reader_highlight_instance.selected_text.text, prompt_idx)
            end
          end)
        end)
      end,
      hold_callback = function() -- hold to remove
        UIManager:nextTick(function()
          UIManager:show(ConfirmBox:new{
            text = string.format(_("Remove [%s] from Highlight Menu?"), btntext),
            ok_text = _("Remove"),
            ok_callback = function()
              self:handleEvent(Event:new("AssistantSetButton", {order=prompt.order, idx=prompt_idx}, "remove"))
            end
          })
        end)
      end,
    }
  end)
end

function Assistant:onDictButtonsReady(dict_popup, dict_buttons)
  local plugin_buttons = {}
  if self.settings:readSetting("dict_popup_show_wikipedia", true) then
    table.insert(plugin_buttons, {
      id = "assistant_wikipedia",
      font_bold = true,
      text = _("Wikipedia") .. " (AI)",
      callback = function()
          NetworkMgr:runWhenOnline(function()
              Trapper:wrap(function()
                self.assistant_dialog:showCustomPrompt(dict_popup.word, "wikipedia")
              end)
          end)
      end,
    })
  end

  if self.settings:readSetting("dict_popup_show_dictionary", true) then
    table.insert(plugin_buttons, {
      id = "assistant_dictionary",
      text = _("Dictionary") .. " (AI)",
      font_bold = true,
      callback = function()
          NetworkMgr:runWhenOnline(function()
              Trapper:wrap(function()
                showDictionaryDialog(self, dict_popup.word)
              end)
          end)
      end,
    })
  end

  if #plugin_buttons > 0 and #dict_buttons > 1 then
    table.insert(dict_buttons, 2, plugin_buttons) -- add to the last second row of buttons
  end
end

-- Event handlers for gesture-triggered actions
function Assistant:onAskAIQuestion()
  if not CONFIGURATION then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Configuration not found. Please set up configuration.lua first.")
    })
    return true
  end
  
  NetworkMgr:runWhenOnline(function()
    -- Show dialog without highlighted text
    Trapper:wrap(function()
      self.assistant_dialog:show()
    end)
  end)
  return true
end

function Assistant:onAskAIRecap()
  
  NetworkMgr:runWhenOnline(function()
    
    -- Get current book information
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(self.ui.document.file)
    local percent_finished = doc_settings:readSetting("percent_finished") or 0
    local doc_props = doc_settings:child("doc_props")
    local title = doc_props:readSetting("title") or self.ui.document:getProps().title or "Unknown Title"
    local authors = doc_props:readSetting("authors") or self.ui.document:getProps().authors or "Unknown Author"
    
    -- Show recap dialog
    local showRecapDialog = require("recapdialog")
    Trapper:wrap(function()
      showRecapDialog(self, title, authors, percent_finished)
    end)
  end)
  return true
end

function Assistant:onAskAIXRay()
  if not CONFIGURATION then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Configuration not found. Please set up configuration.lua first.")
    })
    return true
  end

  NetworkMgr:runWhenOnline(function()
    -- Get current book information
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(self.ui.document.file)
    local percent_finished = doc_settings:readSetting("percent_finished") or 0
    local doc_props = doc_settings:child("doc_props")
    local title = doc_props:readSetting("title") or self.ui.document:getProps().title or "Unknown Title"
    local authors = doc_props:readSetting("authors") or self.ui.document:getProps().authors or "Unknown Author"

    -- Show X-Ray dialog
    local showXRayDialog = require("xraydialog")
    Trapper:wrap(function()
      showXRayDialog(self, title, authors, percent_finished)
    end)
  end)
  return true
end

-- Sync Overriding translate method with setting
function Assistant:syncTranslateOverride()

  local Translator = require("ui/translator")
  local should_override = self.settings:readSetting("ai_translate_override", false) -- default to false

  if should_override then
    -- Store original translate method if not already stored
    if not Translator._original_showTranslation then
      Translator._original_showTranslation = Translator.showTranslation
    end

    -- Override translate method with AI Assistant
    Translator.showTranslation = function(ts_self, text, detailed_view, source_lang, target_lang, from_highlight, index)
      if not CONFIGURATION then
        UIManager:show(InfoMessage:new{
          icon = "notice-warning",
          text = _("Configuration not found. Please set up configuration.lua first.")
        })
        return
      end

      local words = FrontendUtil.splitToWords(text)
      NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
          -- splitToWords result like this: { "The", " ", "good", " ", "news" }
          if #words > 5 then
              self.assistant_dialog:showCustomPrompt(text, "translate")
          else
            -- Show AI Dictionary dialog
            showDictionaryDialog(self, text)
          end
        end)
      end)
    end
    logger.info("Assistant: translate method overridden with AI Assistant")
  else
    -- Restore the override
    if Translator._original_showTranslation then
      -- Restore the original method
      Translator.showTranslation = Translator._original_showTranslation
      Translator._original_showTranslation = nil
      logger.info("Assistant: translate method restored")
    end
  end
end

function Assistant:onAssistantSetButton(btnconf, action)
  local menukey = string.format("assistant_%02d_%s", btnconf.order, btnconf.idx)
  local settingkey = "showOnMain_" .. menukey

  local idx = btnconf.idx
  local prompt = Prompts.custom_prompts[idx]

  if action == "add" then
    self.settings:makeTrue(settingkey)
    self.updated = true
    self:addMainButton(idx, prompt)
    UIManager:show(InfoMessage:new{
      text = T(_("Added [%1 (AI)] to Highlight Menu."), prompt.text),
      icon = "notice-info",
      timeout = 3
    })
  elseif action == "remove" then
    self.settings:makeFalse(settingkey)
    self.updated = true
    self.ui.highlight:removeFromHighlightDialog(menukey)
    UIManager:show(InfoMessage:new{
      text = string.format(_("Removed [%s (AI)] from Highlight Menu."), prompt.text),
      icon = "notice-info",
      timeout = 3
    })
  else
    logger.warn("wrong event args", menukey, action)
  end

  return true
end

-- Adds hook on opening a book, the recap feature
function Assistant:_hookRecap()
  local ReaderUI    = require("apps/reader/readerui")
  -- avoid recurive overrides here
  -- pulgin is loaded on every time file opened
  if not ReaderUI._original_doShowReader then 

    -- Save a reference to the original doShowReader method.
    ReaderUI._original_doShowReader = ReaderUI.doShowReader

    local assistant = self -- reference to the Assistant instance
    local lfs         = require("libs/libkoreader-lfs")   -- for file attributes
    local DocSettings = require("docsettings")			      -- for document progress
  
    -- Override to hook into the reader's doShowReader method.
    function ReaderUI:doShowReader(file, provider, seamless)

      -- Get file metadata; here we use the file's "access" attribute.
      local attr = lfs.attributes(file)
      local lastAccess = attr and attr.access or nil
  
      if lastAccess and lastAccess > 0 then -- Has been opened
        local doc_settings = DocSettings:open(file)
        local percent_finished = doc_settings:readSetting("percent_finished") or 0
        local timeDiffHours = (os.time() - lastAccess) / 3600.0
  
        -- More than 28hrs since last open and less than 95% complete
        -- percent = 0 may means the book is not started yet, the docsettings maybe empty
        if timeDiffHours >= 28 and percent_finished > 0 and percent_finished <= 0.95 then 
          -- Construct the message to display.
          local doc_props = doc_settings:child("doc_props")
          local title = doc_props:readSetting("title", "Unknown Title")
          local authors = doc_props:readSetting("authors", "Unknown Author")
          local message = string.format(T(_("Do you want an AI Recap?\nFor %s by %s.\nLast read %.0f hour(s) ago.")), title, authors, timeDiffHours) -- can add in percent_finished too
  
          -- Display the request popup using ConfirmBox.
          UIManager:show(ConfirmBox:new{
            text            = message,
            ok_text         = _("Yes"),
            ok_callback     = function()
              NetworkMgr:runWhenOnline(function()
                local showRecapDialog = require("recapdialog")
                Trapper:wrap(function()
                  showRecapDialog(assistant, title, authors, percent_finished)
                end)
              end)
            end,
            cancel_text     = _("No"),
          })
        end
      end
      return ReaderUI._original_doShowReader(self, file, provider, seamless)
    end
  end
end

function Assistant:syncProviderSelectionFromConfig()
  -- Sync the selected provider from configuration.lua into settings only when
  -- configuration provider changes compared to the last remembered value.
  -- The remembered value is stored in settings as "previous_config_ai_provider".
  local conf = self.CONFIGURATION
  if not conf then return end

  local config_provider = FrontendUtil.tableGetValue(conf, "provider")
  if not config_provider or config_provider == "" then return end

  local previous_config_ai_provider = self.settings:readSetting("previous_config_ai_provider")
  if previous_config_ai_provider ~= config_provider then
    -- Config changed (or first install). Mark config's provider as selected and remember it.
    self.settings:saveSetting("provider", config_provider)
    self.settings:saveSetting("previous_config_ai_provider", config_provider)
    self.updated = true
  end
end

return Assistant
