--- Text helpers: truncation, selection cleanup, PTF bold, page-text flattening,
--- plus the single-message renderer (suggestions / think-tags / div carriers).
---
--- Headless-safe: only pure string transforms plus assistant_utils /
--- assistant_prompts (both load under test stubs). No heavy UI requires.
local util = require("util")
local strbuf = require("string.buffer")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local ASUtils = require("assistant_utils")
local Prompts = require("assistant_prompts")

local M = {}

--- Convert a getPageText() result (string or table-of-blocks) into a plain string.
--- Mirrors the table handling used in extractBookTextForAnalysis.
--- @param t string|table|nil getPageText() result
--- @return string plain text, "" when the shape is unusable
function M.pageTextToString(t)
  if type(t) == "string" then
    return t
  elseif type(t) == "table" then
    local texts = {}
    for _i, block in ipairs(t) do
      if type(block) == "table" then
        for i = 1, #block do
          local span = block[i]
          if type(span) == "table" and span.word then
            table.insert(texts, span.word)
          end
        end
      end
    end
    return table.concat(texts, " ")
  end
  return ""
end

-- Byte length implied by a UTF-8 lead byte; 0 marks a continuation byte (or an
-- invalid lead byte). Used to keep truncation on character boundaries.
local function utf8_char_len(byte)
  if byte < 0x80 then return 1 end
  if byte < 0xC0 then return 0 end
  if byte < 0xE0 then return 2 end
  if byte < 0xF0 then return 3 end
  if byte < 0xF8 then return 4 end
  return 0
end

--- Keep the tail of text within max_len bytes on a UTF-8 boundary.
--- @param text string source text
--- @param max_len number maximum byte length to keep
--- @return string tail of text
function M.truncateToTailUtf8Safe(text, max_len)
  if #text <= max_len then return text end
  -- A byte slice would start mid-character: advance over the leading
  -- continuation bytes (at most 3) to the next character boundary.
  local start = #text - max_len + 1
  while start <= #text and utf8_char_len(text:byte(start)) == 0 do
    start = start + 1
  end
  return text:sub(start)
end

--- Keep the head of text within max_len bytes on a UTF-8 boundary.
--- @param text string source text
--- @param max_len number maximum byte length to keep
--- @return string head of text
function M.truncateToHeadUtf8Safe(text, max_len)
  if #text <= max_len then return text end
  -- A byte slice would end mid-character: walk back (at most 3 bytes) to the
  -- last character boundary that fits within max_len.
  local i = max_len
  while i >= 1 do
    local len = utf8_char_len(text:byte(i))
    if len == 1 or (len > 1 and i + len - 1 <= max_len) then
      return text:sub(1, i + len - 1)
    end
    i = i - 1
  end
  return ""
end

-- Marks a word selection can pick up at its edges but that are not part of the
-- word. ASCII punctuation/whitespace is matched by [%p%s]; these are the common
-- non-ASCII marks (general punctuation, CJK and fullwidth forms).
local EDGE_PUNCT = {}
for ch in ("…·，。、；：！？「」『』（）【】《》〈〉“”‘’«»"):gmatch(util.UTF8_CHAR_PATTERN) do
  EDGE_PUNCT[ch] = true
end

