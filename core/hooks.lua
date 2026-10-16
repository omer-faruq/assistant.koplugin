-- core/hooks.lua
-- Centralizes monkey patches against KOReader classes. Each patch is
-- idempotent and keeps the upstream method available for restoration or
-- delegation. This module is the only place where the plugin modifies
-- KOReader controls at runtime.
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local koutil = require("util")
local _ = require("core/gettext")
local N_ = _.ngettext
local ffiutil = require("ffi/util")
local T = ffiutil.template
local lfs = require("libs/libkoreader-lfs")
local DocUtils = require("utils/doc")
local NetUtils = require("utils/net")
local Prompts = require("core/prompts")
local TextUtils = require("utils/text")
local Lookup = require("feature/lookup")local Device = require("device")
local Event = require("ui/event")

local M = {}

-- Sentinel on the shared BookInfo class, mirroring the
-- Translator.showTranslation and ReaderUI.doShowReader hooks in main.lua:
-- setup is idempotent across the FileManager and Reader plugin instances.
local BOOK_DESCRIPTION_PATCH = "_assistant_bookdesc_translate_patched"
local TRANSLATOR_PATCH = "_assistant_translate_patched"
local READER_PATCH = "_assistant_recap_patched"
local SCROLL_PAGE_PATCH = "_assistant_scroll_to_page_patched"

--- Put the Assistant entry first in KOReader's Tools menus.
--- This mutates KOReader's menu order tables once per process.
function M.setupMenuOrder()
    local reader_order = require("ui/elements/reader_menu_order").tools
    local filemanager_order = require("ui/elements/filemanager_menu_order").tools
    local function insertFirst(order)
        if order[1] == "ai_assistant" then return end
        for i = 2, #order do
            if order[i] == "ai_assistant" then
                table.remove(order, i)
                table.insert(order, 1, "ai_assistant")
                return
            end
        end
        table.insert(order, 1, "ai_assistant")
    end
    insertFirst(reader_order)
    insertFirst(filemanager_order)
end

--- Add the page navigation helper used by ResultViewer to KOReader's
--- ScrollHtmlWidget class.
function M.setupScrollHtmlWidget()
    local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
    if ScrollHtmlWidget[SCROLL_PAGE_PATCH] then return end
    ScrollHtmlWidget[SCROLL_PAGE_PATCH] = true
    ScrollHtmlWidget.scrollToPage = function(self, page_num)
        if page_num > self.htmlbox_widget.page_count then
            page_num = self.htmlbox_widget.page_count
        end
        self.htmlbox_widget:setPageNumber(page_num)
        self:_updateScrollBar()
        self.htmlbox_widget:freeBb()
        self.htmlbox_widget:_render()
        if self.dialog.movable and self.dialog.movable.alpha then
            self.dialog.movable.alpha = nil
            UIManager:setDirty(self.dialog, function()
                return "partial", self.dialog.movable.dimen
            end)
        else
            UIManager:setDirty(self.dialog, function()
                return "partial", self.dimen
            end)
        end
    end
end

