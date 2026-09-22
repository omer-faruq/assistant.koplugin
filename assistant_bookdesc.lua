-- assistant_bookdesc.lua
-- Adds a bottom "Translate (AI)" button to the upstream Book Description
-- popup: a TextViewer shown by BookInfo:onShowBookDescription from the
-- FileManager long-press menu (and the reader's ShowBookDescription action).
-- The button feeds the plain-text description into the standard translate
-- prompt; the result opens in ChatGPTViewer like any other translation.
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local koutil = require("util")
local _ = require("assistant_gettext")

local M = {}

-- Sentinel on the shared BookInfo class, mirroring the
-- Translator.showTranslation and ReaderUI.doShowReader hooks in main.lua:
-- setup is idempotent across the FileManager and Reader plugin instances.
local PATCH_KEY = "_assistant_bookdesc_translate_patched"

--- Wrap BookInfo:onShowBookDescription so the popup gains a Translate (AI)
--- bottom button. Best effort: a missing BookInfo module is a silent no-op.
--- The button callback re-checks provider setup at tap time, so this can run
--- before any provider is configured.
---@param assistant table plugin instance (isConfigured, assistant_dialog)
function M.setup(assistant)
    local ok, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if not ok or type(BookInfo) ~= "table" then return end
    if BookInfo[PATCH_KEY] then return end
    BookInfo[PATCH_KEY] = true
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
                            DocUtils.runWhenOnlineFast(function()
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

return M
