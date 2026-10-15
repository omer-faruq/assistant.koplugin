--- Smart Dictionary Lookup routing: decides whether a highlight goes to the
-- AI Dictionary (short) or the full Translate action (long), and whether the
-- one-time explainer prompt should be shown.
local koutil = require("util")
local M = {}

-- Script-aware thresholds (dc7a373, issues #207/#208): the old word count used
-- util.splitToWords, whose greedy multi-byte pattern collapses a CJK run into a
-- single token, so a whole CJK sentence counted as one "word" and was routed to
-- the dictionary. CJK is therefore measured in characters instead.
M.CJK_LOOKUP_MAX_CHARS = 8
M.WORD_LOOKUP_MAX_WORDS = 5

--- Classify a selection as "dictionary" (short) or "translate" (long).
--- CJK text is measured in UTF-8 characters, other scripts in words.
---@param text any Selection text; non-strings route to "translate"
---@return string mode Either "dictionary" or "translate"
function M.lookup_mode_for_selection(text)
    if type(text) ~= "string" then return "translate" end
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed == "" then return "translate" end

    if koutil.hasCJKChar(trimmed) then
        local count = 0
        for char in trimmed:gmatch(koutil.UTF8_CHAR_PATTERN) do
            count = count + 1
        end
        return count <= M.CJK_LOOKUP_MAX_CHARS and "dictionary" or "translate"
    end

    local word_count = select(2, trimmed:gsub("%S+", ""))
    return word_count <= M.WORD_LOOKUP_MAX_WORDS and "dictionary" or "translate"
end

--- Resolve where a selection should go once the lookup mode is known.
--- choice = stored user setting: nil = never asked, true = smart lookup
--- enabled, false = disabled. Short ("dictionary") selections may prompt the
--- explainer when the user has never chosen; once chosen, never asked again.
--- Long ("translate") selections never prompt.
---@param choice boolean|nil Stored smart-lookup setting
---@param string mode Result of M.lookup_mode_for_selection
---@return string route One of "ask", "dictionary" or "translate"
function M.resolve_translate_route(choice, mode)
    if mode ~= "dictionary" then return "translate" end
    if choice == nil then return "ask" end
    return choice and "dictionary" or "translate"
end

--- Route a translate request through Smart Dictionary Lookup: short selections
--- may open the AI Dictionary instead, with a one-time three-way prompt on
--- first use. Callers must already be inside runWhenOnlineFast + Trapper:wrap.
---@param assistant table The Assistant instance
---@param text string Selection text
function M.showTranslateOrDictionary(assistant, text)
  local function open_translation()
    if not assistant.assistant_dialog then return end
    assistant.assistant_dialog:runPrompt(text, "translate")
  end
  local function open_dictionary()
    local showDictionaryDialog = require("dialogs/dict")
    showDictionaryDialog(assistant, text)
  end

  local choice = assistant.settings:readSetting("ai_smart_dictionary")
  local mode = M.lookup_mode_for_selection(text)
  local route = M.resolve_translate_route(choice, mode)

  if route == "ask" then
    local ButtonDialog = require("ui/widget/buttondialog")
    local Font = require("ui/font")
    local UIManager = require("ui/uimanager")
    local Trapper = require("ui/trapper")
    local NetUtils = require("utils/net")
    local TextUtils = require("utils/text")
    local _ = require("core/gettext")
    local ask_dialog
    ask_dialog = ButtonDialog:new{
      title = TextUtils.bold_format(_("Dictionary or Translation?\n\nThis selection looks like a word or short phrase.\n\nYou can change this later in Settings > Other Settings > Smart Dictionary Lookup for 'Translate'.")),
      title_align = "left",
      info_face = Font:getFace("smallinfofont"),
      buttons = {{
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(ask_dialog)
          end,
        },
        {
          text = _("Translate"),
          callback = function()
            assistant.settings:saveSetting("ai_smart_dictionary", false)
            assistant.updated = true
            UIManager:close(ask_dialog)
            NetUtils.runWhenOnlineFast(function() Trapper:wrap(open_translation) end)
          end,
        },
        {
          text = _("Dictionary"),
          callback = function()
            assistant.settings:saveSetting("ai_smart_dictionary", true)
            assistant.updated = true
            UIManager:close(ask_dialog)
            NetUtils.runWhenOnlineFast(function() Trapper:wrap(open_dictionary) end)
          end,
        },
      }},
      dismissable = true,
      tap_close_callback = function()
      end,
    }
    UIManager:show(ask_dialog)
  elseif route == "dictionary" then
    open_dictionary()
  else
    open_translation()
  end
end

return M
