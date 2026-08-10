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
local koutil = require("util")
local TextViewer = require("ui/widget/textviewer")
local ButtonDialog = require("ui/widget/buttondialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ffiutil = require("ffi/util")
local ToolExecutor = require("assistant_tool_executor")
local ASUtils = require("assistant_utils")

local _ = require("assistant_gettext")
local N_ = _.ngettext
local AssistantDialog = require("assistant_dialog")
local Updater = require("assistant_updater")
local Prompts = require("assistant_prompts")
local SettingsDialog = require("assistant_settings")
local showDictionaryDialog = require("assistant_dictdialog")
local Registry = require("assistant_provider_registry")

local Assistant = InputContainer:new {
  name = "assistant",
  meta = nil,           -- reference to the _meta module
  is_doc_only = false,   -- available in both doc and filemanager models
  settings_file = DataStorage:getSettingsDir() .. "/assistant.lua",
  settings = nil,
  querier = nil,
  updated = false, -- flag to track if settings were updated
  assistant_dialog = nil, -- reference to the main dialog instance
  ui_language = nil,
  ui_language_is_rtl = nil,
  CONFIGURATION = nil,  -- reference to the main configuration
}

-- Preset platforms offered in the "Add Provider" sub-menu.
-- Selecting one only asks for the API key (name/base_url come from here).
local PRESET_PROVIDERS = {
    { name = "DeepSeek",   handler = "openai",   base_url = "https://api.deepseek.com/v1" },
    { name = "OpenRouter", handler = "openai",   base_url = "https://openrouter.ai/api/v1" },
    { name = "Groq",       handler = "openai",   base_url = "https://api.groq.com/openai/v1" },
    { name = "Mistral",    handler = "openai",   base_url = "https://api.mistral.ai/v1" },
    { name = "Gemini",     handler = "gemini",   base_url = "https://generativelanguage.googleapis.com/v1beta" },
    { name = "Anthropic",  handler = "anthropic", base_url = "https://api.anthropic.com/v1" },
}

-- Protocol sub-menu for the "Custom" entry: pick a wire format, then
-- enter a name + API key.
local CUSTOM_HANDLERS = {
    { name = "OpenAI",     handler = "openai",   base_url = "https://api.openai.com/v1" },
    { name = "Anthropic",  handler = "anthropic", base_url = "https://api.anthropic.com/v1" },
    { name = "Gemini",     handler = "gemini",   base_url = "https://generativelanguage.googleapis.com/v1beta" },
    { name = "Responses",  handler = "responses", base_url = "https://api.openai.com/v1" },
}

local function testConfigFile(filePath)
    local env = {}
    setmetatable(env, {__index = _G})
    local chunk, err = loadfile(filePath, "t", env) -- test mode to loadfile, check syntax errors
    if not chunk then return false, err end
    local success, result = pcall(chunk) -- run the code, checks runtime errors
    if not success then return false, result end
    return true, nil
end

-- configuration locations
local ASSISTANT_DIR = T("%1/plugins/%2.koplugin/", DataStorage:getDataDir(), Assistant.name)
local CONFIG_FILE_PATH = ASSISTANT_DIR .. "configuration.lua"
local META_FILE_PATH = ASSISTANT_DIR .. "_meta.lua"
local CONFIG_LOAD_ERROR = nil
local CONFIGURATION = nil

-- test the configuration.lua and store the error message if any
local ok, err = testConfigFile(CONFIG_FILE_PATH)
if not ok then CONFIG_LOAD_ERROR = err end

-- Load Configuration
local success, result = pcall(function() return dofile(CONFIG_FILE_PATH) end)
if success then CONFIGURATION = result
else logger.warn(result) end

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
  Dispatcher:registerAction("ai_recap", {
    category = "none", 
    event = "AskAIRecap", 
    title = _("AI Recaps"), 
    general = true
  })
  
  -- Register AI X-Ray action (available for gesture binding)
  Dispatcher:registerAction("ai_xray", {
    category = "none",
    event = "AskAIXRay",
    title = _("AI X-Ray"),
    general = true
  })

  -- Register Quick Notes action (available for gesture binding)
  Dispatcher:registerAction("ai_quick_note", {
    category = "none", 
    event = "AskAIQuickNote", 
    title = _("Take Quick Notes"), 
    general = true
  })

  -- Register Book Information action (available for gesture binding)
  Dispatcher:registerAction("ai_book_info", {
    category = "none",
    event = "AskAIBookInfo",
    title = _("Book Summary & Recs"),
    general = true
  })

  -- Register Annotations Analysis action (available for gesture binding)
  Dispatcher:registerAction("ai_annotations", {
    category = "none",
    event = "AskAIAnnotations",
    title = _("Highlight & Note Analysis"),
    general = true
  })

  -- Register Annotations Analysis action (available for gesture binding)
  Dispatcher:registerAction("ai_summary_using_annotations", {
    category = "none",
    event = "AskSummaryUsingAnnotations",
    title = _("Summary Using Highlights & Notes"),
    general = true,
    separator = true
  })
end

-- tricky hack: make our menu be the first under tools menu
table.insert(require("ui/elements/reader_menu_order").tools, 1, "ai_assistant")
table.insert(require("ui/elements/filemanager_menu_order").tools, 1, "ai_assistant")
function Assistant:addToMainMenu(menu_items)
  local common_items_table = {
              {
                text = _("Ask the AI a question"),
                separator = true,
                callback = function ()
                  self:onAskAIQuestion()
                end,
                hold_callback = function ()
                  UIManager:show(InfoMessage:new{
                    text = _("Enter a question to ask AI.")
                  })
                end
              },
              {
                text = _("Take Quick Notes"),
                callback = function ()
                  self:onAskAIQuickNote()
                end,
                hold_callback = function ()
                  UIManager:show(InfoMessage:new{
                    text = _("Take quick notes that will be saved to your notebook.")
                  })
                end,
              },
              {
                text = _("NoteBook (AI Conversation Log)"),
                callback = function ()
                  local notebookfile = self.ui.bookinfo:getNotebookFile(self.ui.doc_settings)
                  UIManager:show(ConfirmBox:new{
                    icon = "appbar.pageview",
                    face = Font:getFace("smallinfofont"),
                    text = ASUtils.bold_format(
                        T(_("<b>Notebook file:</b>\n\n%1"), notebookfile)
                    ),
                    ok_text = _("View"),
                    ok_callback = function()
                      if not koutil.pathExists(notebookfile) then
                        UIManager:show(InfoMessage:new{
                          text = T(_("File does not exist.\n\n%1"), notebookfile)
                        })
                        return
                      end
                      TextViewer.openFile(notebookfile)
                    end,
                    other_buttons = {{
                      {
                        text = _("Delete"),
                        callback = function ()
                          UIManager:show(ConfirmBox:new{
                            text = T(_("Delete file?\n%1\nThis operation is not reversible."), notebookfile),
                            ok_text = _("Delete"),
                            ok_callback = function ()
                              local ok, err = koutil.removeFile(notebookfile)
                              if not ok then
                                UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
                              end
                            end
                          })
                        end
                      },
                      {
                        text = _("Edit"),
                        callback = function ()
                          UIManager:broadcastEvent(Event:new("ShowNotebookFile"))
                        end
                      },
                    }}
                  })
                end,
                separator = true,
              },
              {
                text = _("Add Provider"),
                separator = true,
                keep_menu_open = true,
                sub_item_table_func = function()
                    local items = {}
                    -- Add preset providers
                    for _, preset in ipairs(PRESET_PROVIDERS) do
                        table.insert(items, {
                            text = preset.name,
                            keep_menu_open = true,
                            callback = function()
                                self:_showAddProviderDialog(preset.name, preset.handler, preset.base_url)
                            end,
                        })
                    end
                    -- Add Custom sub-menu for protocol selection
                    local custom_items = {}
                    for i, ch in ipairs(CUSTOM_HANDLERS) do
                        table.insert(custom_items, {
                            text = T(_("%1 (Compatible)"), ch.name),
                            keep_menu_open = true,
                            callback = function()
                                self:_showAddProviderDialog(nil, ch.handler, ch.base_url)
                            end,
                        })
                    end
                    table.insert(items, {
                        text = _("Custom"),
                        sub_item_table = custom_items,
                    })
                    return items
                end,
              },
              {
                text_func = function ()
                  if not self.querier then
                    return _("AI Provider: not configured")
                  end
                  local provider = self.querier.provider_setting
                      and self.querier.provider_setting.display_name
                      or self.querier.provider_name
                  local model = self.querier.handler.model
                  return T(_("AI Provider: %1(%2)"), provider, model)
                end,
                keep_menu_open = true,
                callback = function (touchmenu_instance)
                  self:showSettings(function ()
                    touchmenu_instance:updateItems()
                  end)
                end,
              },
              {
                  text_func = function ()
                    local key = self.settings:readSetting("use_websearch", "none")
                    local text = ToolExecutor.ToolToText(key)
                      return T(_("Smart Web Search: %1"), text)
                  end,
                  hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                          text = _("Improves response accuracy with real-time web results. \nNote: Higher token usage and additional API charges apply.")
                      })
                  end,
                  sub_item_table = {},
              },
              {
                text = _("Other Settings"),
                sub_item_table_func = function ()
                  return SettingsDialog.genMenuSettings(self)
                end,
                hold_callback = function ()
                  self:showAboutDialog()
                end
              }
            }
          
  -- append External Search tools menu item
  for _, n in ipairs(ToolExecutor.SEARCH_API_NAMES) do
    table.insert(common_items_table[6].sub_item_table,
      SettingsDialog.genWebSearchSubMenuItem(self, n))
  end

  local book_level_items = {
              {
                text = _("Book-Level Built-in Prompts"),
                sub_item_table = {
                  {
                    text_func = function()
                      return Prompts.getDisplayText(_("Book Summary & Recs"),
                        koutil.tableGetValue(Prompts.assistant_prompts, "book_info", "use_websearch") or false,
                        Prompts.isWebSearchEnabled(self.settings))
                    end,
                    callback = function ()
                      self:onAskAIBookInfo()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Summary of the book, author biography, historical context, and a list of similar book recommendations with descriptions.")
                      })
                    end
                  },
                  {
                    text_func = function()
                      return Prompts.getDisplayText(_("AI X-Ray"),
                        koutil.tableGetValue(Prompts.assistant_prompts, "xray", "use_websearch") or false,
                        Prompts.isWebSearchEnabled(self.settings))
                    end,
                    callback = function ()
                      self:onAskAIXRay()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("\"X-Ray\" summary for a book, structured into specific sections like Characters, Locations, Themes, Terms & Concepts, Timeline, and Re-immersion.")
                      })
                    end
                  },
                  {
                    text_func = function()
                      return Prompts.getDisplayText(_("AI Recaps"),
                        koutil.tableGetValue(Prompts.assistant_prompts, "recap", "use_websearch") or false,
                        Prompts.isWebSearchEnabled(self.settings))
                    end,
                    callback = function ()
                      self:onAskAIRecap()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("A very brief, spoiler-free summary of the book up to current reading progress.")
                      })
                    end,
                  },
                  {
                    text = _("Highlight & Note Analysis"),
                    callback = function ()
                      self:onAskAIAnnotations()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Analysis of your highlights, notes, and notebook content from the book.")
                      })
                    end,
                  },
                  {
                    text_func = function()
                      return Prompts.getDisplayText(_("Summary Using Highlights & Notes"),
                        koutil.tableGetValue(Prompts.assistant_prompts, "summary_using_annotations", "use_websearch") or false,
                        Prompts.isWebSearchEnabled(self.settings))
                    end,
                    callback = function ()
                      self:onAskSummaryUsingAnnotations()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Summary of the book using your highlights and notes.")
                      })
                    end,
                  },
                }
              },
              {
                text = _("Book-Level Custom Prompts"),
                enabled = not not koutil.tableGetValue(CONFIGURATION, "features", "book_level_prompts"),
                sub_item_table_func = function ()
                  return BookLevelCustomPrompts(self)
                end,
                hold_callback = function ()
                  UIManager:show(InfoMessage:new{
                    text = _("Includes user defined book level prompts from Config file")
                  })
                end,
                separator = true,
              },
            }

    local reader_items_table = {}
    -- shallow copy of the common_items_table
    table.move(common_items_table, 1, #common_items_table, 1, reader_items_table)
    for i = #book_level_items,1,-1 do
      table.insert(reader_items_table, 2, book_level_items[i])
    end

    if self.ui.document then
        -- Reader menu
        menu_items.ai_assistant = {
            text = _("AI Assistant"),
            sorting_hint = "tools",
            hold_callback = function ()
              self:_help_dialog()
            end,
            sub_item_table = reader_items_table
          }
    else
        -- Filemanager menu
        menu_items.ai_assistant = {
            text = _("AI Assistant"),
            sorting_hint = "tools",
            hold_callback = function ()
              self:_help_dialog()
            end,
            sub_item_table = common_items_table
        }
    end
end

local function getDocumentInfo(document)
  local DocSettings = require("docsettings")
  local doc_settings = DocSettings:open(document.file)
  local percent_finished = doc_settings:readSetting("percent_finished") or 0
  local doc_props = doc_settings:child("doc_props")
  local title = doc_props:readSetting("title") or document:getProps().title or "Unknown Title"
  local authors = doc_props:readSetting("authors") or document:getProps().authors or "Unknown Author"
  return {
    title = title,
    authors = authors,
    percent_finished = percent_finished,
  }
end

function BookLevelCustomPrompts(assistant)
  local sub_item_table = {}

  -- Read book_level_prompts from configuration
  local book_level_prompts = koutil.tableGetValue(CONFIGURATION, "features", "book_level_prompts") or {}

  for key, prompt_config in ffiutil.orderedPairs(book_level_prompts) do
    if prompt_config.visible == true and prompt_config.type == "feature" then
      local button = {
        text = Prompts.getDisplayText(prompt_config.text or key,
          koutil.tableGetValue(prompt_config, "use_websearch") or false,
          Prompts.isWebSearchEnabled(assistant.settings)),
        callback = function()
          if not assistant:isConfigured() then return end
          NetworkMgr:runWhenOnline(function()
            local book = getDocumentInfo(assistant.ui.document)
            local showFeatureDialog = require("assistant_featuredialog")
            Trapper:wrap(function()
              showFeatureDialog(assistant, prompt_config, book.title, book.authors, book.percent_finished)
            end)
          end)
        end,
        hold_callback = function()
          UIManager:show(InfoMessage:new{
            text = prompt_config.description or _("This is a custom prompt")
          })
        end,
      }
      table.insert(sub_item_table, button)
    end
  end

  if #sub_item_table == 0 then
    local button = {
      text = _("No valid book-level custom prompt found"),
      enabled = false,
    }
    table.insert(sub_item_table, button)
    local button = {
      text = _("For details, visit the 'Configuration' wiki page on github."),
      enabled = false,
    }
    table.insert(sub_item_table, button)
  end
  return sub_item_table
end

function Assistant:showSettings(close_callback)
  if not self:isConfigured() then return end

  if self._settings_dialog then
    -- If settings dialog is already open, just show it again
    UIManager:show(self._settings_dialog)
    return
  end

  local settingDlg = SettingsDialog:new{
      assistant = self,
      CONFIGURATION = self.CONFIGURATION, -- merged config (file + UI providers)
      settings = self.settings,
      close_callback = close_callback,
  }

  self._settings_dialog = settingDlg -- store reference to the dialog
  UIManager:show(settingDlg)
end

--- Show a unified dialog for adding a provider (Name, Base URL, API Key, Model).
--- For preset providers: Name + Base URL are pre-filled from the preset.
--- For Custom (preset_name=nil): Base URL is pre-filled from the protocol sub-menu, Name is empty.
function Assistant:_showAddProviderDialog(preset_name, handler, base_url)
    local dialog_title = preset_name and T(_("Add %1"), preset_name) or T(_("Add %1 Provider"), handler)
    local default_name = preset_name or ""

    local dialog_ref = {}  -- forward ref for enabled_func closure in buttons
    local dialog
    dialog = MultiInputDialog:new{
        title = dialog_title,
        fields = {
            { description = _("Provider Name"), hint = _("Display name"), text = default_name },
            { description = _("Base URL"),      hint = _("https://..."),   text = base_url },
            { description = _("API Key"),       hint = _("Your API key"),  text = "" },
            { description = _("Model"),         hint = _("Default: auto"), text = "auto" },
        },
        buttons = {{
            {
                id = "cancel",
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                id = "browse_models",
                text = _("Browse Models"),
                enabled_func = function()
                    local d = dialog_ref[1]
                    if not d then return false end
                    return d:getFields()[3] ~= ""  -- enabled when API key is filled
                end,
                callback = function()
                    local fields = dialog:getFields()
                    local api_key = fields[3]
                    local url = fields[2]
                    if api_key == "" or url == "" then return end
                    -- Fetch models then reuse model_picker's showPickerDialog
                    NetworkMgr:runWhenOnline(function()
                        Trapper:wrap(function()
                            local models_url = url:gsub("/+$", "") .. "/models"
                            local models_data, err = ASUtils.fetchJSON(models_url, {
                                ["Content-Type"]  = "application/json",
                                ["Authorization"] = "Bearer " .. api_key,
                            })
                            if err or not models_data or not models_data.data then
                                UIManager:show(InfoMessage:new{
                                    text = err or _("Failed to fetch models."),
                                })
                                return
                            end
                            local model_list = models_data.data
                            table.sort(model_list, function(a, b) return a.id < b.id end)
                            local mp = require("assistant_model_picker")
                            mp.showPickerDialog(self, model_list, nil, "", 1,
                                function(model_id)
                                    if dialog.input_fields[4] then
                                        dialog.input_fields[4]:setText(model_id)
                                        dialog.input_fields[4]:moveCursorToCharPos(#model_id + 1)
                                    end
                                end
                            )
                        end)
                    end)
                end,
            },
            {
                id = "save",
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local name = fields[1]
                    local url = fields[2]
                    local api_key = fields[3]
                    local model = fields[4]
                    if name == "" then name = handler end
                    if url == "" then
                        UIManager:show(InfoMessage:new{ text = _("Base URL is required.") })
                        return
                    end
                    if api_key == "" then
                        UIManager:show(InfoMessage:new{ text = _("API key is required.") })
                        return
                    end
                    Registry.installProvider(self, handler, url, name, api_key, model)
                    UIManager:close(dialog)
                    -- Refresh settings if open
                    if self._settings_dialog then
                        UIManager:close(self._settings_dialog)
                        self._settings_dialog = nil
                        UIManager:scheduleIn(0.15, function() self:showSettings() end)
                    end
                end,
            },
        }},
    }
    dialog_ref[1] = dialog
    UIManager:show(dialog)
end

function Assistant:getModelProvider()

  if type(self.CONFIGURATION) ~= "table" then
    return nil
  end

  local provider_settings = self.CONFIGURATION.provider_settings -- provider settings table from configuration.lua
  if type(provider_settings) ~= "table" then
    return nil
  end
  local setting_provider = self.settings:readSetting("provider")

  local function is_provider_valid(key)
    if not key then return false end
    local provider = koutil.tableGetValue(self.CONFIGURATION, "provider_settings", key)
    return provider and koutil.tableGetValue(provider, "model") and
        koutil.tableGetValue(provider, "base_url") and
        koutil.tableGetValue(provider, "api_key")
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

    local conf_provider = self.CONFIGURATION.provider -- provider name from configuration.lua
    if is_provider_valid(conf_provider) then
      -- if the configuration provider is valid, use it
      setting_provider = conf_provider
    else
      -- try to find the one defined with `default = true`
      setting_provider = find_setting_provider(function(key, tab)
        return koutil.tableGetValue(tab, "default") == true
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

function Assistant:isConfigured()
    local err_text = _("Configuration Error.\nPlease set up configuration.lua.")

    -- handle error message during loading
    if CONFIG_LOAD_ERROR and type(CONFIG_LOAD_ERROR) == "string" then
      -- keep the error message clean
      local cut = CONFIG_LOAD_ERROR:find("configuration.lua", 1, true) or 0 -- find as plain
      err_text = string.format("%s\n\n%s", err_text,
              (cut > 0) and CONFIG_LOAD_ERROR:sub(cut) or CONFIG_LOAD_ERROR)
      UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err_text })
      return nil
    end

    if not self.CONFIGURATION then
      UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err_text })
      return nil
    end
  
    return true
