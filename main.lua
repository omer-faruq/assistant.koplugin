local Device = require("device")
local logger = require("logger")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
local ConfirmBox  = require("ui/widget/confirmbox")
local T 		      = require("ffi/util").template
local t = require("i18n")
local FrontendUtil = require("util")
local ffiutil = require("ffi/util")

local AssistantDialog = require("dialogs")
local UpdateChecker = require("update_checker")
local Prompts = require("prompts")
local SettingsDialog = require("settingsdialog")

local Assistant = InputContainer:new {
  name = "Assistant",
  is_doc_only = true,
  settings_file = DataStorage:getSettingsDir() .. "/assistant.lua",
  settings = nil,
  querier = nil,
  updated = false, -- flag to track if settings were updated
  assitant_dialog = nil, -- reference to the main dialog instance
}

-- Load Configuration
local CONFIGURATION = nil
local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  logger.warn("configuration.lua not found, skipping...")
end

-- Flag to ensure the update message is shown only once per session
local updateMessageShown = false

function Assistant:onDispatcherRegisterActions()
  -- Register main AI ask action
  Dispatcher:registerAction("ai_ask_question", {
    category = "none", 
    event = "AskAIQuestion", 
    title = t("ask_ai_question"), 
    general = true
  })
  
  -- Register AI recap action
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.enable_AI_recap then
    Dispatcher:registerAction("ai_recap", {
      category = "none", 
      event = "AskAIRecap", 
      title = t("ai_recap"), 
      general = true,
      separator = true
    })
  end
end

function Assistant:addToMainMenu(menu_items)
    menu_items.assitant_provider_switch = {
        text = t("assistant_settings"),
        sorting_hint = "more_tools",
        callback = function ()
          self:showSettings()
        end
    }
end

function Assistant:showSettings()
    UIManager:show(SettingsDialog:new{
        assitant = self,
        CONFIGURATION = CONFIGURATION,
        settings = self.settings,
    })
end

function Assistant:getModelProvider()

  if not (CONFIGURATION and CONFIGURATION.provider_settings) then
    error(t("configuration_not_found_please_set_up_first"))
  end

  local provider_settings = CONFIGURATION.provider_settings -- provider settings table from configuration.lua
  local setting_provider = nil -- provider name from LuaSettings
  
  -- settings may not be initialized, so check if self.settings exists
  if self.settings and next(self.settings.data) ~= nil then
    setting_provider = self.settings:readSetting("provider")
  end

  if setting_provider and provider_settings[setting_provider] then
    -- If the setting provider is valid, use it
    return setting_provider
  else
    -- If the setting provider is invalid, try to find one from configuration

    local conf_provider = CONFIGURATION.provider -- provider name from configuration.lua

    if provider_settings[conf_provider] then
      -- if the configuration provider is valid, use it
      setting_provider = conf_provider
    else
      -- still invalid, try to find the one defined with `default = true`
      for key, tab in pairs(CONFIGURATION.provider_settings) do
        if tab.default then
          setting_provider = key
          break
        end
      end
      
      -- still invalid (none of them defined `default`)
      if not setting_provider then
        -- log a warning and use a random one available provider
        local function first_key(t) for k, _ in pairs(t) do return k end end
        setting_provider = first_key(CONFIGURATION.provider_settings)
        logger.warn("Invalid provider setting found, using a random one: ", setting_provider)
      end
    end
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
      text = t("assistant"),
      enabled = Device:hasClipboard(),
      callback = function()
        if not CONFIGURATION then
          UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = t("configuration_not_found_please_set_up_first")
          })
          return
        end
        NetworkMgr:runWhenOnline(function()
          if not updateMessageShown then
            UpdateChecker.checkForUpdates()
            updateMessageShown = true
          end
          Trapper:wrap(function()
            -- Show the main AI dialog with highlighted text
            self.assitant_dialog:show(_reader_highlight_instance.selected_text.text)
          end)
        end)
      end,
    }
  end)

  -- skip initialization if configuration.lua is not found
  if not CONFIGURATION then
    logger.warn("Configuration not found. Please set up configuration.lua first.")
    return
  end

  -- Conditionally override translate method based on user setting
  self:applyOrRemoveTranslateOverride()

  -- Load the model provider from settings or default configuration
  self.querier = require("gpt_query"):new({
    assitant = self,
    settings = self.settings,
  })
  self.querier:load_model(self:getModelProvider())

  self.assitant_dialog = AssistantDialog:new(self, CONFIGURATION)
 
  -- Recap Feature
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.enable_AI_recap then
    local ReaderUI    = require("apps/reader/readerui")
    -- avoid recurive overrides here
    -- pulgin is loaded on every time file opened
    if not ReaderUI._original_doShowReader then 
      -- Save a reference to the original doShowReader method.
      ReaderUI._original_doShowReader = ReaderUI.doShowReader

      local assitant = self -- reference to the Assistant instance
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
            local message = string.format(T(t("do_you_want_ai_recap_for_book_last_read")), title, authors, timeDiffHours) -- can add in percent_finished too
    
            -- Display the request popup using ConfirmBox.
            UIManager:show(ConfirmBox:new{
              text            = message,
              ok_text         = t("Yes"),
              ok_callback     = function()
                NetworkMgr:runWhenOnline(function()
                  local showRecapDialog = require("recapdialog")
                  Trapper:wrap(function()
                    showRecapDialog(assitant, title, authors, percent_finished)
                  end)
                end)
              end,
              cancel_text     = t("No"),
            })
          end
        end
        return ReaderUI._original_doShowReader(self, file, provider, seamless)
      end
    end
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
  self.ui.highlight:addToHighlightDialog(menukey, function(_reader_highlight_instance)
    return {
      text = prompt.text .. " (AI)",  -- append "(AI)" to identify as our function
      callback = function()
        NetworkMgr:runWhenOnline(function()
          Trapper:wrap(function()
            if prompt.order == -10 and prompt_idx == "dictionary" then
              -- Dictionary prompt, show dictionary dialog
              local showDictionaryDialog = require("dictdialog")
              showDictionaryDialog(self, _reader_highlight_instance.selected_text.text)
            else
              -- For other prompts, show the custom prompt dialog
              self.assitant_dialog:showCustomPrompt(_reader_highlight_instance.selected_text.text, prompt_idx)
            end
          end)
        end)
      end,
    }
  end)