--- Wrap BookInfo:onShowBookDescription so the popup gains a Translate (AI)
--- bottom button. Best effort: a missing BookInfo module is a silent no-op.
--- The button callback re-checks provider setup at tap time, so this can run
--- before any provider is configured.
---@param assistant table plugin instance (isConfigured, assistant_dialog)
function M.setupBookDescription(assistant)
    local ok, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if not ok or type(BookInfo) ~= "table" then return end
    if BookInfo[BOOK_DESCRIPTION_PATCH] then return end
    BookInfo[BOOK_DESCRIPTION_PATCH] = true
    local orig_show = BookInfo.onShowBookDescription

    function BookInfo:onShowBookDescription(description, file)
        local resolved = description
        if not resolved then
            if file then
                resolved = self:getDocProps(file).description
            elseif self.document then -- currently opened document
                resolved = self.ui.doc_props.description
            end
        end
        if not resolved then
            -- Keep the upstream empty-state notice (and its core catalog
            -- msgid) untouched.
            return orig_show(self, description, file)
        end
        local plain = koutil.htmlToPlainTextIfHtml(resolved)
        local viewer = TextViewer:new{
            title = self.prop_text["description"],
            text = plain,
            text_type = "book_info",
            -- Custom rows first, upstream Find/Close rows appended: the same
            -- buttons_table + add_default_buttons pattern as the Translator
            -- popup (frontend/ui/translator.lua).
            add_default_buttons = true,
            buttons_table = {
                {
                    {
                        -- @translators Button text: translates the book description with AI. Keep it short.
                        text = _("Translate (AI)"),
                        callback = function()
                            if not assistant:isConfigured() then return end
                            if not assistant.assistant_dialog then return end
                            -- Lazy require: avoids pulling the network stack
                            -- during test-suite init (same reason DocUtils
                            -- lazy-requires NetworkMgr inside runWhenOnlineFast).
                            local DocUtils = require("utils/doc")
                            NetUtils.runWhenOnlineFast(function()
                                Trapper:wrap(function()
                                    assistant.assistant_dialog:runPrompt(plain, "translate")
                                end)
                            end)
                        end,
                        hold_callback = function()
                            UIManager:show(InfoMessage:new{
                                text = _("Translates the book description with AI."),
                            })
                        end,
                    },
                },
            },
        }
        UIManager:show(viewer)
    end
end

--- Synchronize the AI replacement for KOReader's built-in translation.
--- @param assistant table plugin instance
function M.syncTranslateOverride(assistant)
    local Translator = require("ui/translator")
    local should_override = assistant.settings:readSetting("ai_translate_override", false)

    if should_override then
        if not Translator._assistant_original_showTranslation then
            Translator._assistant_original_showTranslation = Translator.showTranslation
        end
        Translator[TRANSLATOR_PATCH] = true
        Translator.showTranslation = function(ts_self, text)
            if not assistant.config then
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = _("Configuration not found. Please set up configuration.lua first."),
                })
                return
            end
            NetUtils.runWhenOnlineFast(function()
                Trapper:wrap(function()
                    Lookup.showTranslateOrDictionary(assistant, text)
                end)
            end)
        end
        logger.info("Assistant: translate method overridden with AI Assistant")
    elseif Translator._assistant_original_showTranslation then
        Translator.showTranslation = Translator._assistant_original_showTranslation
        Translator._assistant_original_showTranslation = nil
        Translator[TRANSLATOR_PATCH] = nil
        logger.info("Assistant: translate method restored")
    end
end

--- Resolve when a book was last read without relying on file atime:
--- KOReader's history entry time, else the sidecar metadata mtime, as epoch
--- seconds. Returns nil when neither source is available.
local function get_last_read_time(file)
    local ReadHistory = require("readhistory")
    local resolved = ffiutil.realpath(file)
    local candidates = { file }
    if resolved and resolved ~= file then
        candidates = { resolved, file }
    end
    for i = 1, #candidates do
        local index = ReadHistory:getIndexByFile(candidates[i])
        local entry = index and ReadHistory.hist[index]
        if entry and type(entry.time) == "number" and entry.time > 0 then
            return entry.time
        end
    end
    local sidecar
    local DocSettings = require("docsettings")
    if type(DocSettings.findSidecarFile) == "function" then
        sidecar = DocSettings:findSidecarFile(file)
    elseif type(DocSettings.getSidecarDir) == "function"
        and type(DocSettings.getSidecarFilename) == "function" then
        sidecar = ffiutil.joinPath(
            DocSettings:getSidecarDir(file),
            DocSettings.getSidecarFilename(file))
    end
    if sidecar then
        local mtime = lfs.attributes(sidecar, "modification")
        if type(mtime) == "number" and mtime > 0 then
            return mtime
        end
    end
    return nil
end

