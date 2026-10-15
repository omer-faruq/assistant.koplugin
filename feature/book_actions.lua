-- feature/book_actions.lua
-- Book-level features, identification flow and FileManager long-press row.
-- All KOReader browser widget requires stay lazy inside the functions so
-- headless tests can mock them after requiring main.lua.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Notification = require("ui/widget/notification")
local Event = require("ui/event")
local Trapper = require("ui/trapper")
local NetUtils = require("utils/net")
local Prompts = require("core/prompts")
local Notebook = require("feature/notebook")
local logger = require("logger")
local koutil = require("util")
local _ = require("core/gettext")
local T = require("ffi/util").template

local M = {}

-- Single row id for the FileManager long-press AI buttons.
-- One row_func returns one row, so both buttons share this id to sit
-- on the same line.
M.FM_AI_ROW_ID = "assistant_ai"
local FM_AI_ROW_ID = M.FM_AI_ROW_ID

-- Browser widgets sharing the FileManager long-press file_dialog mechanism.
-- coverbrowser.koplugin registers its rows on the same four classes.
M.FILE_DIALOG_WIDGET_MODULES = {
  "apps/filemanager/filemanager",
  "apps/filemanager/filemanagerhistory",
  "apps/filemanager/filemanagercollection",
  "apps/filemanager/filemanagerfilesearcher",
}
local FILE_DIALOG_WIDGET_MODULES = M.FILE_DIALOG_WIDGET_MODULES

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
M.getFileDialogWidgets = getFileDialogWidgets

-- Resolves the live Assistant instance at tap time, mirroring upstream
-- FileManagerHistory/Collection/FileSearcher.getMenuInstance: the long-press
-- row is registered on the browser class tables and deduped by row id, so a
-- closure that bound the registering instance would keep serving the first
-- FileManager's stale querier/config after a book open/close cycle.
local function liveAssistant()
  local ui
  local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
  if ok_fm and type(FM) == "table" then ui = FM.instance end
  if not ui then
    local ok_ru, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_ru and type(ReaderUI) == "table" then ui = ReaderUI.instance end
  end
  return ui and ui.assistant
end
M.liveAssistant = liveAssistant

function M.getDocumentInfo(ui)
  local DocUtils = require("utils/doc")
  local DocSettings = require("docsettings")
  local document = ui and ui.document
  local file = document and document.file
  local doc_settings
  local percent_finished = 0
  if file then
    local ok, ds = pcall(function() return DocSettings:open(file) end)
    if ok then doc_settings = ds end
    if doc_settings then
      local ok_p, v = pcall(function() return doc_settings:readSetting("percent_finished") end)
      if ok_p and type(v) == "number" then percent_finished = v end
    end
  end
  local meta = DocUtils.getBookMeta(ui, file)
  return {
    title = meta.title,
    authors = meta.authors,
    percent_finished = percent_finished,
  }
end

-- FileManager-side metadata for book_info: no open document exists, and
-- book_info only needs title/author/language, so this never opens the
-- document (no body/toc/cover needed).
-- Priority: long-press book_props -> bookinfo:getDocProps(file, nil, true)
-- (metadata only, no open) -> sidecar DocSettings doc_props -> filename.
-- Reading progress comes from the sidecar percent_finished, or 0.
function M.getDocumentInfoForFile(assistant, file, book_props)
  -- @doc FileManager-side metadata for book_info: no open document exists,
  -- and book_info only needs title/author/language, so this never opens the
  -- document (no body/toc/cover needed).
  -- Returns title/authors exactly as resolved (nil when unknown) plus
  -- display_title (filename stem is factual as a display label, never a title).
  -- Priority: long-press book_props -> DocUtils.getBookMeta chain (which
  -- covers bookinfo:getDocProps, sidecar doc_props, filename stem) ->
  -- BookList percent cache. No fabricated metadata, no document open.

  local function normAuthors(value)
    if type(value) == "table" then
      local parts = {}
      for _, v in ipairs(value) do
        if type(v) == "string" and v ~= "" then
          table.insert(parts, v)
        end
      end
      if #parts > 0 then return table.concat(parts, ", ") end
      return nil
    elseif type(value) == "string" and value ~= "" then
      return value
    end
    return nil
  end

  local raw_title = koutil.tableGetValue(book_props, "title")
  local title = (type(raw_title) == "string" and raw_title ~= "") and raw_title or nil
  local authors = normAuthors(koutil.tableGetValue(book_props, "authors"))

  local DocUtils = require("utils/doc")
  local meta = DocUtils.getBookMeta(assistant.ui, file)
  if not title then
    title = meta.title
  end
  if not authors then
    authors = meta.authors
  end
  local display_title = meta.display_title

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
    local ok_p, v = pcall(function()
      return doc_settings:readSetting("percent_finished")
    end)
    if type(booklist_percent) ~= "number" and ok_p and type(v) == "number" then
      percent_finished = v
    end
  end

  return {
    title = title,
    authors = authors,
    percent_finished = percent_finished,
    display_title = display_title,
  }