end

function Assistant:removeMainButton(prompt_idx, prompt)
  local menukey = string.format("assistant_%02d_%s", prompt.order, prompt_idx)
  self.ui.highlight:removeFromHighlightDialog(menukey)
end

function Assistant:onDictButtonsReady(dict_popup, buttons)
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.show_dictionary_button_in_dictionary_popup then
    table.insert(buttons, 1, {{
        id = "assistant_dictionary",
        text = t("dictionary").." (AI)",
        font_bold = false,
        callback = function()
            NetworkMgr:runWhenOnline(function()
                local showDictionaryDialog = require("dictdialog")
                Trapper:wrap(function()
                  showDictionaryDialog(self, dict_popup.word)
                end)
            end)
        end,
    }})
  end
end

-- Event handlers for gesture-triggered actions
function Assistant:onAskAIQuestion()
  if not CONFIGURATION then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = t("configuration_not_found_please_set_up_first")
    })
    return true
  end
  
  NetworkMgr:runWhenOnline(function()
    if not updateMessageShown then
      UpdateChecker.checkForUpdates()
      updateMessageShown = true
    end
    -- Show dialog without highlighted text
    Trapper:wrap(function()
      self.assitant_dialog:show()
    end)
  end)
  return true
end

function Assistant:onAskAIRecap()
  if not CONFIGURATION then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = t("configuration_not_found_please_set_up_first")
    })
    return true
  end
  
  if not CONFIGURATION.features or not CONFIGURATION.features.enable_AI_recap then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = t("ai_recap_feature_not_enabled_in_configuration")
    })
    return true
  end
  
  NetworkMgr:runWhenOnline(function()
    if not updateMessageShown then
      UpdateChecker.checkForUpdates()
      updateMessageShown = true
    end
    
    -- Get current book information
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(self.ui.document.file)
    local percent_finished = doc_settings:readSetting("percent_finished") or 0
    local doc_props = doc_settings:child("doc_props")
    local title = doc_props:readSetting("title") or self.ui.document:getProps().title or t("unknown_title")
    local authors = doc_props:readSetting("authors") or self.ui.document:getProps().authors or t("unknown_author")
    
    -- Show recap dialog
    local showRecapDialog = require("recapdialog")
    Trapper:wrap(function()
      showRecapDialog(self, title, authors, percent_finished)
    end)
  end)
  return true
end

-- Override the translate method in ReaderHighlight to use AI Assistant
function Assistant:applyOrRemoveTranslateOverride()

  local Translator = require("ui/translator")

  local should_override = CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.response_language and
      self.settings:readSetting("ai_translate_override")

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
          text = t("configuration_not_found_please_set_up_first")
        })
        return
      end

      local words = FrontendUtil.splitToWords(text)
      NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
          -- splitToWords result like this: { "The", " ", "good", " ", "news" }
          if #words > 5 then
              self.assitant_dialog:showCustomPrompt(text, "translate")
          else
            -- Show AI Dictionary dialog
            local showDictionaryDialog = require("dictdialog")
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

return Assistant