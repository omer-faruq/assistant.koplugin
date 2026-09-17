local Device = require("device")
local logger = require("logger")
local Event = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
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
local Notebook = require("assistant_notebook")

local _ = require("assistant_gettext")
local N_ = _.ngettext
local AssistantDialog = require("assistant_dialog")
local Updater = require("assistant_updater")
local Prompts = require("assistant_prompts")
local SettingsDialog = require("assistant_settings")
local showDictionaryDialog = require("assistant_dictdialog")
local Registry = require("assistant_provider_registry")
local SearchRegistry = require("assistant_search_registry")
local Config = require("assistant_config")

-- Single row id for the FileManager long-press AI buttons.
-- One row_func returns one row, so both buttons share this id to sit
-- on the same line.
local FM_AI_ROW_ID = "assistant_ai"

-- Browser widgets sharing the FileManager long-press file_dialog mechanism.
-- coverbrowser.koplugin registers its rows on the same four classes.
local FILE_DIALOG_WIDGET_MODULES = {
  "apps/filemanager/filemanager",
  "apps/filemanager/filemanagerhistory",
  "apps/filemanager/filemanagercollection",
  "apps/filemanager/filemanagerfilesearcher",
}

-- Requires the browser widget classes (best effort: a tree may miss some),
-- returning an array of widget tables.
local function getFileDialogWidgets()
  local widgets = {}
  for i, name in ipairs(FILE_DIALOG_WIDGET_MODULES) do
    local ok, widget = pcall(require, name)
    if ok and type(widget) == "table" then
      table.insert(widgets, widget)
    end
  end
  return widgets