end

function Assistant:init()
  -- loading our own _meta.lua
  self.meta = dofile(META_FILE_PATH)

  -- init settings
  self.settings = LuaSettings:open(self.settings_file)

  -- Load UI providers from settings and merge with file config
  local ui_data = Registry.load(self.settings)
  local merged_ps = Registry.merge(CONFIGURATION, ui_data)
  self._ui_provider_data = ui_data  -- kept for Add/Delete from Settings UI

  -- Build effective CONFIGURATION (file config as base + merged provider_settings)
  local effective = {}
  if CONFIGURATION then
    for k, v in pairs(CONFIGURATION) do
      effective[k] = v
    end
  end
  effective.provider_settings = merged_ps or {}
  self.CONFIGURATION = effective

  -- Register actions with dispatcher for gesture assignment
  self:onDispatcherRegisterActions()

  -- Register menu to main menu (under "tools") - for both reader and filemanager
  self.ui.menu:registerToMainMenu(self)

  if self.ui.document then
    -- Reader specific initialization
    -- Assistant button in highlight dialog
    self.ui.highlight:addToHighlightDialog("ai_assistant", function(_reader_highlight_instance)
      return {
        text = _("AI Assistant"),
        enabled = Device:hasClipboard(),
        callback = function()
          if not self:isConfigured() then
            return
          end

          NetworkMgr:runWhenOnline(function()
            if not updateMessageShown then
              Updater.checkForUpdates(self)
              updateMessageShown = true
            end
            UIManager:nextTick(function()
              -- Show the main AI dialog with highlighted text
              self.assistant_dialog:show(_reader_highlight_instance.selected_text.text)
            end)
          end)
        end,
        hold_callback = function()
          self:_help_dialog()
        end,
      }
    end)
  end

  -- skip initialization if no provider is configured (file or UI)
  if not merged_ps then return end

  -- Sync provider selection from configuration if configuration provider changed
  self:syncProviderSelectionFromConfig()

  local model_provider = self:getModelProvider()
  if not model_provider then
    CONFIG_LOAD_ERROR = _("configuration.lua: model providers are invalid.")
    return
  end

  -- Load the model provider from settings or default configuration
  self.querier = require("assistant_querier"):new({
    assistant = self,
    settings = self.settings,
  })

  local ok, err = self.querier:load_model(model_provider)
  if not ok then
    CONFIG_LOAD_ERROR = err
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
    return
  end

  -- store the UI language
  local ui_locale = G_reader_settings:readSetting("language") or "en"
  self.ui_language = Language:getLanguageName(ui_locale) or "English"
  self.ui_language_is_rtl = Language:isLanguageRTL(ui_locale)

  -- Conditionally override translate method based on user setting
  self:syncTranslateOverride()

  -- Register Assistant buttons with new KOReader dict API (PR #15184+)
  -- Safe no-op on older versions where addToDictButtons doesn't exist.
  if self.ui and self.ui.dictionary
      and type(self.ui.dictionary.addToDictButtons) == "function" then
    local button_ids = {}
    for _, button in ipairs(self:_buildAssistantDictButtons(nil, true)) do
      self.ui.dictionary:addToDictButtons(button)
      table.insert(button_ids, button.id)
    end
    self:_groupDictButtonsInDefaultLayout(button_ids)
    self:_restoreDictButtonsInUserLayout(button_ids)
  end


  self.assistant_dialog = AssistantDialog:new(self, CONFIGURATION)

  if self.ui.document then
    -- Reader specific
    -- Auto Recap Feature (hook before a book is opened)
    if self.settings:readSetting("enable_auto_recap", false) then
      self:_hookRecap()
    end

    self:_rebuildShowOnMainButtons()
  end
end

-- Rebuild the highlight-menu buttons from the current showOnMain settings.
-- Called at init() and whenever web search setting changes (so the 🌐 icon
-- stays in sync).  addMainButton already calls removeFromHighlightDialog
-- before re-adding, so re-registering existing keys is safe.
function Assistant:_rebuildShowOnMainButtons()
  if not self.ui.document then return end

  Prompts.invalidateCache()
  Prompts.getMergedPrompts(koutil.tableGetValue(CONFIGURATION, "features", "prompts"))

  local showOnMain = Prompts.getSortedPrompts(function (prompt, idx)
    if prompt.visible == false then
      return false
    end

    --  set in runtime settings (by holding the prompt button)
    local menukey = string.format("assistant_%02d_%s", prompt.order or 1000, idx)
    local settingkey = "showOnMain_" .. menukey
    if self.settings:has(settingkey) then
      return self.settings:isTrue(settingkey)
    end

    -- set in configure file
    if prompt.show_on_main_popup then
      return true
    end

    return false -- only show if `show_on_main_popup` is true
  end, Prompts.isWebSearchEnabled(self.settings)) or {}

  for _, tab in ipairs(showOnMain) do
    self:addMainButton(tab.idx, tab)
  end
end

function Assistant:_help_dialog()
    local info_text = string.format("%s %s  ", self.meta.fullname, self.meta.version) .. _([[Usage Tips

Select:
Highlight text (or a word) in the book, then press [AI assistant] in the poped up menu.

Long Press:
- On a Prompt Button: Add to the highlight menu.
- On a highlight menu button to remove it.
- On the Close button to go back to the book in 1 step.

Very-Long Press (over 3 seconds):
On a single word in the book to show the highlight menu (instead of the dictionary).

Multi-Swipe (e.g., ⮠, ⮡, ↺):
On the result dialog to close (as the Close button is far to reach).
]])
    UIManager:show(ConfirmBox:new{
        icon = "info",
        text = info_text,
        face = Font:getFace("xx_smallinfofont"),
        other_buttons = {{
          {
            text = _("Version Info"),
            callback = function()
              self:showAboutDialog()
            end,
          },
        }},
        ok_text = _("Purge Settings"),
        ok_callback = function()
          UIManager:show(ConfirmBox:new{
            text = _([[Are you sure to purge the assistant plugin settings? 
This resets the assistant plugin to the status the first time you installed it.

configuration.lua is safe, only the settings are purged.]]),
            ok_text = _("Purge"),
            ok_callback = function()
              self.settings:reset({})
              self.settings:flush()
              UIManager:askForRestart()
            end
          })
        end
    })
end

function Assistant:addMainButton(prompt_idx, prompt)
  local menukey = string.format("assistant_%02d_%s", prompt.order, prompt_idx)
  self.ui.highlight:removeFromHighlightDialog(menukey) -- avoid duplication
  self.ui.highlight:addToHighlightDialog(menukey, function(_reader_highlight_instance)
    local ws_enabled = Prompts.isWebSearchEnabled(self.settings)
    local btntext = Prompts.getDisplayText(prompt.text or prompt_idx,
      prompt.use_websearch or false, ws_enabled) .. " (AI)"  -- append "(AI)" to identify as our function
    return {
      text = btntext,
      callback = function()
        if prompt_idx == "quick_note" then
          Trapper:wrap(function()
            if not self.quicknote then
              local QuickNote = require("assistant_quicknote")
              self.quicknote = QuickNote:new(self)
            end
            self.quicknote:saveNote(nil, _reader_highlight_instance.selected_text.text)
          end)
        else
          NetworkMgr:runWhenOnline(function()
            Trapper:wrap(function()
              if prompt.order == -10 and prompt_idx == "dictionary" then
                -- Dictionary prompt, show dictionary dialog
                showDictionaryDialog(self, _reader_highlight_instance.selected_text.text)
              elseif prompt_idx == "term_xray" then
                -- Special case for term_xray prompt - use dictionary dialog with enhanced context
                showDictionaryDialog(self, _reader_highlight_instance.selected_text.text, nil, "term_xray")
              else
                -- For other prompts, show the custom prompt dialog
                self.assistant_dialog:showPrompt(_reader_highlight_instance.selected_text.text, prompt_idx)
              end
            end)
          end)
        end
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

-- Builds the Assistant button specs for the dict popup.
-- Used by both the new addToDictButtons API and the legacy onDictButtonsReady hook.
-- Returns an array of button specs.
--
-- `live` is set for the new API: the specs are registered once at init(), so
-- our settings must be read through show_func/text_func to let every popup see
-- their current value.  The legacy hook runs for each popup, so there the
-- settings are simply resolved right here.
function Assistant:_buildAssistantDictButtons(dict_popup_arg, live)
  if not CONFIGURATION then return {} end

  local plugin_buttons = {}
  local enabled_count = 0

  -- Appends a spec, gated by one of our `dict_popup_show_*` settings.
  local function addButton(setting_key, default, spec)
    if self.settings:readSetting(setting_key, default) then
      enabled_count = enabled_count + 1
    elseif not live then
      return -- legacy hook: hidden buttons are simply not built
    end
    if live then
      -- `menu_text` is what puts the button in KOReader's "Customize buttons"
      -- selector.  Without it the selector doesn't know the button, and the
      -- first time the user sorts/toggles anything there our buttons are
      -- dropped from the saved dict_button_config for good.
      spec.menu_text = spec.menu_text or spec.text
      spec.show_func = function()
        return self.settings:readSetting(setting_key, default) and true or false
      end
    end
    table.insert(plugin_buttons, spec)
  end

  -- Label with the web search indicator resolved at call time.
  local function displayText(label, use_websearch)
    return Prompts.getDisplayText(label, use_websearch or false,
      Prompts.isWebSearchEnabled(self.settings)) .. " (AI)"
  end

  addButton("dict_popup_show_wikipedia", true, {
    id = "assistant_wikipedia",
    font_bold = true,
    menu_text = _("Wikipedia") .. " (AI)",
    text_func = function()
      return displayText(_("Wikipedia"),
        koutil.tableGetValue(Prompts.builtin_prompts, "wikipedia", "use_websearch"))
    end,
    callback = function(widget_instance)
        local popup = widget_instance or dict_popup_arg
        local word = popup and popup.word
        NetworkMgr:runWhenOnline(function()
            Trapper:wrap(function()
              self.assistant_dialog:showPrompt(word, "wikipedia")
            end)
        end)
    end,
  })

  addButton("dict_popup_show_term_xray", false, {
    id = "assistant_term_xray",
    font_bold = true,
    menu_text = _("Term X-Ray") .. " (AI)",
    text_func = function()
      return displayText(_("Term X-Ray"),
        koutil.tableGetValue(Prompts.builtin_prompts, "term_xray", "use_websearch"))
    end,
    callback = function(widget_instance)
        local popup = widget_instance or dict_popup_arg
        local word = popup and popup.word
        NetworkMgr:runWhenOnline(function()
            Trapper:wrap(function()
              showDictionaryDialog(self, word, nil, "term_xray")
            end)
        end)
    end,
  })

  addButton("dict_popup_show_dictionary", true, {
    id = "assistant_dictionary",
    font_bold = true,
    text = _("Dictionary") .. " (AI)",
    callback = function(widget_instance)
        local popup = widget_instance or dict_popup_arg
        local word = popup and popup.word
        NetworkMgr:runWhenOnline(function()
            Trapper:wrap(function()
              showDictionaryDialog(self, word)
            end)
        end)
    end,
  })

  if live or self.settings:readSetting("dict_popup_show_custom_prompts", false) then
    -- Collect custom prompts with show_on_dictionary_popup = true
    local custom_prompts = {}
    if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.prompts then
      for prompt_key, prompt_config in pairs(CONFIGURATION.features.prompts) do
        if prompt_config.show_on_dictionary_popup == true and prompt_config.visible ~= false then
          table.insert(custom_prompts, {
            id = prompt_key,
            config = prompt_config
          })
        end
      end
    end

    -- Calculate how many custom prompts to add (max 3 total buttons)
    local max_custom_to_add = math.max(0, 3 - enabled_count)
    local custom_to_add = math.min(#custom_prompts, max_custom_to_add)

    -- Add custom prompts as buttons
    for i = 1, custom_to_add do
      local prompt = custom_prompts[i]
      addButton("dict_popup_show_custom_prompts", false, {
        id = "assistant_" .. prompt.id,
        font_bold = true,
        menu_text = (prompt.config.text or prompt.id) .. " (AI)",
        text_func = function()
          return displayText(prompt.config.text or prompt.id, prompt.config.use_websearch)
        end,
        callback = function(widget_instance)
            local popup = widget_instance or dict_popup_arg
            local word = popup and popup.word
            NetworkMgr:runWhenOnline(function()
                Trapper:wrap(function()
                  self.assistant_dialog:showPrompt(word, prompt.id)
                end)
            end)
        end,
      })
    end
  end

  if not live then
    -- The legacy hook builds plain buttons: resolve the labels now.
    for _, spec in ipairs(plugin_buttons) do
      if spec.text_func then
        spec.text = spec.text_func()
        spec.text_func = nil
      end
    end
  end

  return plugin_buttons
end

-- Is `button_id` used anywhere in a dict button layout (a list of rows of ids)?
local function layoutHasButtonId(layout, button_id)
  for _, row in ipairs(layout or {}) do
    for _, id in ipairs(row) do
      if id == button_id then return true end
    end
  end
  return false
end

-- KOReader appends one full width row per plugin button to its default layout.
-- Claim a single shared row instead (as the pre-addToDictButtons hook did), so
-- a fresh install doesn't get a popup stacked with one-button rows.
-- Only affects users who never customized their dictionary buttons.
function Assistant:_groupDictButtonsInDefaultLayout(button_ids)
  local default_layout = self.ui.dictionary.default_layout
  if not default_layout then return end

  local row = {}
  for _, id in ipairs(button_ids) do
    if not layoutHasButtonId(default_layout, id) then
      table.insert(row, id)
      if #row == 3 then -- keep rows at KOReader's default width
        table.insert(default_layout, 2, row)
        row = {}
      end
    end
  end
  if #row > 0 then
    table.insert(default_layout, 2, row)
  end
end

-- One time repair of the saved dictionary button layout.
-- Our buttons used to be registered without a `menu_text`, so KOReader's
-- "Customize buttons" selector didn't list them: as soon as the user sorted or
-- toggled any dictionary button, the regenerated dict_button_config silently
-- lost the Assistant buttons, with no way to get them back (that layout lives
-- in KOReader's global settings, so even reinstalling the plugin doesn't help).
-- Re-add each id once; whether the button is actually drawn stays under our own
-- `dict_popup_show_*` settings (show_func), and removing it again in the
-- selector now sticks.
function Assistant:_restoreDictButtonsInUserLayout(button_ids)
  local config = G_reader_settings:readSetting("dict_button_config")
  if not (config and config.layout) then return end -- never customized, nothing to repair

  local layout_changed = false
  for _, id in ipairs(button_ids) do
    local restore_flag = "dict_button_restored_" .. id
    if not self.settings:isTrue(restore_flag) then
      self.settings:saveSetting(restore_flag, true)
      self.updated = true
      if not layoutHasButtonId(config.layout, id) then
        local last_idx = #config.layout
        local row = config.layout[last_idx]
        local max_in_row = koutil.tableGetValue(config, "row_count", last_idx) or 3
        if not row or #row >= max_in_row then
          row = {}
          table.insert(config.layout, row)
          if config.row_count then
            config.row_count[#config.layout] = 3
          end
        end
        table.insert(row, id)
        if config.order and not layoutHasButtonId({ config.order }, id) then
          table.insert(config.order, id) -- `order` is a flat list, i.e. a single row
        end
        layout_changed = true
      end
    end
  end

  if layout_changed then
    G_reader_settings:saveSetting("dict_button_config", config)
  end
end

function Assistant:onDictButtonsReady(dict_popup, dict_buttons)
  if not CONFIGURATION then return end
  -- If new KOReader API is present, we already registered at init() time.
  -- This hook won't be called on new KOReader anyway, but guard for safety.
  if self.ui and self.ui.dictionary
      and type(self.ui.dictionary.addToDictButtons) == "function" then
    return
  end

  local plugin_buttons = {}
  local buttons = self:_buildAssistantDictButtons(dict_popup)
  for _, btn in ipairs(buttons) do
    table.insert(plugin_buttons, {
      id = btn.id,
      font_bold = btn.font_bold,
      text = btn.text,
      callback = function() btn.callback(nil) end,
    })
  end

  if #plugin_buttons > 0 and #dict_buttons > 1 then
    table.insert(dict_buttons, 2, plugin_buttons)
  end
end

  -- Event handlers for gesture-triggered actions
  function Assistant:onAskAIQuestion()
    if not self:isConfigured() then
      return
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
    if not self:isConfigured() then return end
    NetworkMgr:runWhenOnline(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "recap", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  function Assistant:onAskAIXRay()
    if not self:isConfigured() then return end
    NetworkMgr:runWhenOnline(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "xray", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  function Assistant:onAskAIBookInfo()
    if not self:isConfigured() then return end
    NetworkMgr:runWhenOnline(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "book_info", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  function Assistant:onAskAIAnnotations()
    if not self:isConfigured() then return end
    NetworkMgr:runWhenOnline(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "annotations", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  function Assistant:onAskSummaryUsingAnnotations()
    if not self:isConfigured() then return end
    NetworkMgr:runWhenOnline(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "summary_using_annotations", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  function Assistant:onAskAIQuickNote()
    if not self:isConfigured() then return end
    -- Initialize quicknote if not already done
    if not self.quicknote then
      local QuickNote = require("assistant_quicknote")
      self.quicknote = QuickNote:new(self)
    end
    self.quicknote:show()
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

      local words = koutil.splitToWords(text)
      NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
          -- splitToWords result like this: { "The", " ", "good", " ", "news" }
          if #words > 5 then
              self.assistant_dialog:showPrompt(text, "translate")
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
  -- use merged prompts: prompts defined only in configuration.lua
  -- are absent from the built-in `builtin_prompts` table
  local prompt = Prompts.getMergedPrompts(
    koutil.tableGetValue(CONFIGURATION, "features", "prompts"))[idx]
  local ws_enabled = Prompts.isWebSearchEnabled(self.settings)
  local display_text = Prompts.getDisplayText(prompt.text or idx, prompt.use_websearch or false, ws_enabled)

  if action == "add" then
    self.settings:makeTrue(settingkey)
    self.updated = true
    self:addMainButton(idx, prompt)
    UIManager:show(InfoMessage:new{
      text = ASUtils.bold_format(
        T(_("<b>Added</b> [%1 (AI)] to Highlight Menu."), display_text)
      ),
      icon = "notice-info",
      timeout = 3
    })
  elseif action == "remove" then
    self.settings:makeFalse(settingkey)
    self.updated = true
    self.ui.highlight:removeFromHighlightDialog(menukey)
    UIManager:show(InfoMessage:new{
      text = ASUtils.bold_format(
        T(_("<b>Removed</b> [%1 (AI)] from Highlight Menu."), display_text)
      ),
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
        local timeDiffHours = math.floor((os.time() - lastAccess) / 3600)
  
        -- More than 28hrs since last open and less than 95% complete
        -- percent = 0 may means the book is not started yet, the docsettings maybe empty
        if timeDiffHours >= 28 and percent_finished > 0 and percent_finished <= 0.95 then 
          -- Construct the message to display.
          local doc_props = doc_settings:child("doc_props")
          local title = doc_props:readSetting("title", "Unknown Title")
          local authors = doc_props:readSetting("authors", "Unknown Author")
          local message = T(_("Do you want an AI Recap?\nFor %1 by %2.\n\n"), title, authors)
                    .. T(N_("Last read an hour ago.", "Last read %1 hours ago.", timeDiffHours), timeDiffHours)
  
          -- Display the request popup using ConfirmBox.
          UIManager:show(ConfirmBox:new{
            text            = message,
            ok_text         = _("Yes"),
            ok_callback     = function()
              NetworkMgr:runWhenOnline(function()
                local showFeatureDialog = require("assistant_featuredialog")
                Trapper:wrap(function()
                  showFeatureDialog(assistant, "recap", title, authors, percent_finished)
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

  local config_provider = koutil.tableGetValue(conf, "provider")
  if not config_provider or config_provider == "" then return end

  local previous_config_ai_provider = self.settings:readSetting("previous_config_ai_provider")
  if previous_config_ai_provider ~= config_provider then
    -- Config changed (or first install). Mark config's provider as selected and remember it.
    self.settings:saveSetting("provider", config_provider)
    self.settings:saveSetting("previous_config_ai_provider", config_provider)
    self.updated = true
  end
end

function Assistant:showAboutDialog()
  local md_renderer = "Pure MD"
  if package.preload["resty.hoedown.library"] then
    md_renderer = "libhoedown"
  end

  local Version = require("version")

  UIManager:show(InfoMessage:new{
      show_icon = false,
      text = ASUtils.bold_format(
        T("<b>%1 %2</b>\n――――――――――――――――\n<b>%3:</b> %4\n<b>%5:</b> %6\n<b>%7:</b> %8\n<b>%9:</b> %10/%11\n<b>%12:</b> %13",
          self.meta.fullname, self.meta.version,
          _("Markdown Engine"), md_renderer,
          _("KOReader"), Version:getShortVersion(),
          _("Device"), Device.model or "?",
          _("Platform"), jit.os, jit.arch,
          _("Runtime"), jit.version
        )
      ),
  })
end

return Assistant