--- Install the AI recap prompt before KOReader opens a book.
--- @param assistant table plugin instance
function M.setupRecap(assistant)
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI[READER_PATCH] then return end
    ReaderUI[READER_PATCH] = true
    ReaderUI._assistant_original_doShowReader = ReaderUI.doShowReader

    local DocSettings = require("docsettings")
    ReaderUI.doShowReader = function(self, file, provider, seamless)
        local last_read = get_last_read_time(file)
        if last_read then
            local doc_settings = DocSettings:open(file)
            local percent_finished = doc_settings:readSetting("percent_finished") or 0
            local time_diff_hours = math.floor((os.time() - last_read) / 3600)
            if time_diff_hours < 0 then time_diff_hours = 0 end
            if time_diff_hours >= 28 and percent_finished >= 0.03 and percent_finished <= 0.95 then
                local DocUtils = require("utils/doc")
                local meta = DocUtils.getBookMeta(assistant and assistant.ui, file)
                local title = meta.title or meta.display_title or _("Unknown Title")
                local authors = meta.authors or _("Unknown Author")
                -- @translators Prompt offering a "Recap" (a brief spoiler-free summary of what was already read, to refresh memory after a break). %1 is the book title, %2 is the author.
                local message = T(_("Do you want an AI Recap?\nFor %1 by %2.\n\n"), title, authors)
                    .. T(N_("Last read an hour ago.", "Last read %1 hours ago.", time_diff_hours), time_diff_hours)
                UIManager:show(ConfirmBox:new{
                    text = message,
                    ok_text = _("Yes"),
                    ok_callback = function()
                        NetUtils.runWhenOnlineFast(function()
                            local showFeatureDialog = require("dialogs/feature")
                            Trapper:wrap(function()
                                showFeatureDialog(assistant, "recap", title, authors, percent_finished)
                            end)
                        end)
                    end,
                    cancel_text = _("No"),
                })
            end
        end
        return ReaderUI._assistant_original_doShowReader(self, file, provider, seamless)
    end
end

--- Register the reader highlight-dialog entry point.
---@param assistant table plugin instance
function M.setupHighlightMainButton(assistant)
  assistant.ui.highlight:addToHighlightDialog("ai_assistant", function(_reader_highlight_instance)
    return {
      text = _("AI Assistant"),
      enabled = Device:hasClipboard(),
      callback = function()
        if not assistant:isConfigured() then
          return
        end

        NetUtils.runWhenOnlineFast(function()
          local Updater = require("core/updater")
          Updater.checkForUpdates(assistant)
          UIManager:nextTick(function()
            if not assistant.assistant_dialog then return end
            assistant.assistant_dialog:showAskDialog(_reader_highlight_instance.selected_text.text)
          end)
        end)
      end,
      hold_callback = function()
        require("dialogs/settings_menu").showHelpDialog(assistant)
      end,
    }
  end)
end

--- Rebuild the highlight-menu buttons from the current showOnMain settings.
---@param assistant table plugin instance
function M.rebuildShowOnMainButtons(assistant)
  if not assistant.ui.document then return end

  Prompts.invalidateCache()
  Prompts.getMergedPrompts(assistant.config:getFeature("prompts"))

  local showOnMain = Prompts.getSortedPrompts(function (prompt, idx)
    if prompt.visible == false then
      return false
    end

    local menukey = string.format("assistant_%02d_%s", prompt.order or 1000, idx)
    local settingkey = "showOnMain_" .. menukey
    if assistant.settings:has(settingkey) then
      return assistant.settings:isTrue(settingkey)
    end

    if prompt.show_on_main_popup then
      return true
    end

    return false
  end, Prompts.isWebSearchEnabled(assistant.settings)) or {}

  for _, tab in ipairs(showOnMain) do
    M.addMainButton(assistant, tab.idx, tab)
  end
end