end

-- Builds the FileManager long-press row with the AI buttons on one line.
-- One row_func returns one row, so returning two buttons here keeps them
-- side by side. Gate: directories and files without a document provider
-- return nil (no row). Missing files (e.g. deleted books still listed in
-- History) stay visible but disabled, matching how native file-dialog
-- buttons treat unavailable targets. Progress is NOT checked here: it
-- needs the BookList cache and is judged inside onAskAIRecapForFile,
-- keeping long-press cheap.
function M.buildFileDialogAIRow(assistant, file, is_file, book_props)
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
        M.closeFileDialogs()
        assistant:onAskAIBookInfoForFile(file, book_props)
      end,
    },
    {
      text = _("Recap (AI)"),
      enabled = enabled,
      callback = function()
        M.closeFileDialogs()
        assistant:onAskAIRecapForFile(file, book_props)
      end,
    },
    {
      text = _("Identify (AI)"),
      enabled = enabled,
      callback = function()
        M.closeFileDialogs()
        assistant:onAskAIIdentifyBookForFile(file, book_props)
      end,
    },
  }
end

-- Close any open long-press file dialog before running book_info, so the
-- result viewer is not stacked behind it. The dialog owner varies by browser
-- (FileManager, History, Collections, FileSearcher), so try each widget's
-- current menu instance.
function M.closeFileDialogs()
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
function M.registerFileDialogButtons()
  local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
  if not ok or type(FileManager) ~= "table"
    or type(FileManager.addFileDialogButtons) ~= "function" then
    return
  end
  for i, widget in ipairs(getFileDialogWidgets()) do
    FileManager.addFileDialogButtons(widget, FM_AI_ROW_ID,
      function(file, is_file, dialog_book_props)
        local live = liveAssistant()
        if not live then return nil end
        return M.buildFileDialogAIRow(live, file, is_file, dialog_book_props)
      end)
  end
end

-- Paired with registerFileDialogButtons: row_id is globally unique, and
-- addFileDialogButtons already dedupes, so re-registration is safe.
function M.removeFileDialogButtons()
  local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
  if not ok or type(FileManager) ~= "table"
    or type(FileManager.removeFileDialogButtons) ~= "function" then
    return
  end
  for i, widget in ipairs(getFileDialogWidgets()) do
    FileManager.removeFileDialogButtons(widget, FM_AI_ROW_ID)
  end
end

function M.confirmMissingMetadata(assistant, launch)
  UIManager:show(ConfirmBox:new{
    text = _("Title or author metadata is missing or incomplete, so the AI result may be unreliable. Use Identify (AI) to set it first."),
    ok_text = _("Continue"),
    cancel_text = _("Cancel"),
    ok_callback = launch,
  })
end