end

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
  config = nil,  -- Config object (assistant_config.lua)
}

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
    -- @translators Action title. "Recap" is short for "recapitulation": a brief spoiler-free summary of what the reader has already read, to refresh memory. Keep consistent with "Recap" / "AI Recap" elsewhere.
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
                text = _("Ask a Question"),
                callback = function ()
                  self:onAskAIQuestion()
                end,
                hold_callback = function ()
                  UIManager:show(InfoMessage:new{
                    text = _("Enter a question to ask the AI.")
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
                text_func = function ()
                  if not self.ui.doc_settings and Notebook.isEnabled(self) then
                    return T(
                      _("Notebook: %1"),
                      Notebook.getActiveDisplayName(self, 24)
                    )
                  end
                  return _("Notebook (AI Conversation Log)")
                end,
                callback = function ()
                  local is_general_mode = not self.ui.doc_settings
                  local multi_enabled = Notebook.isEnabled(self)

                  local function showNotebookFileDialog(notebookfile, include_switch, include_edit)
                    local other_buttons = {}
                    local notebook_dialog

                    if include_switch then
                      table.insert(other_buttons, {
                        text = _("Switch"),
                        callback = function ()
                          Notebook.showPicker(self, {
                            on_select = function ()
                              -- Close the old details dialog because it still
                              -- refers to the previously active notebook.
                              if notebook_dialog then
                                UIManager:close(notebook_dialog)
                              end
                            end,
                          })
                        end
                      })
                    end

                    table.insert(other_buttons, {
                      text = _("Delete"),
                      callback = function ()
                        UIManager:show(ConfirmBox:new{
                          text = T(_("Delete file?\n%1\nThis operation is not reversible."), notebookfile),
                          ok_text = _("Delete"),
                          ok_callback = function ()
                            local ok, err = koutil.removeFile(notebookfile)
                            if not ok then
                              UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
                              return
                            end
                            if notebook_dialog then
                              UIManager:close(notebook_dialog)
                            end
                          end
                        })
                      end
                    })

                    -- KOReader's ShowNotebookFile event edits the current book
                    -- notebook. Do not expose it for a general notebook path.
                    if include_edit then
                      table.insert(other_buttons, {
                        text = _("Edit"),
                        callback = function ()
                          UIManager:broadcastEvent(Event:new("ShowNotebookFile"))
                        end
                      })
                    end

                    notebook_dialog = ConfirmBox:new{
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
                      other_buttons = { other_buttons },
                    }
                    UIManager:show(notebook_dialog)
                  end

                  -- FileManager without an open book in multi-notebook mode:
                  -- pick the notebook first, then show its file dialog. The
                  -- picker itself is the selection, so no Switch button.
                  if is_general_mode and multi_enabled then
                    Notebook.showPicker(self, {
                      title = _("Notebooks"),
                      on_select = function(notebook)
                        if notebook and notebook.path then
                          showNotebookFileDialog(notebook.path, false, false)
                        end
                      end,
                    })
                    return
                  end

                  local notebookfile
                  if is_general_mode then
                    notebookfile = Notebook.getGeneralNotebookFilePath(self)
                  else
                    notebookfile = self.ui.bookinfo:getNotebookFile(self.ui.doc_settings)
                  end
                  showNotebookFileDialog(
                    notebookfile,
                    is_general_mode and multi_enabled,
                    not is_general_mode
                  )
                end,
                separator = true,
              },
              {
                text_func = function ()
                  if not self.querier or not self.querier.handler then
                    return T(_("Provider %1 NOT CONFIGURED"), "▸")
                  end
                  local provider = self.querier.provider_setting
                      and self.querier.provider_setting.display_name
                      or self.querier.provider_name
                  local model = self.querier.handler.model or "?"
                  return T(_("Provider %1 %2(%3)"), "▸", provider, model)
                end,
                keep_menu_open = true,
                callback = function (touchmenu_instance)
                  -- Remember the menu so a confirmed provider edit can dismiss
                  -- it (the menu stays open behind the dialogs).
                  self._menu_instance = touchmenu_instance
                  self:showSettings(function ()
                    touchmenu_instance:updateItems()
                  end)
                end,
              },
              {
                  text_func = function ()
                    local key = self.settings:readSetting("use_websearch", "none")
                    local text = ToolExecutor.ToolToText(key)
                      return T(_("Web Search %1 %2"), "▸", text)
                  end,
                  hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                          text = _("Improves response accuracy with real-time web results. \nNote: Higher token usage and additional API charges apply.")
                      })
                  end,
                  sub_item_table = {},
              },
              {
                text = _("Settings"),
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
    table.insert(common_items_table[5].sub_item_table,
      SettingsDialog.genWebSearchSubMenuItem(self, n))
  end

  local book_level_items = {
              {
                text = _("Book Insights"),
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
                      -- @translators Menu entry. Same "Recap" feature as elsewhere: a brief spoiler-free summary of what the reader has already read. Keep consistent with "Recap" / "AI Recap".
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
            }

  -- Only show the Custom Prompts entry when book_level_prompts are actually
  -- configured. When absent, mark the Book Insights group with a trailing
  -- separator so it doesn't visually run into the next menu item.
  if self.config:getFeature("book_level_prompts") then
    table.insert(book_level_items, {
              text = _("Custom Prompts"),
              sub_item_table_func = function ()
                return BookLevelCustomPrompts(self)
              end,
              hold_callback = function ()
                UIManager:show(InfoMessage:new{
                  text = _("Your own prompts defined in the configuration file")
                })
              end,
              separator = true,
            })
  else
    book_level_items[1].separator = true
  end

    local reader_items_table = {}
    -- shallow copy of the common_items_table
    table.move(common_items_table, 1, #common_items_table, 1, reader_items_table)
    for i = #book_level_items,1,-1 do
      table.insert(reader_items_table, 2, book_level_items[i])
    end

    if self.ui.document then
        -- Reader menu. No separator after "Ask a Question": the book-level
        -- items carry the trailing separator (on Custom Prompts when
        -- configured, otherwise on Book Insights).
        common_items_table[1].separator = false
        menu_items.ai_assistant = {
            text = _("AI Assistant"),
            sorting_hint = "tools",
            hold_callback = function ()
              self:_help_dialog()
            end,
            sub_item_table = reader_items_table
          }
    else
        -- Filemanager menu. Separate "Ask a Question" from the notebook
        -- items that follow it.
        common_items_table[1].separator = true
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

-- FileManager-side metadata for book_info: no open document exists, and
-- book_info only needs title/author/language, so this never opens the
-- document (no body/toc/cover needed).
-- Priority: long-press book_props -> bookinfo:getDocProps(file, nil, true)
-- (metadata only, no open) -> sidecar DocSettings doc_props -> filename.
-- Reading progress comes from the sidecar percent_finished, or 0.
function Assistant:getDocumentInfoForFile(file, book_props)
  local function normAuthors(value)
    if type(value) == "table" then
      return table.concat(value, ", ")
    end
    return value
  end

  local title = koutil.tableGetValue(book_props, "title")
  local authors = normAuthors(koutil.tableGetValue(book_props, "authors"))

  if (not title or title == "") or (not authors or authors == "") then
    local bookinfo = koutil.tableGetValue(self, "ui", "bookinfo")
    if type(bookinfo) == "table" and type(bookinfo.getDocProps) == "function" then
      local ok, props = pcall(bookinfo.getDocProps, bookinfo, file, nil, true)
      if ok and type(props) == "table" then
        if not title or title == "" then
          title = koutil.tableGetValue(props, "title")
            or koutil.tableGetValue(props, "display_title")
        end
        if not authors or authors == "" then
          authors = normAuthors(koutil.tableGetValue(props, "authors"))
        end
      end
    end
  end

  local percent_finished = 0
  -- Prefer the BookList cache when available (cheap, synchronous): it is the
  -- most reliable progress source. Fall back to sidecar DocSettings below.
  local booklist_percent = nil
  local ok_booklist, BookList = pcall(require, "ui/widget/booklist")
  if ok_booklist and type(BookList) == "table"
    and type(BookList.getBookInfo) == "function" then
    local ok_info, info = pcall(BookList.getBookInfo, file)
    if ok_info and type(info) == "table"
      and type(info.percent_finished) == "number" then
      booklist_percent = info.percent_finished
    end
  end
  if type(booklist_percent) == "number" then
    percent_finished = booklist_percent
  end
  local ok_settings, doc_settings = pcall(function()
    return require("docsettings"):open(file)
  end)
  if ok_settings and doc_settings then
    if (not title or title == "") or (not authors or authors == "") then
      local ok_child, doc_props = pcall(function()
        return doc_settings:child("doc_props")
      end)
      if ok_child and doc_props then
        if not title or title == "" then
          local ok_t, v = pcall(function() return doc_props:readSetting("title") end)
          if ok_t and type(v) == "string" and v ~= "" then title = v end
        end
        if not authors or authors == "" then
          local ok_a, v = pcall(function() return doc_props:readSetting("authors") end)
          if ok_a then
            local norm = normAuthors(v)
            if type(norm) == "string" and norm ~= "" then authors = norm end
          end
        end
      end
    end
    local ok_p, v = pcall(function()
      return doc_settings:readSetting("percent_finished")
    end)
    if type(booklist_percent) ~= "number" and ok_p and type(v) == "number" then
      percent_finished = v
    end
  end

  if not title or title == "" then
    local ok_name, name = pcall(function()
      return require("apps/filemanager/filemanagerutil").splitFileNameType(file)
    end)
    if ok_name and type(name) == "string" and name ~= "" then
      title = name
    else
      title = file
    end
  end
  if not authors or authors == "" then
    authors = "Unknown Author"
  end

  return {
    title = title,
    authors = authors,
    percent_finished = percent_finished,
  }
end

-- Builds the FileManager long-press row with both AI buttons on one line.
-- One row_func returns one row, so returning two buttons here keeps them
-- side by side. Gate: directories and files without a document provider
-- return nil (no row). Missing files (e.g. deleted books still listed in
-- History) stay visible but disabled, matching how native file-dialog
-- buttons treat unavailable targets. Progress is NOT checked here: it
-- needs the BookList cache and is judged inside onAskAIRecapForFile,
-- keeping long-press cheap.
function Assistant:_buildFileDialogAIRow(file, is_file, book_props)
  if not is_file then return nil end
  if type(file) ~= "string" then return nil end
  local ok, DocumentRegistry = pcall(require, "document/documentregistry")
  if not ok or type(DocumentRegistry) ~= "table"
    or not DocumentRegistry:hasProvider(file) then
    return nil
  end
  local enabled = koutil.pathExists(file)
  return {
    {
      text = _("Book Info (AI)"),
      enabled = enabled,
      callback = function()
        self:_closeFileDialogs()
        self:onAskAIBookInfoForFile(file, book_props)
      end,
    },
    {
      text = _("Recap (AI)"),
      enabled = enabled,
      callback = function()
        self:_closeFileDialogs()
        self:onAskAIRecapForFile(file, book_props)
      end,
    },
  }
end

-- Close any open long-press file dialog before running book_info, so the
-- result viewer is not stacked behind it. The dialog owner varies by browser
-- (FileManager, History, Collections, FileSearcher), so try each widget's
-- current menu instance.
function Assistant:_closeFileDialogs()
  for i, widget in ipairs(getFileDialogWidgets()) do
    if type(widget.getMenuInstance) == "function" then
      local ok, menu = pcall(widget.getMenuInstance)
      if ok and type(menu) == "table" and menu.file_dialog then
        UIManager:close(menu.file_dialog)
      end
    end
  end
end

-- FileManager-side long-press AI buttons on one row (no book open).
-- Registered on every browser widget available, mirroring coverbrowser.
function Assistant:_registerFileDialogButtons()
  local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
  if not ok or type(FileManager) ~= "table"
    or type(FileManager.addFileDialogButtons) ~= "function" then
    return
  end
  for i, widget in ipairs(getFileDialogWidgets()) do
    FileManager.addFileDialogButtons(widget, FM_AI_ROW_ID,
      function(file, is_file, dialog_book_props)
        return self:_buildFileDialogAIRow(file, is_file, dialog_book_props)
      end)
  end
end

-- Paired with _registerFileDialogButtons: row_id is globally unique, and
-- addFileDialogButtons already dedupes, so re-registration is safe.
function Assistant:_removeFileDialogButtons()
  local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
  if not ok or type(FileManager) ~= "table"
    or type(FileManager.removeFileDialogButtons) ~= "function" then
    return
  end
  for i, widget in ipairs(getFileDialogWidgets()) do
    FileManager.removeFileDialogButtons(widget, FM_AI_ROW_ID)
  end
end

function BookLevelCustomPrompts(assistant)
  local sub_item_table = {}

  -- Read book_level_prompts from configuration
  local book_level_prompts = assistant.config:getFeature("book_level_prompts") or {}

  for key, prompt_config in ffiutil.orderedPairs(book_level_prompts) do
    if prompt_config.visible == true and prompt_config.type == "feature" then
      local button = {
        text = Prompts.getDisplayText(prompt_config.text or key,
          koutil.tableGetValue(prompt_config, "use_websearch") or false,
          Prompts.isWebSearchEnabled(assistant.settings)),
        callback = function()
          if not assistant:isConfigured() then return end
          ASUtils.runWhenOnlineFast(function()
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
      text = _("No valid custom prompt found"),
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
  if not self.config or not next(self.config:getProviderSettings()) then
    UIManager:show(InfoMessage:new{
      text = T(_("Add providers from the main menu:\n%1 -> AI Assistant -> Settings -> Provider API"), "⚙")
    })
    return
  end
  if not self:isConfigured() then return end

  if self._settings_dialog then
    -- If settings dialog is already open, just show it again
    UIManager:show(self._settings_dialog)
    return
  end

  -- Reopens (after add/edit/delete provider) inherit the caller's refresh hook
  -- so the main menu label keeps tracking the active provider/model.
  self._settings_close_callback = close_callback or self._settings_close_callback

  local settingDlg = SettingsDialog:new{
      assistant = self,
      settings = self.settings,
      close_callback = self._settings_close_callback,
  }

  self._settings_dialog = settingDlg -- store reference to the dialog
  UIManager:show(settingDlg)
end

--- Show the unified add/edit provider dialog.
--- Implementation lives in Registry.showProviderDialog; this thin wrapper
--- keeps a stable entry point for settings/menu callers.
function Assistant:_showAddProviderDialog(preset_name, handler, base_url, additional_parameters, edit_id)
    Registry.showProviderDialog(self, preset_name, handler, base_url, additional_parameters, edit_id)
end

--- Show a dialog for adding or editing a web search API tool.
--- Reuses MultiInputDialog style. Only shows the credential field:
---   - API key tools (SerpAPI, Tavily, Exa): API Key field only
---   - Base URL tools (SearXNG): Base URL field only
--- The display name comes from SEARCH_TOOLS and is not user-editable.
---@param tool_key string The fixed tool key (serpapi, tavilyapi, exaapi, searxngapi)
function Assistant:_showAddWebSearchDialog(tool_key)
    local tool_def = SearchRegistry.SEARCH_TOOLS[tool_key]
    if not tool_def then return end

    -- Pre-fill from existing UI record if present
    local existing = self._ui_search_data and self._ui_search_data.tools[tool_key]
    local default_key = existing and existing.api_key or ""
    local default_url = existing and existing.base_url or ""

    local is_edit = SearchRegistry.is_deletable(
        self.config:getProvider(tool_key))

    local title = is_edit and T(_("Edit %1"), tool_def.display_name)
        or T(_("Add %1"), tool_def.display_name)

    -- Build fields based on credential type (no display_name field)
    local fields
    if tool_def.needs == "api_key" then
        fields = {
            { description = _("API Key"), hint = _("Your API key"), text = default_key },
        }
    else  -- base_url
        fields = {
            { description = _("Base URL"), hint = _("https://..."), text = default_url },
        }
    end

    local dialog_ref = {}
    local dialog
    local function readFields()
        return ASUtils.trimDialogFields(dialog)
    end
    dialog = MultiInputDialog:new{
        title = title,
        fields = fields,
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("OK"),
                is_enter_default = true,
                callback = function()
                    local input_fields = readFields()

                    local api_key, base_url
                    if tool_def.needs == "api_key" then
                        api_key = input_fields[1]
                    else
                        base_url = input_fields[1]
                    end

                    -- SearchRegistry.validate (through installSearchTool) is the
                    -- shared normalization gate: it trims and rejects empty or
                    -- whitespace-laden credentials, returning the message.
                    local ok, err = SearchRegistry.installSearchTool(
                        self, tool_key, api_key, base_url)
                    if not ok then
                        UIManager:show(InfoMessage:new{
                            icon = "notice-warning",
                            text = err or _("Failed to save search tool."),
                        })
                        return
                    end

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

-- Effective configuration accessors are in assistant_config.lua (Config object).
-- Mounted as self.config during init(); all callers use self.config:get* etc.

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
    local err_text = ASUtils.bold_format(
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

    -- handle error message during loading
    local loadError = self.config and self.config:getLoadError()
    if loadError and type(loadError) == "string" then
      -- keep the error message clean
      local cut = loadError:find("configuration.lua", 1, true) or 0 -- find as plain
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
  -- loading our own _meta.lua
  self.meta = dofile(Config.getMetaPath())

  -- init settings
  self.settings = LuaSettings:open(self.settings_file)

  -- Initialize UI state independently of provider configuration. Menus and
  -- Settings can be opened before a provider is added through the UI.
  local ui_locale = G_reader_settings:readSetting("language") or "en"
  self.ui_language = Language:getLanguageName(ui_locale) or "English"
  self.ui_language_is_rtl = Language:isLanguageRTL(ui_locale)

  -- Build effective CONFIGURATION.
  -- RAW is the configuration loaded via dofile(configuration.lua);
  -- shallow-copies RAW tables (e.g. features) while provider_settings is rebuilt.
  local rawConfig, loadError = Config.loadRawConfig()
  self.config = Config:new{ assistant = self, data = rawConfig or {}, loadError = loadError }
  self.config:buildEffectiveConfig()

  -- Register actions with dispatcher for gesture assignment
  self:onDispatcherRegisterActions()

  -- Register menu to main menu (under "tools") - for both reader and filemanager
  self.ui.menu:registerToMainMenu(self)

  if not self.ui.document then
    -- FileManager side (no open document): long-press "Book Info (AI)" button.
    -- Registered before the provider early-return below so the entry exists
    -- even when providers are added later through the UI; the callback itself
    -- re-checks isConfigured().
    self:_registerFileDialogButtons()
  end

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

          ASUtils.runWhenOnlineFast(function()
            -- Throttled inside updater: only hits network if 48h passed since last check
            Updater.checkForUpdates(self)
            UIManager:nextTick(function()
              -- Show the main AI dialog with highlighted text
              self.assistant_dialog:showAskDialog(_reader_highlight_instance.selected_text.text)
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
  if not next(self.config:getProviderSettings()) then return end

  -- A missing/optional configuration.lua leaves a stale load error in
  -- self.config._loadError.  With at least one provider available (e.g.
  -- UI-only) the plugin is configured, so clear it before provider
  -- selection/querier validation below (those paths re-set the error on failure).
  self.config:clearLoadError()

  -- Sync provider selection from configuration if configuration provider changed
  self:syncProviderSelectionFromConfig()

  local model_provider = self.config:getActiveProviderId()
  if not model_provider then
    self.config:setLoadError(_("configuration.lua: model providers are invalid."))
    return
  end

  -- Load the model provider from settings or default configuration
  self.querier = require("assistant_querier"):new({
    assistant = self,
    settings = self.settings,
  })

  local ok, err = self.querier:load_model(model_provider)
  if not ok then
    self.config:setLoadError(err)
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
    return
  end

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


  self.assistant_dialog = AssistantDialog:new(self)

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
  Prompts.getMergedPrompts(self.config:getFeature("prompts"))

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
    local info_text = string.format("%s %s  ", self.meta.fullname, self.meta.version) .. T(_([[Usage Tips

Select:
Highlight text (or a word) in the book, then press [AI assistant] in the poped up menu.

Long Press:
- On a Prompt Button: Add to the highlight menu.
- On a highlight menu button to remove it.
- On the Close button to go back to the book in 1 step.

Very-Long Press (over 3 seconds):
On a single word in the book to show the highlight menu (instead of the dictionary).

Multi-Swipe (e.g., %1, %2, %3):
On the result dialog to close (as the Close button is far to reach).
]]), "⮠", "⮡", "↺")
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
          ASUtils.runWhenOnlineFast(function()
            Trapper:wrap(function()
              if prompt.order == -10 and prompt_idx == "dictionary" then
                -- Dictionary prompt, show dictionary dialog
                showDictionaryDialog(self, _reader_highlight_instance.selected_text.text)
              elseif prompt_idx == "term_xray" then
                -- Special case for term_xray prompt - use dictionary dialog with enhanced context
                showDictionaryDialog(self, _reader_highlight_instance.selected_text.text, nil, "term_xray")
              elseif prompt_idx == "translate" then
                -- Same Smart Dictionary Lookup routing as KOReader's built-in Translate
                self:showTranslateOrDictionary(_reader_highlight_instance.selected_text.text)
              else
                -- For other prompts, show the custom prompt dialog
                self.assistant_dialog:runPrompt(_reader_highlight_instance.selected_text.text, prompt_idx)
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
  if not self.config then return {} end

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
        ASUtils.runWhenOnlineFast(function()
            Trapper:wrap(function()
              self.assistant_dialog:runPrompt(word, "wikipedia")
            end)
        end)
    end,
  })

  addButton("dict_popup_show_term_xray", false, {
    id = "assistant_term_xray",
    font_bold = true,
    -- @translators Button label. Same "Term X-Ray" feature as elsewhere: explains the selected word by scanning every occurrence across the book. Translate consistently with the other "Term X-Ray" button. Keep it short.
    menu_text = _("Term X-Ray") .. " (AI)",
    text_func = function()
      -- @translators Button label. Same "Term X-Ray" feature as elsewhere: explains the selected word by scanning every occurrence across the book. Translate consistently with the other "Term X-Ray" button. Keep it short.
      return displayText(_("Term X-Ray"),
        koutil.tableGetValue(Prompts.builtin_prompts, "term_xray", "use_websearch"))
    end,
    callback = function(widget_instance)
        local popup = widget_instance or dict_popup_arg
        local word = popup and popup.word
        ASUtils.runWhenOnlineFast(function()
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
        ASUtils.runWhenOnlineFast(function()
            Trapper:wrap(function()
              showDictionaryDialog(self, word)
            end)
        end)
    end,
  })

  if live or self.settings:readSetting("dict_popup_show_custom_prompts", false) then
    -- Collect custom prompts with show_on_dictionary_popup = true
    local custom_prompts = {}
    local prompts = self.config:getFeature("prompts")
    if prompts then
      for prompt_key, prompt_config in pairs(prompts) do
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
            ASUtils.runWhenOnlineFast(function()
                Trapper:wrap(function()
                  self.assistant_dialog:runPrompt(word, prompt.id)
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
  if not self.config then return end
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
    
    ASUtils.runWhenOnlineFast(function()
      -- Show dialog without highlighted text
      Trapper:wrap(function()
        self.assistant_dialog:showAskDialog()
      end)
    end)
    return true
  end

  function Assistant:onAskAIRecap()
    if not self:isConfigured() then return end
    ASUtils.runWhenOnlineFast(function()
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
    ASUtils.runWhenOnlineFast(function()
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
    if not koutil.tableGetValue(self, "ui", "document") then
      UIManager:show(InfoMessage:new{
        text = _("No book is open. Long-press a book in the file manager and choose Book Info (AI).")
      })
      return true
    end
    ASUtils.runWhenOnlineFast(function()
      local book = getDocumentInfo(self.ui.document)
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "book_info", book.title, book.authors, book.percent_finished)
      end)
    end)
    return true
  end

  -- FileManager-side book_info: metadata comes from the file, not an open doc.
  function Assistant:onAskAIBookInfoForFile(file, book_props)
    if not self:isConfigured() then return end
    ASUtils.runWhenOnlineFast(function()
      local book = self:getDocumentInfoForFile(file, book_props)
      local notebook_path
      if Notebook.isEnabled(self) then
        local ok, path = pcall(Notebook.getBookNotebookPath, self, file)
        if ok and type(path) == "string" and path ~= "" then
          notebook_path = path
        elseif not ok then
          logger.warn("Assistant: Could not compute per-book notebook path:", path)
        end
      end
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "book_info", book.title, book.authors, book.percent_finished, nil, notebook_path)
      end)
    end)
    return true
  end

  -- FileManager-side recap: degraded version without book text (no document
  -- open), so require proof the book was opened and started. Never opens the
  -- document here.
  function Assistant:onAskAIRecapForFile(file, book_props)
    if not self:isConfigured() then return end
    local book = self:getDocumentInfoForFile(file, book_props)
    local been_opened = nil
    local list_percent = nil
    local ok_list, BookList = pcall(require, "ui/widget/booklist")
    if ok_list and type(BookList) == "table"
      and type(BookList.getBookInfo) == "function" then
      local ok_info, info = pcall(BookList.getBookInfo, file)
      if ok_info and type(info) == "table" then
        been_opened = info.been_opened
        if type(info.percent_finished) == "number" then
          list_percent = info.percent_finished
        end
      end
    end
    local percent = list_percent
    if type(percent) ~= "number" then
      percent = book.percent_finished
    end
    if type(percent) ~= "number" then
      percent = 0
    end
    if been_opened == nil then
      been_opened = percent > 0
    end
    if not been_opened or percent <= 0 then
      UIManager:show(InfoMessage:new{
        text = _("Please open this book and start reading before requesting a recap.")
      })
      return true
    end
    local notebook_path
    if Notebook.isEnabled(self) then
      local ok, path = pcall(Notebook.getBookNotebookPath, self, file)
      if ok and type(path) == "string" and path ~= "" then
        notebook_path = path
      elseif not ok then
        logger.warn("Assistant: Could not compute per-book notebook path:", path)
      end
    end
    ASUtils.runWhenOnlineFast(function()
      local showFeatureDialog = require("assistant_featuredialog")
      Trapper:wrap(function()
        showFeatureDialog(self, "recap", book.title, book.authors, percent, nil, notebook_path)
      end)
    end)
    return true
  end

  function Assistant:onAskAIAnnotations()
    if not self:isConfigured() then return end
    ASUtils.runWhenOnlineFast(function()
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
    ASUtils.runWhenOnlineFast(function()
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

-- Route a translate request through Smart Dictionary Lookup: short selections
-- may open the AI Dictionary instead (see ASUtils.lookup_mode_for_selection),
-- with a one-time three-way prompt on first use. Callers must already be inside
-- ASUtils.runWhenOnlineFast + Trapper:wrap.
function Assistant:showTranslateOrDictionary(text)
  local function open_translation()
    self.assistant_dialog:runPrompt(text, "translate")
  end
  local function open_dictionary()
    showDictionaryDialog(self, text)
  end

  -- No default: a truthy default would be written by LuaSettings:readSetting,
  -- destroying the "never asked" (nil) state.
  local choice = self.settings:readSetting("ai_smart_dictionary")
  local mode = ASUtils.lookup_mode_for_selection(text)
  local route = ASUtils.resolve_translate_route(choice, mode)

  if route == "ask" then
    -- Three-way first-run choice in a single button row:
    --   Translate  -> persist "off", never ask again
    --   Dictionary -> persist "on", never ask again
    --   Cancel / dismiss -> abort this action; leave the setting unset
    --     so the next short selection asks again
    local ask_dialog
    ask_dialog = ButtonDialog:new{
      title = ASUtils.bold_format(_("Dictionary or Translation?\n\nThis selection looks like a word or short phrase.\n\nYou can change this later in Settings > Other Settings > Smart Dictionary Lookup for 'Translate'.")),
      title_align = "left",
      info_face = Font:getFace("smallinfofont"),
      buttons = {{
        {
          text = _("Cancel"),
          callback = function()
            -- Abort: no translation, no persistence.
            UIManager:close(ask_dialog)
          end,
        },
        {
          text = _("Translate"),
          callback = function()
            self.settings:saveSetting("ai_smart_dictionary", false)
            self.updated = true -- persist choice on next FlushSettings
            UIManager:close(ask_dialog)
            ASUtils.runWhenOnlineFast(function() Trapper:wrap(open_translation) end)
          end,
        },
        {
          text = _("Dictionary"),
          callback = function()
            self.settings:saveSetting("ai_smart_dictionary", true)
            self.updated = true -- persist choice on next FlushSettings
            UIManager:close(ask_dialog)
            ASUtils.runWhenOnlineFast(function() Trapper:wrap(open_dictionary) end)
          end,
        },
      }},
      dismissable = true,
      tap_close_callback = function()
        -- Tap outside / back: abort, no persistence.
      end,
    }
    UIManager:show(ask_dialog)
  elseif route == "dictionary" then
    open_dictionary()
  else
    open_translation()
  end
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
      if not self.config then
        UIManager:show(InfoMessage:new{
          icon = "notice-warning",
          text = _("Configuration not found. Please set up configuration.lua first.")
        })
        return
      end

      -- Smart Dictionary Lookup may divert short selections to the AI
      -- Dictionary, with a one-time prompt (dc7a373 / #207/#208).
      ASUtils.runWhenOnlineFast(function()
        Trapper:wrap(function()
          self:showTranslateOrDictionary(text)
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
    self.config:getFeature("prompts"))[idx]
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
          -- @translators Prompt offering a "Recap" (a brief spoiler-free summary of what was already read, to refresh memory after a break). %1 is the book title, %2 is the author.
          local message = T(_("Do you want an AI Recap?\nFor %1 by %2.\n\n"), title, authors)
                    .. T(N_("Last read an hour ago.", "Last read %1 hours ago.", timeDiffHours), timeDiffHours)
  
          -- Display the request popup using ConfirmBox.
          UIManager:show(ConfirmBox:new{
            text            = message,
            ok_text         = _("Yes"),
            ok_callback     = function()
              ASUtils.runWhenOnlineFast(function()
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

--- Sync the provider selection from configuration.lua into self.settings when
--- the configuration.lua provider changes compared to the last remembered value.
--- Mutates only self.settings; configuration.lua is never written.
function Assistant:syncProviderSelectionFromConfig()
  -- Sync the selected provider from configuration.lua into settings only when
  -- configuration provider changes compared to the last remembered value.
  -- The remembered value is stored in settings as "previous_config_ai_provider".
  local conf = self.config and self.config._data
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
  local ok, parser = pcall(require, "assistant_mdparser")
  if ok and parser and parser._is_hoedown then
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