---@param assistant table plugin instance
---@param prompt_idx string prompt key
---@param prompt table prompt config
function M.addMainButton(assistant, prompt_idx, prompt)
  local menukey = string.format("assistant_%02d_%s", prompt.order, prompt_idx)
  assistant.ui.highlight:removeFromHighlightDialog(menukey)
  assistant.ui.highlight:addToHighlightDialog(menukey, function(_reader_highlight_instance)
    local ws_enabled = Prompts.isWebSearchEnabled(assistant.settings)
    local btntext = Prompts.getDisplayText(prompt.text or prompt_idx,
      prompt.use_websearch or false, ws_enabled) .. " (AI)"
    return {
      text = btntext,
      callback = function()
        if prompt_idx == "quick_note" then
          Trapper:wrap(function()
            if not assistant.quicknote then
              local QuickNote = require("dialogs/quicknote")
              assistant.quicknote = QuickNote:new(assistant)
            end
            assistant.quicknote:saveNote(nil, _reader_highlight_instance.selected_text.text)
          end)
        else
          NetUtils.runWhenOnlineFast(function()
            Trapper:wrap(function()
              if prompt.order == -10 and prompt_idx == "dictionary" then
                local showDictionaryDialog = require("dialogs/dict")
                showDictionaryDialog(assistant, _reader_highlight_instance.selected_text.text)
              elseif prompt_idx == "term_xray" then
                local showDictionaryDialog = require("dialogs/dict")
                showDictionaryDialog(assistant, _reader_highlight_instance.selected_text.text, nil, "term_xray")
              elseif prompt_idx == "translate" then
                Lookup.showTranslateOrDictionary(assistant, _reader_highlight_instance.selected_text.text)
              else
                if not assistant.assistant_dialog then return end
                assistant.assistant_dialog:runPrompt(_reader_highlight_instance.selected_text.text, prompt_idx)
              end
            end)
          end)
        end
      end,
      hold_callback = function()
        UIManager:nextTick(function()
          UIManager:show(ConfirmBox:new{
            text = string.format(_("Remove [%s] from Highlight Menu?"), btntext),
            ok_text = _("Remove"),
            ok_callback = function()
              assistant:handleEvent(Event:new("AssistantSetButton", {order=prompt.order, idx=prompt_idx}, "remove"))
              assistant.ui.highlight:onClose(true)
            end
          })
        end)
      end,
    }
  end)
end

---@param assistant table plugin instance
---@param btnconf table { order: number, idx: string }
---@param action string "add" or "remove"
function M.onAssistantSetButton(assistant, btnconf, action)
  local menukey = string.format("assistant_%02d_%s", btnconf.order, btnconf.idx)
  local settingkey = "showOnMain_" .. menukey

  local idx = btnconf.idx
  local prompt = Prompts.getMergedPrompts(
    assistant.config:getFeature("prompts"))[idx]
  local ws_enabled = Prompts.isWebSearchEnabled(assistant.settings)
  local display_text = Prompts.getDisplayText(prompt.text or idx, prompt.use_websearch or false, ws_enabled)

  if action == "add" then
    assistant.settings:makeTrue(settingkey)
    assistant.updated = true
    M.addMainButton(assistant, idx, prompt)
    UIManager:show(InfoMessage:new{
      text = TextUtils.bold_format(
        T(_("Added <b>[%1 (AI)]</b>"), display_text)
      ),
      icon = "notice-info",
      timeout = 3
    })
  elseif action == "remove" then
    assistant.settings:makeFalse(settingkey)
    assistant.updated = true
    assistant.ui.highlight:removeFromHighlightDialog(menukey)
    UIManager:show(InfoMessage:new{
      text = TextUtils.bold_format(
        T(_("Removed <b>[%1 (AI)]</b>"), display_text)
      ),
      icon = "notice-info",
      timeout = 3
    })
  else
    logger.warn("wrong event args", menukey, action)
  end

  return true
end

--- Register Assistant buttons with the dict popup API when available.
---@param assistant table plugin instance
function M.setupDictButtons(assistant)
  if assistant.ui and assistant.ui.dictionary
      and type(assistant.ui.dictionary.addToDictButtons) == "function" then
    local button_ids = {}
    for _, button in ipairs(M.buildAssistantDictButtons(assistant, nil, true)) do
      assistant.ui.dictionary:addToDictButtons(button)
      table.insert(button_ids, button.id)
    end
    M.groupDictButtonsInDefaultLayout(assistant, button_ids)
    M.restoreDictButtonsInUserLayout(assistant, button_ids)
  end
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