function M.commitIdentifiedMetadata(assistant, ui, file, identified)
  identified = identified or {}
  ui = ui or assistant.ui
  local book_props
  if ui and ui.document and ui.document.file == file then
    book_props = ui.doc_props or {}
  else
    local bi0 = ui and ui.bookinfo
    local get_doc_props = type(bi0) == "table" and bi0.getDocProps
    if type(get_doc_props) ~= "function" then
      local ok_mod, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
      if ok_mod and type(BookInfo) == "table" then
        bi0 = BookInfo:new{ ui = ui }
        get_doc_props = type(bi0) == "table" and bi0.getDocProps
      end
    end
    if type(get_doc_props) == "function" then
      local ok_props, props = pcall(get_doc_props, bi0, file, nil, true)
      if ok_props and type(props) == "table" then
        book_props = props
      end
    end
    if book_props == nil then book_props = {} end
  end
  local bi = ui and ui.bookinfo
  if type(bi) ~= "table" or type(bi.setCustomMetadata) ~= "function" then
    local ok_mod, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if ok_mod and type(BookInfo) == "table" then
      bi = BookInfo:new{ ui = ui }
    end
  end
  if type(bi) ~= "table" or type(bi.setCustomMetadata) ~= "function" then
    UIManager:show(InfoMessage:new{ text = _("Metadata could not be saved.") })
    return
  end
  -- Upstream setCustomMetadata ends in updateBookInfo(), which refreshes the
  -- Book Information dialog (kvp_widget, show). That dialog does not exist in
  -- this headless flow, so the writes run on a proxy that shadows the UI tail
  -- and keeps the primed settings cache on itself instead of the shared widget.
  bi = setmetatable({ updateBookInfo = function() end }, { __index = bi })
  -- Prime the cache like upstream bookInfo() so consecutive writes accumulate
  -- into one object instead of each overwriting the file from scratch.
  if bi.custom_doc_settings == nil then
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and type(DocSettings) == "table" then
      local existing_file = nil
      if type(DocSettings.findCustomMetadataFile) == "function" then
        pcall(function() existing_file = DocSettings:findCustomMetadataFile(file) end)
      end
      if type(DocSettings.openSettingsFile) == "function" then
        local ok_open, opened = pcall(DocSettings.openSettingsFile, existing_file)
        if ok_open and type(opened) == "table" then
          bi.custom_doc_settings = opened
        end
      end
    end
  end
  local succeeded = 0
  local calls = {}
  if identified.title then
    table.insert(calls, { "title", identified.title })
  end
  if identified.authors then
    table.insert(calls, { "authors", identified.authors })
  end
  if identified.description then
    table.insert(calls, { "description", identified.description })
  end
  for _, call in ipairs(calls) do
    local ok_call = pcall(bi.setCustomMetadata, bi, file, book_props, call[1], call[2])
    if ok_call then succeeded = succeeded + 1 end
    -- Reload from disk so the next write in the batch accumulates instead of
    -- starting from an empty object.
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and type(DocSettings) == "table" and type(DocSettings.openSettingsFile) == "function" then
      local existing_file = nil
      if type(DocSettings.findCustomMetadataFile) == "function" then
        pcall(function() existing_file = DocSettings:findCustomMetadataFile(file) end)
      end
      local ok_open, opened = pcall(DocSettings.openSettingsFile, existing_file)
      if ok_open and type(opened) == "table" then
        bi.custom_doc_settings = opened
      elseif bi.custom_doc_settings == nil then
        local ok_ds2, DocSettings2 = pcall(require, "docsettings")
        if ok_ds2 and type(DocSettings2) == "table" and type(DocSettings2.openSettingsFile) == "function" then
          local ok_o, opened2 = pcall(DocSettings2.openSettingsFile, nil)
          if ok_o and type(opened2) == "table" then
            bi.custom_doc_settings = opened2
          end
        end
      end
    end
  end
  if ui and ui.document and ui.document.file == file then
    local ok_fb, FB = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if ok_fb and type(FB) == "table" and type(FB.extendProps) == "function" then
      ui.doc_props = FB.extendProps(ui.doc_props or book_props, file)
    end
  end
  UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file))
  UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
  if succeeded > 0 then
    Notification:notify(_("Book metadata updated."), Notification.SOURCE_ALWAYS_SHOW)
  else
    UIManager:show(InfoMessage:new{ text = _("Metadata could not be saved.") })
  end
end

