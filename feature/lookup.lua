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

return M
