-- assistant_hooks.lua
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
local _ = require("assistant_gettext")
local N_ = _.ngettext
local T = require("ffi/util").template
local DocUtils = require("assistant_doc_utils")
local NetUtils = require("assistant_net_utils")

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

--- Add the page navigation helper used by ChatGPTViewer to KOReader's
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
                            local DocUtils = require("assistant_doc_utils")
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
                    assistant:showTranslateOrDictionary(text)
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

--- Install the AI recap prompt before KOReader opens a book.
--- @param assistant table plugin instance
function M.setupRecap(assistant)
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI[READER_PATCH] then return end
    ReaderUI[READER_PATCH] = true
    ReaderUI._assistant_original_doShowReader = ReaderUI.doShowReader

    local lfs = require("libs/libkoreader-lfs")
    local DocSettings = require("docsettings")
    ReaderUI.doShowReader = function(self, file, provider, seamless)
        local attr = lfs.attributes(file)
        local last_access = attr and attr.access or nil
        if last_access and last_access > 0 then
            local doc_settings = DocSettings:open(file)
            local percent_finished = doc_settings:readSetting("percent_finished") or 0
            local time_diff_hours = math.floor((os.time() - last_access) / 3600)
            if time_diff_hours >= 28 and percent_finished > 0 and percent_finished <= 0.95 then
                local doc_props = doc_settings:child("doc_props")
                local title = doc_props:readSetting("title", "Unknown Title")
                local authors = doc_props:readSetting("authors", "Unknown Author")
                -- @translators Prompt offering a "Recap" (a brief spoiler-free summary of what was already read, to refresh memory after a break). %1 is the book title, %2 is the author.
                local message = T(_("Do you want an AI Recap?\nFor %1 by %2.\n\n"), title, authors)
                    .. T(N_("Last read an hour ago.", "Last read %1 hours ago.", time_diff_hours), time_diff_hours)
                UIManager:show(ConfirmBox:new{
                    text = message,
                    ok_text = _("Yes"),
                    ok_callback = function()
                        NetUtils.runWhenOnlineFast(function()
                            local showFeatureDialog = require("assistant_featuredialog")
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

return M