function M.identifyBookFlow(assistant, opening, file, commit_ui)
  local ui = commit_ui
  local DocUtils = require("utils/doc")

  local system_prompt = Prompts.withResponseLanguage(
      koutil.tableGetValue(Prompts, "builtin_prompts", "identify_book", "system_prompt")
          or Prompts.assistant_prompts.default.system_prompt,
      assistant.settings:readSetting("response_language") or assistant.ui_language)

  local user_instructions = koutil.tableGetValue(Prompts, "builtin_prompts", "identify_book", "user_prompt")
      or "Identify the book."
  local user_content = DocUtils.buildIdentifyUserMessage(user_instructions, opening)

  local message_history = {
    { role = "system", content = system_prompt },
    { role = "user", content = user_content },
  }

  local identify_prompt_config = koutil.tableGetValue(Prompts, "builtin_prompts", "identify_book") or {}
  local identify_ws_mode = koutil.tableGetValue(identify_prompt_config, "use_websearch")
      and assistant.settings:readSetting("use_websearch", "none") or "none"

  local identified, answer, status = DocUtils.identifyWithRetry(function(history)
      return assistant.querier:query(history, _("Identify This Book"), {
          use_websearch = identify_ws_mode,
      })
  end, message_history, "Reply ONLY with lines in this format:\n::title{...}::\n::author{...}::\n::description{...}::\nNo other text.")

  if not identified then
    if status == "no_data" then
      UIManager:show(InfoMessage:new{
        text = _("The model could not identify this book.")
      })
    else
      local snippet = (answer or ""):gsub("%s+", " ")
      if #snippet > 120 then
        snippet = string.sub(snippet, 1, 120)
      end
      UIManager:show(InfoMessage:new{
        text = _("Could not parse the identification result.") .. " " .. snippet
      })
    end
    return
  end
  if not identified.title and not identified.authors then
    UIManager:show(InfoMessage:new{
      text = _("The model could not identify this book.")
    })
    return
  end

  local message = DocUtils.buildIdentifyConfirmMessage(identified)
  UIManager:show(ConfirmBox:new{
    text = message,
    ok_text = _("Set"),
    cancel_text = _("Cancel"),
    ok_callback = function()
      M.commitIdentifiedMetadata(assistant, ui, file, identified)
    end,
  })
end

function M.onAskAIIdentifyBook(assistant)
  if not assistant:isConfigured() then return end
  if not koutil.tableGetValue(assistant, "ui", "document") then
    UIManager:show(InfoMessage:new{
      text = _("No book is open.")
    })
    return true
  end
  NetUtils.runWhenOnlineFast(function()
    Trapper:wrap(function()
      local ui = assistant.ui
      local file = ui.document.file
      local DocUtils = require("utils/doc")
      local opening = DocUtils.getOpeningText(ui, 3000)
      if opening == "" then
        UIManager:show(InfoMessage:new{
          text = _("Could not extract text from this book.")
        })
        return
      end
      M.identifyBookFlow(assistant, opening, file, ui)
    end)
  end)
  return true
end

function M.onAskAIIdentifyBookForFile(assistant, file, book_props)
  if not assistant:isConfigured() then return end
  local ui = assistant.ui
  NetUtils.runWhenOnlineFast(function()
    Trapper:wrap(function()
      local DocUtils = require("utils/doc")
      local opening = ""
      local doc
      local ok_reg, DocumentRegistry = pcall(require, "document/documentregistry")
      if ok_reg and type(DocumentRegistry) == "table"
        and type(DocumentRegistry.hasProvider) == "function"
        and type(DocumentRegistry.openDocument) == "function" then
        if DocumentRegistry:hasProvider(file) then
          doc = DocumentRegistry:openDocument(file)
        end
      end
      if doc then
        local loaded = true
        local ok_load = pcall(function()
          if type(doc.loadDocument) == "function" then
            if not doc:loadDocument(false) then
              loaded = false
            end
          end
        end)
        if not ok_load then loaded = false end
        if loaded then
          local ok_extract, res = pcall(DocUtils.getOpeningText, { document = doc }, 3000)
          if ok_extract and type(res) == "string" then
            opening = res
          end
        end
        pcall(function()
          if type(doc.close) == "function" then doc:close() end
        end)
      end

      if opening == "" then
        -- Only plain-text formats yield a readable document from the file
        -- manager; everything else loads metadata only, so send the user to
        -- the reader, where the opening text is available.
        UIManager:show(InfoMessage:new{
          text = _("This book's text cannot be read from the file manager. Open the book and use Identify This Book.")
        })
        return
      end
      M.identifyBookFlow(assistant, opening, file, ui)
    end)
  end)
  return true
end