-- Strip whitespace/punctuation a selection picked up at its edges
-- ("Docile." -> "Docile", "他说。" -> "他说"). Only the edges are trimmed, so
-- internal punctuation ("don't", "well-known") is preserved. Returns the text
-- unchanged when it is not a string or nothing but edge marks remains.
--- @param text string|any selection text
--- @return string|any trimmed text, or the input unchanged
function M.strip_selection_punctuation(text)
  if type(text) ~= "string" then return text end
  local chars = {}
  for ch in text:gmatch(util.UTF8_CHAR_PATTERN) do
    chars[#chars + 1] = ch
  end
  local first, last = 1, #chars
  while first <= last and (EDGE_PUNCT[chars[first]] or chars[first]:match("[%p%s]")) do
    first = first + 1
  end
  while last >= first and (EDGE_PUNCT[chars[last]] or chars[last]:match("[%p%s]")) do
    last = last - 1
  end
  if first > last then return text end
  return table.concat(chars, "", first, last)
end

-- ---------------------------------------------------------------------------
-- PTF (Poor Text Formatting) helpers
--
-- KOReader's TextBoxWidget recognizes a tiny in-band markup: text that starts
-- with \u{FFF1} and uses \u{FFF2} / \u{FFF3} to toggle synthetic-bold runs.
-- These helpers produce strings that can be passed as `text` to InfoMessage,
-- ConfirmBox, and any other widget that wraps TextBoxWidget.
--
-- Reference: frontend/ui/widget/textboxwidget.lua (PTF_* constants).
-- ---------------------------------------------------------------------------
local PTF_HEADER     = "\u{FFF1}"
local PTF_BOLD_START = "\u{FFF2}"
local PTF_BOLD_END   = "\u{FFF3}"

--- Parse text containing <b> and </b> tags into KOReader's PTF (Poor Text Formatting) bold string.
--- If no <b> tag is present, returns the input string as-is.
--- Suitable for text passed to InfoMessage, ConfirmBox, and other TextBoxWidget-backed dialogs.
---
--- Example:
---   bold_format(_("<b>API Error:</b> Bad key"))
--- @param text string|nil
--- @return string
function M.bold_format(text)
    if type(text) ~= "string" or text == "" then return text or "" end
    if not text:find("<b>", 1, true) then
        return text
    end

    local out = strbuf.new()
    out:put(PTF_HEADER)
    local in_bold = false
    local pos = 1
    local len = #text

    while pos <= len do
        if not in_bold then
            local b_start, b_end = text:find("<b>", pos, true)
            if b_start then
                if b_start > pos then
                    out:put(text:sub(pos, b_start - 1))
                end
                out:put(PTF_BOLD_START)
                in_bold = true
                pos = b_end + 1
            else
                out:put(text:sub(pos))
                break
            end
        else
            local e_start, e_end = text:find("</b>", pos, true)
            if e_start then
                if e_start > pos then
                    out:put(text:sub(pos, e_start - 1))
                end
                out:put(PTF_BOLD_END)
                in_bold = false
                pos = e_end + 1
            else
                out:put(text:sub(pos))
                break
            end
        end
    end

    if in_bold then
        out:put(PTF_BOLD_END)
    end

    return out:get()
end

--[[
    Processes the model content, converting everything after the <suggestions> tag
    into Markdown links. It safely handles cases where the closing </suggestions> tag is missing.

    @param content string: The raw LLM response text.
    @return string: The processed Markdown text.
--]]
function M.process_suggestions(content)
    if type(content) ~= "string" or content == "" then
        return content
    end

    -- Ignore <suggestions> inside the reasoning fence: search only after
    -- its closing fence (plain search)
    local fence_open = string.find(content, "```reasoning", 1, true)
    local tag_start
    if fence_open then
        local fence_close = string.find(content, "```", fence_open + 13, true)
        if not fence_close then return content end -- truncated reasoning, ignore
        tag_start = string.find(content, "<suggestions>", fence_close + 3, true)
        if not tag_start then return content end
    else
        tag_start = string.find(content, "<suggestions>", 1, true)
        if not tag_start then return content end
    end

    -- Extract the main text before the tag
    local main_body = string.sub(content, 1, tag_start - 1)

    -- Extract everything after the "<suggestions>" tag (length is 13)
    local suggestions_block = string.sub(content, tag_start + 13)

    -- Reset a fresh buffer to build the result
    local buf = strbuf.new()

    -- Append the clean main body first
    buf:put(main_body)
    buf:putf("\n\n%s\n\n", _("##### You may find these topics interesting:"))

    -- Iterate through each line after the opening tag
    for line in string.gmatch(suggestions_block, "[^\r\n]+") do
        -- Extract the question text. If a line is just "</suggestions>",
        -- it lacks a leading hyphen and will fail this match automatically.
        local question = string.match(line, "^%s*-%s*(.-)%s*$")
        if question and question ~= "" and question:find("[^%-]") then
            -- Append formatted links into C memory
            buf:putf("- [%s](#q:%s)\n", question, util.urlEncode(question))
        end
    end

    -- Serialize and return the final string
    return buf:get()
end

-- Split text at the first </think> into reasoning and answer.
-- @param ret string answer text
-- @param structured string|nil reasoning-channel text (may be nil or empty)
-- @param show_reasoning boolean wrap reasoning as ```reasoning fence when true, strip when false
-- @return string final answer text
function M.strip_think_tags(ret, structured, show_reasoning)
    if type(ret) ~= "string" then return ret end
    local close_s, close_e = ret:find("</think>", 1, true)
    local reasoning, text
    if not close_s then
        -- No inline </think>: answer is the whole ret, reasoning (if any)
        -- comes only from the structured channel (reasoning_content/thought).
        reasoning = ""
        text = ret
    else
        reasoning = ret:sub(1, close_s - 1):gsub("^%s*<think>%s*", "", 1)
        text = ret:sub(close_e + 1):gsub("^%s+", "", 1)
    end
    local combined = {}
    if type(structured) == "string" and structured ~= "" then
        table.insert(combined, structured)
    end
    if reasoning ~= "" then
        table.insert(combined, reasoning)
    end
    if #combined == 0 then return text end
    if not show_reasoning then return text end
    reasoning = table.concat(combined, "\n"):gsub("```", "\n")
    return T("```reasoning\n%1\n```\n\n%2", reasoning, text)
end

--- Single-message renderer shared by the Ask dialog and the feature dialog.
---
--- Emits the div-carrier shapes (Question / Thought / Response / Search) so
--- both result paths stay identical; the rendered HTML must stay
--- byte-identical, while _() msgids carry only human-readable words (never
--- markup).
--- @param message_history table full history, used for show_suggestions inheritance
--- @param message table the user/assistant message to format
--- @param opts table render options: title (string|nil book title),
---   msg_idx (integer|nil position in history), settings (KOReader settings),
---   default_config (table|nil suggestion fallback config)
--- @return string formatted markdown, "" when the message carries nothing to show
function M.formatSingleMessage(message_history, message, opts)
    if not message then return "" end
    if message.role == "user" then
        local user_message = strbuf.new()
        -- A preset prompt tags its user message with its display name; the
        -- viewer then shows the name instead of the full template text.
        -- Free questions carry no tag and use the title/content below.
        local prompt_title = ASUtils.get_attr(message, "prompt_title")
        local title = opts.title
        if prompt_title and prompt_title ~= "" then
            title = prompt_title
        end
        if title and title ~= "" then
            user_message:put(T('<div class="assistant-label">%1 %2</div>\n\n', "☺", _("Question")))
            user_message:putf("➤ ‹ %s ›\n", title)

            local user_input = ASUtils.get_attr(message, "user_input", "")

            -- Check if user input is available
            if user_input and user_input ~= "" then

                if user_input:find("%[BOOK TEXT BEGIN%]") then
                    user_input = user_input:gsub("%[BOOK TEXT BEGIN%].*%[BOOK TEXT END%]", "[BOOK TEXT]")
                end

                if user_input:find("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%]") then
                    user_input = user_input:gsub("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%].*%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT END%]", "[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT]")
                end

                user_message:put("➤")
                user_message:put(user_input)
                user_message:put("\n\n")
            end
            return user_message:get()
        elseif type(message.content) == "string" then
            -- shows user input prompt
            user_message:put(T('<div class="assistant-label">%1 %2</div>\n\n', "☺", _("Question")))
            local content = message.content

            if content:find("%[BOOK TEXT BEGIN%]") then
                content = content:gsub("%[BOOK TEXT BEGIN%].*%[BOOK TEXT END%]", "[BOOK TEXT]")
            end

            if content:find("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%]") then
                content = content:gsub("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%].*%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT END%]", "[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT]")
            end

            user_message:putf("\n➤ %s\n\n", content)
            return user_message:get()
        end
        -- Tool-payload user messages (table content, parts-only) carry no
        -- question text; a bare Question div would be junk, so show nothing.
        return ""
    elseif message.role == "assistant" then
        local assistant_content, answer_type, reasoning_section
        local kw = ASUtils.get_attr(message, "search_keywords")
        if kw then
            answer_type = _("Search")
            assistant_content = string.format("%s\n\n", kw)
        else
            answer_type = _("Response")
            assistant_content = message.content or _("(No response)")
            local show_for_this = ASUtils.get_attr(message, "show_suggestions")
            if show_for_this == nil and opts.msg_idx then
                for j = opts.msg_idx - 1, 1, -1 do
                    if message_history[j].role == "user" then
                        local v = ASUtils.get_attr(message_history[j], "show_suggestions")
                        if v ~= nil then show_for_this = v; break end
                    end
                end
            end
            if show_for_this == nil then
                show_for_this = Prompts.isSuggestionsEnabled(opts.settings, opts.default_config)
            end
            if show_for_this then
                assistant_content = M.process_suggestions(assistant_content)
            end

            -- Bare ```reasoning fence stored by the querier: split it off so it
            -- renders before the Response header (spacing comes from CSS).
            local reasoning_text, body = assistant_content:match(
                "^```reasoning%s*([%s%S]-)%s*```%s*([%s%S]*)$")
            if reasoning_text and reasoning_text:find("%S") then
                reasoning_section = T('<div class="assistant-label assistant-label--thought">%1 %2</div>\n\n```reasoning\n%3\n```\n\n',
                    "❖", _("Deeply Thought"), reasoning_text)
                assistant_content = body
            end
        end

        if reasoning_section then
            return reasoning_section .. T('<div class="assistant-label">%1 %2</div>\n\n%3\n\n', "✦", answer_type, assistant_content)
        end
        return T('<div class="assistant-label">%1 %2</div>\n\n%3\n\n', "✦", answer_type, assistant_content)
    end
    return "" -- Should not happen for valid roles
end

return M