---@param assistant table plugin instance
---@param dict_popup_arg table|nil popup for the legacy hook
---@param live boolean|nil true when registering via the new API
---@return table specs button specs
function M.buildAssistantDictButtons(assistant, dict_popup_arg, live)
  if not assistant.config then return {} end

  local plugin_buttons = {}
  local enabled_count = 0

  local function addButton(setting_key, default, spec)
    if assistant.settings:readSetting(setting_key, default) then
      enabled_count = enabled_count + 1
    elseif not live then
      return
    end
    if live then
      spec.menu_text = spec.menu_text or spec.text
      spec.show_func = function()
        return assistant.settings:readSetting(setting_key, default) and true or false
      end
    end
    table.insert(plugin_buttons, spec)
  end

  local function displayText(label, use_websearch)
    return Prompts.getDisplayText(label, use_websearch or false,
      Prompts.isWebSearchEnabled(assistant.settings)) .. " (AI)"
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
        NetUtils.runWhenOnlineFast(function()
            Trapper:wrap(function()
              if not assistant.assistant_dialog then return end
              assistant.assistant_dialog:runPrompt(word, "wikipedia")
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
        NetUtils.runWhenOnlineFast(function()
            Trapper:wrap(function()
              local showDictionaryDialog = require("dialogs/dict")
              showDictionaryDialog(assistant, word, nil, "term_xray")
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
        NetUtils.runWhenOnlineFast(function()
            Trapper:wrap(function()
              local showDictionaryDialog = require("dialogs/dict")
              showDictionaryDialog(assistant, word)
            end)
        end)
    end,
  })

  if live or assistant.settings:readSetting("dict_popup_show_custom_prompts", false) then
    local custom_prompts = {}
    local prompts = assistant.config:getFeature("prompts")
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

    local max_custom_to_add = math.max(0, 3 - enabled_count)
    local custom_to_add = math.min(#custom_prompts, max_custom_to_add)

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
            NetUtils.runWhenOnlineFast(function()
                Trapper:wrap(function()
                  if not assistant.assistant_dialog then return end
                  assistant.assistant_dialog:runPrompt(word, prompt.id)
                end)
            end)
        end,
      })
    end
  end

  if not live then
    for _, spec in ipairs(plugin_buttons) do
      if spec.text_func then
        spec.text = spec.text_func()
        spec.text_func = nil
      end
    end
  end

  return plugin_buttons
end

---@param assistant table plugin instance
---@param button_ids table button ids
function M.groupDictButtonsInDefaultLayout(assistant, button_ids)
  local default_layout = assistant.ui.dictionary.default_layout
  if not default_layout then return end

  local row = {}
  for _, id in ipairs(button_ids) do
    if not layoutHasButtonId(default_layout, id) then
      table.insert(row, id)
      if #row == 3 then
        table.insert(default_layout, 2, row)
        row = {}
      end
    end
  end
  if #row > 0 then
    table.insert(default_layout, 2, row)
  end
end

---@param assistant table plugin instance
---@param button_ids table button ids
function M.restoreDictButtonsInUserLayout(assistant, button_ids)
  local config = G_reader_settings:readSetting("dict_button_config")
  if not (config and config.layout) then return end

  local layout_changed = false
  for _, id in ipairs(button_ids) do
    local restore_flag = "dict_button_restored_" .. id
    if not assistant.settings:isTrue(restore_flag) then
      assistant.settings:saveSetting(restore_flag, true)
      assistant.updated = true
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
          table.insert(config.order, id)
        end
        layout_changed = true
      end
    end
  end

  if layout_changed then
    G_reader_settings:saveSetting("dict_button_config", config)
  end
end

---@param assistant table plugin instance
---@param dict_popup table popup widget
---@param dict_buttons table mutable button list
function M.onDictButtonsReady(assistant, dict_popup, dict_buttons)
  if not assistant.config then return end
  if assistant.ui and assistant.ui.dictionary
      and type(assistant.ui.dictionary.addToDictButtons) == "function" then
    return
  end

  local plugin_buttons = {}
  local buttons = M.buildAssistantDictButtons(assistant, dict_popup)
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

return M