-- FileManager-side book_info: metadata comes from the file, not an open doc.
function M.onAskAIBookInfoForFile(assistant, file, book_props)
  if not assistant:isConfigured() then return end
  local book = M.getDocumentInfoForFile(assistant, file, book_props)
  local function launch()
    NetUtils.runWhenOnlineFast(function()
      local notebook_path
      if Notebook.isEnabled(assistant) then
        local ok, path = pcall(Notebook.getBookNotebookPath, assistant, file)
        if ok and type(path) == "string" and path ~= "" then
          notebook_path = path
        elseif not ok then
          logger.warn("Assistant: Could not compute per-book notebook path:", path)
        end
      end
      local showFeatureDialog = require("dialogs/feature")
      Trapper:wrap(function()
        showFeatureDialog(assistant, "book_info", book.title, book.authors, book.percent_finished, nil, notebook_path)
      end)
    end)
  end
  if not book or not book.title or not book.authors then
    M.confirmMissingMetadata(assistant, launch)
    return true
  end
  launch()
  return true
end

-- FileManager-side recap: degraded version without book text (no document
-- open), so require proof the book was opened and started. Never opens the
-- document here.
function M.onAskAIRecapForFile(assistant, file, book_props)
  if not assistant:isConfigured() then return end
  local book = M.getDocumentInfoForFile(assistant, file, book_props)
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
  if Notebook.isEnabled(assistant) then
    local ok, path = pcall(Notebook.getBookNotebookPath, assistant, file)
    if ok and type(path) == "string" and path ~= "" then
      notebook_path = path
    elseif not ok then
      logger.warn("Assistant: Could not compute per-book notebook path:", path)
    end
  end
  local function launch()
    NetUtils.runWhenOnlineFast(function()
      local showFeatureDialog = require("dialogs/feature")
      Trapper:wrap(function()
        showFeatureDialog(assistant, "recap", book.title, book.authors, percent, nil, notebook_path)
      end)
    end)
  end
  if not book or not book.title or not book.authors then
    M.confirmMissingMetadata(assistant, launch)
    return true
  end
  launch()
  return true
end

function M.onAskAIRecap(assistant)
  if not assistant:isConfigured() then return end
  NetUtils.runWhenOnlineFast(function()
    local book = M.getDocumentInfo(assistant.ui)
    local showFeatureDialog = require("dialogs/feature")
    Trapper:wrap(function()
      showFeatureDialog(assistant, "recap", book.title, book.authors, book.percent_finished)
    end)
  end)
  return true
end

function M.onAskAIXRay(assistant)
  if not assistant:isConfigured() then return end
  NetUtils.runWhenOnlineFast(function()
    local book = M.getDocumentInfo(assistant.ui)
    local showFeatureDialog = require("dialogs/feature")
    Trapper:wrap(function()
      showFeatureDialog(assistant, "xray", book.title, book.authors, book.percent_finished)
    end)
  end)
  return true
end

function M.onAskAIBookInfo(assistant)
  if not assistant:isConfigured() then return end
  if not koutil.tableGetValue(assistant, "ui", "document") then
    UIManager:show(InfoMessage:new{
      text = _("No book is open. Long-press a book in the file manager and choose Book Info (AI).")
    })
    return true
  end
  NetUtils.runWhenOnlineFast(function()
    local book = M.getDocumentInfo(assistant.ui)
    local showFeatureDialog = require("dialogs/feature")
    Trapper:wrap(function()
      showFeatureDialog(assistant, "book_info", book.title, book.authors, book.percent_finished)
    end)
  end)
  return true
end

function M.onAskAIAnnotations(assistant)
  if not assistant:isConfigured() then return end
  NetUtils.runWhenOnlineFast(function()
    local book = M.getDocumentInfo(assistant.ui)
    local showFeatureDialog = require("dialogs/feature")
    Trapper:wrap(function()
      showFeatureDialog(assistant, "annotations", book.title, book.authors, book.percent_finished)
    end)
  end)
  return true
end

function M.onAskSummaryUsingAnnotations(assistant)
  if not assistant:isConfigured() then return end
  NetUtils.runWhenOnlineFast(function()
    local book = M.getDocumentInfo(assistant.ui)
    local showFeatureDialog = require("dialogs/feature")
    Trapper:wrap(function()
      showFeatureDialog(assistant, "summary_using_annotations", book.title, book.authors, book.percent_finished)
    end)
  end)
  return true
end

return M
