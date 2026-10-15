local InputContainer = require("ui/widget/container/inputcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local Language = require("ui/language")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local ConfirmBox  = require("ui/widget/confirmbox")
local T = require("ffi/util").template
local TextUtils = require("utils/text")
local NetUtils = require("utils/net")
local Lookup = require("feature/lookup")
local BookActions = require("feature/book_actions")
local _ = require("core/gettext")
local AssistantDialog = require("dialogs/dialog")
local SettingsMenu = require("dialogs/settings_menu")
local Registry = require("core/provider_registry")
local SearchRegistry = require("core/search_registry")
local Config = require("core/config")
local Hooks = require("core/hooks")

-- One LuaSettings per file shared across Assistant instances: the plugin is
-- instantiated per UI (FileManager and ReaderUI), and separate LuaSettings:open
-- snapshots of the same file diverge - the last flush clobbers the other's keys.
local SHARED_SETTINGS = {}
local function openSharedSettings(file)
  local settings = SHARED_SETTINGS[file]
  if not settings then
    settings = LuaSettings:open(file)
    SHARED_SETTINGS[file] = settings
  end
  return settings
end

local Assistant = InputContainer:new {
  name = "assistant",
  meta = nil,
  is_doc_only = false,
  settings_file = DataStorage:getSettingsDir() .. "/assistant.lua",
  settings = nil,
  querier = nil,
  updated = false,
  assistant_dialog = nil,
  ui_language = nil,
  ui_language_is_rtl = nil,
  config = nil,
}

function Assistant:onDispatcherRegisterActions()
  Dispatcher:registerAction("ai_ask_question", {
    category = "none",
    event = "AskAIQuestion",
    title = _("Ask the AI a question"),
    general = true
  })
  Dispatcher:registerAction("ai_recap", {
    category = "none",
    event = "AskAIRecap",
    -- @translators Action title. "Recap" is short for "recapitulation": a brief spoiler-free summary of what the reader has already read, to refresh memory. Keep consistent with "Recap" / "AI Recap" elsewhere.
    title = _("AI Recaps"),
    general = true
  })
  Dispatcher:registerAction("ai_identify_book", {
    category = "none",
    event = "AskAIIdentifyBook",
    -- @translators Action title: infer a book's title/author from its opening text.
    title = _("Identify This Book"),
    general = true
  })
  Dispatcher:registerAction("ai_xray", {
    category = "none",
    event = "AskAIXRay",
    title = _("AI X-Ray"),
    general = true
  })
  Dispatcher:registerAction("ai_quick_note", {
    category = "none",
    event = "AskAIQuickNote",
    title = _("Take Quick Notes"),
    general = true
  })
  Dispatcher:registerAction("ai_book_info", {
    category = "none",
    event = "AskAIBookInfo",
    title = _("Book Summary & Recs"),
    general = true
  })
  Dispatcher:registerAction("ai_annotations", {
    category = "none",
    event = "AskAIAnnotations",
    title = _("Highlight & Note Analysis"),
    general = true
  })
  Dispatcher:registerAction("ai_summary_using_annotations", {
    category = "none",
    event = "AskSummaryUsingAnnotations",
    title = _("Summary Using Highlights & Notes"),
    general = true,
    separator = true
  })
end

function Assistant:addToMainMenu(menu_items)
  SettingsMenu.addToMainMenu(self, menu_items)
end

function Assistant:showProviderDialog(close_callback)
  SettingsMenu.showProviderDialog(self, close_callback)
end

function Assistant:_help_dialog()
  SettingsMenu.showHelpDialog(self)
end

function Assistant:showAboutDialog()
  SettingsMenu.showAboutDialog(self)
end

function Assistant:_showAddProviderDialog(preset_name, handler, base_url, additional_parameters, edit_id)
  Registry.showProviderDialog(self, preset_name, handler, base_url, additional_parameters, edit_id)
end

function Assistant:_showAddWebSearchDialog(tool_key)
  SearchRegistry.showWebSearchDialog(self, tool_key)
end

function Assistant:getDocumentInfoForFile(file, book_props)
  return BookActions.getDocumentInfoForFile(self, file, book_props)
end

function Assistant:_buildFileDialogAIRow(file, is_file, book_props)
  return BookActions.buildFileDialogAIRow(self, file, is_file, book_props)
end

function Assistant:_closeFileDialogs()
  BookActions.closeFileDialogs()
end

function Assistant:_registerFileDialogButtons()
  BookActions.registerFileDialogButtons()
end

function Assistant:_removeFileDialogButtons()
  BookActions.removeFileDialogButtons()
end

function Assistant:confirmMissingMetadata(launch)
  BookActions.confirmMissingMetadata(self, launch)
end

function Assistant:commitIdentifiedMetadata(ui, file, identified)
  BookActions.commitIdentifiedMetadata(self, ui, file, identified)
end

function Assistant:_identifyBookFlow(opening, file, commit_ui)
  BookActions.identifyBookFlow(self, opening, file, commit_ui)
end

function Assistant:onAskAIIdentifyBook()
  return BookActions.onAskAIIdentifyBook(self)
end

function Assistant:onAskAIIdentifyBookForFile(file, book_props)
  return BookActions.onAskAIIdentifyBookForFile(self, file, book_props)
end

function Assistant:onAskAIBookInfoForFile(file, book_props)
  return BookActions.onAskAIBookInfoForFile(self, file, book_props)
end

function Assistant:onAskAIRecapForFile(file, book_props)
  return BookActions.onAskAIRecapForFile(self, file, book_props)
end

function Assistant:onAskAIRecap()
  return BookActions.onAskAIRecap(self)
end

function Assistant:onAskAIXRay()
  return BookActions.onAskAIXRay(self)
end

function Assistant:onAskAIBookInfo()
  return BookActions.onAskAIBookInfo(self)
end

function Assistant:onAskAIAnnotations()
  return BookActions.onAskAIAnnotations(self)
end

function Assistant:onAskSummaryUsingAnnotations()
  return BookActions.onAskSummaryUsingAnnotations(self)
end

function Assistant:showTranslateOrDictionary(text)
  Lookup.showTranslateOrDictionary(self, text)
end

function Assistant:_rebuildShowOnMainButtons()
  Hooks.rebuildShowOnMainButtons(self)
end

function Assistant:addMainButton(prompt_idx, prompt)
  Hooks.addMainButton(self, prompt_idx, prompt)
end

function Assistant:_buildAssistantDictButtons(dict_popup_arg, live)
  return Hooks.buildAssistantDictButtons(self, dict_popup_arg, live)
end

function Assistant:_groupDictButtonsInDefaultLayout(button_ids)
  Hooks.groupDictButtonsInDefaultLayout(self, button_ids)
end

function Assistant:_restoreDictButtonsInUserLayout(button_ids)
  Hooks.restoreDictButtonsInUserLayout(self, button_ids)
end

function Assistant:onDictButtonsReady(dict_popup, dict_buttons)
  Hooks.onDictButtonsReady(self, dict_popup, dict_buttons)
end

function Assistant:onAssistantSetButton(btnconf, action)
  return Hooks.onAssistantSetButton(self, btnconf, action)
end

function Assistant:syncProviderSelectionFromConfig()
  if self.config then self.config:syncProviderSelection() end
end

function Assistant:onFlushSettings()
  if self.updated then
    self.settings:flush()
    self.updated = nil
  end
end

function Assistant:onClose()
  self:_removeFileDialogButtons()
end

function Assistant:isConfigured()
  local err_text = TextUtils.bold_format(
    _("<b>No provider set up yet.</b>\nPlease add a provider in Settings or configuration.lua.")
  )
  local function show_config_error()
    UIManager:show(ConfirmBox:new{
      icon = "notice-warning",
      text = err_text,
      ok_text = _("OK"),
      ok_callback = function()
        UIManager:show(InfoMessage:new{
          text = T(_("Add providers from the main menu:\n%1 -> AI Assistant -> Settings -> Provider API"), "⚙")
        })
      end,
      cancel_text = _("Cancel"),
    })
  end
  local loadError = self.config and self.config:getLoadError()
  if loadError and type(loadError) == "string" then
    local cut = loadError:find("configuration.lua", 1, true) or 0
    err_text = string.format("%s\n\n%s", err_text,
      (cut > 0) and loadError:sub(cut) or loadError)
    show_config_error()
    return nil
  end
  if not self.config or not self.querier or not self.querier.handler then
    show_config_error()
    return nil
  end
  return true
end

function Assistant:init()
  self.meta = dofile(Config.getMetaPath())
  self.settings = openSharedSettings(self.settings_file)
  local ui_locale = G_reader_settings:readSetting("language") or "en"
  self.ui_language = Language:getLanguageName(ui_locale) or "English"
  self.ui_language_is_rtl = Language:isLanguageRTL(ui_locale)
  local rawConfig, loadError = Config.loadRawConfig()
  self.config = Config:new{ assistant = self, data = rawConfig or {}, loadError = loadError }
  self.config:buildEffectiveConfig()
  self:onDispatcherRegisterActions()
  Hooks.setupMenuOrder()
  self.ui.menu:registerToMainMenu(self)
  Hooks.setupScrollHtmlWidget()
  Hooks.setupBookDescription(self)
  if not self.ui.document then
    self:_registerFileDialogButtons()
  end
  if self.ui.document then
    Hooks.setupHighlightMainButton(self)
  end
  if not next(self.config:getProviderSettings()) then return end
  self.config:clearLoadError()
  self:syncProviderSelectionFromConfig()
  local model_provider = self.config:getActiveProviderId()
  if not model_provider then
    self.config:setLoadError(_("configuration.lua: model providers are invalid."))
    return
  end
  self.querier = require("core/querier"):new({
    assistant = self,
    settings = self.settings,
  })
  local ok, err = self.querier:load_model(model_provider)
  if not ok then
    self.config:setLoadError(err)
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
    return
  end
  Hooks.syncTranslateOverride(self)
  Hooks.setupDictButtons(self)
  self.assistant_dialog = AssistantDialog:new(self)
  if self.ui.document then
    if self.settings:readSetting("enable_auto_recap", false) then
      Hooks.setupRecap(self)
    end
    self:_rebuildShowOnMainButtons()
  end
end

function Assistant:onAskAIQuestion()
  if not self:isConfigured() then
    return
  end
  NetUtils.runWhenOnlineFast(function()
    Trapper:wrap(function()
      if not self.assistant_dialog then return end
      self.assistant_dialog:showAskDialog()
    end)
  end)
  return true
end

function Assistant:onAskAIQuickNote()
  if not self:isConfigured() then return end
  if not self.quicknote then
    local QuickNote = require("dialogs/quicknote")
    self.quicknote = QuickNote:new(self)
  end
  self.quicknote:show()
  return true
end

return Assistant
