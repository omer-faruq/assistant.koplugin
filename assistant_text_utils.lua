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

-- Byte budget for the selection shown in a user-bubble caption. The caption is
-- the only place a selection is displayed, so it carries a full paragraph
-- rather than a phrase; only a runaway selection is cut.
local HIGHLIGHT_CAPTION_MAX = 500

-- Chat bubble widths by turn length (see assistant_css): an action label
-- alone hugs the right edge, a question keeps the chat shape, and anything
-- longer takes the page. MuPDF has no max-width and fills whatever the margin
-- leaves, so the class is the bubble's share of the page, and a long turn in
-- the chat width would stack into a tall narrow column. The turn is measured
-- in body-text display units (a full-width glyph costs two, see
-- display_units): the chat width wraps about 30 units per line at the default
-- font, so 100 units is three to four lines. An approximation: glyph widths
-- vary with the script and the reader's font size.
local BUBBLE_TINY_MAX = 18
local BUBBLE_SHORT_MAX = 100

-- Collapse whitespace runs to single spaces, then trim. A chat caption is one
-- line, and a blank line inside a raw HTML block would end the block.
local function flatten_whitespace(text)
    return (text:gsub("%s+", " ")):match("^%s*(.-)%s*$")
end

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

-- Display width of text in Latin-glyph units, for the chat-length test (see
-- BUBBLE_SHORT_MAX): a CJK glyph renders twice as wide and costs two.
local function display_units(text)
    local units, i = 0, 1
    while i <= #text do
        local len = utf8_char_len(text:byte(i))
        if len == 0 then
            -- A stray continuation byte: count it and move on.
            i = i + 1
            units = units + 1
        else
            units = units + (util.isCJKChar(text:sub(i, i + len - 1)) and 2 or 1)
            i = i + len
        end
    end
    return units
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

--- Locate a <suggestions> block, ignoring one quoted inside a reasoning fence.
---
--- A tag inside an unterminated fence means truncated reasoning, so there is no
--- trustworthy block position and none is reported.
--- @param content string assistant content
--- @return number|nil start index of the tag, nil when there is no usable block
function M.findSuggestionsBlock(content)
    -- Ignore <suggestions> inside the reasoning fence: search only after
    -- its closing fence (plain search)
    local fence_open = string.find(content, "```reasoning", 1, true)
    if fence_open then
        local fence_close = string.find(content, "```", fence_open + 13, true)
        if not fence_close then return nil end -- truncated reasoning, ignore
        return string.find(content, "<suggestions>", fence_close + 3, true)
    end
    return string.find(content, "<suggestions>", 1, true)
end

--- Drop a <suggestions> block and everything after it.
---
--- Used when follow-up questions are off: a turn answered while the switch was
--- on still carries the raw block, and it must not reach the page as literal
--- markup.
--- @param content string assistant content
--- @return string content without the block (unchanged when there is none)
function M.stripSuggestions(content)
    if type(content) ~= "string" or content == "" then
        return content
    end
    local tag_start = M.findSuggestionsBlock(content)
    if not tag_start then return content end
    return (content:sub(1, tag_start - 1):gsub("%s+$", ""))
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

    local tag_start = M.findSuggestionsBlock(content)
    if not tag_start then return content end

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

--- Build the selection suffix of a user-bubble caption: the text flattened to
--- one line and cut to fit, prefixed with a space. Empty when there is none.
--- @param text string|nil the selected text
--- @return string caption suffix (leading space included), "" when there is nothing to append
function M.caption_highlight(text)
    if type(text) ~= "string" then return "" end
    -- A selection that is only whitespace leaves nothing to caption.
    local flat = flatten_whitespace(text)
    if flat == "" then return "" end
    if #flat > HIGHLIGHT_CAPTION_MAX then
        flat = M.truncateToHeadUtf8Safe(flat, HIGHLIGHT_CAPTION_MAX - 3) .. "..."
    end
    -- A bare space separator: no msgid needed, there are no words to translate.
    return " " .. flat
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

--- Split a stored ```reasoning fence off an assistant answer.
---
--- The querier folds reasoning into the answer only while Reasoning Text is
--- on, but a turn answered before the switch was turned off still carries its
--- fence, so the templates decide here what to do with it: show it as a
--- Thought block or keep the answer body alone.
--- @param content string stored assistant content
--- @return string|nil reasoning text, nil when there is no fence
--- @return string answer body (the whole content when there is no fence)
function M.splitReasoning(content)
    local reasoning, body = content:match("^```reasoning%s*([%s%S]-)%s*```%s*([%s%S]*)$")
    if reasoning and reasoning:find("%S") then
        return reasoning, body
    end
    return nil, content
end

--- Replace the bulky context blocks a user message may carry with a short
--- placeholder, so the displayed question stays readable.
--- @param text string user question or typed input
--- @return string same text with the book-text / notebook blocks collapsed
function M.compact_context_blocks(text)
    if text:find("%[BOOK TEXT BEGIN%]") then
        text = text:gsub("%[BOOK TEXT BEGIN%].*%[BOOK TEXT END%]", "[BOOK TEXT]")
    end
    if text:find("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%]") then
        text = text:gsub("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%].*%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT END%]", "[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT]")
    end
    return text
end

--- Minimalist-mode renderer: the reply body only.
---
--- The Response Settings minimalist mode shows the answer as plain text, so
--- this shape carries no Question/Thought/Response/Search carrier and no
--- prompt name. Kept as a separate template (not a filter over the labelled
--- one) so the result is assembled the way it will be displayed.
--- @param message table the user/assistant message to format
--- @param opts table render options: title (string|nil book title)
--- @return string formatted markdown, "" when the message carries nothing to show
function M.formatAnswerOnly(message, opts)
    if not message then return "" end
    if message.role == "user" then
        -- A preset prompt tags its user message with its display name; the
        -- template text behind that name is never shown, only what was typed.
        local title = ASUtils.get_attr(message, "prompt_title")
        if not (title and title ~= "") then
            title = opts.title
        end
        local text
        if title and title ~= "" then
            text = ASUtils.get_attr(message, "user_input", "")
        else
            text = message.content
        end
        -- Tool-payload user messages (table content, parts-only) and
        -- prompt-only turns (name dropped, nothing typed) show nothing.
        if type(text) ~= "string" or text == "" then return "" end
        return M.compact_context_blocks(text) .. "\n\n"
    elseif message.role == "assistant" then
        local kw = ASUtils.get_attr(message, "search_keywords")
        if kw then
            return string.format("%s\n\n", kw)
        end
        -- Answer only, and that includes what a turn picked up before the mode
        -- was switched on: a reasoning fence and a raw <suggestions> block.
        local _, body = M.splitReasoning(message.content or _("(No response)"))
        body = M.stripSuggestions(body)
        -- The blank line is what kept the labelled shape's blocks apart, so the
        -- next turn still starts a new markdown block.
        return body .. "\n\n"
    end
    return "" -- Should not happen for valid roles
end

-- RTL display pipeline: per-block direction annotation for rendered HTML.
--
-- MuPDF takes a block's base direction from its `dir` attribute (the CSS
-- `direction` property would inherit and suppress it), and it swaps
-- text-align left/right logically while `markup_dir` is RTL, so a block
-- marked `dir="rtl"` right-aligns on `text-align: left` (the default) and
-- puts a justified last line on the right. The caller resolves the text
-- direction mode (assistant_utils.response_direction) and runs this pass for
-- "auto" and "rtl"; "ltr" leaves the HTML untouched.

-- Bidi-strong direction of a codepoint: "r" for the RTL scripts (Hebrew,
-- Arabic and its supplements/presentation forms, Syriac, Thaana, NKo), "l"
-- for the common LTR scripts. nil for neutrals (digits, punctuation,
-- symbols, emoji), which never decide a direction on their own.
local function direction_class(cp)
    if (cp >= 0x0590 and cp <= 0x05FF)      -- Hebrew
        or (cp >= 0x0620 and cp <= 0x064A)  -- Arabic letters
        or (cp >= 0x066E and cp <= 0x06D3)  -- Arabic letters
        or (cp >= 0x06FA and cp <= 0x06FF)  -- Arabic letters
        or (cp >= 0x0700 and cp <= 0x074F)  -- Syriac
        or (cp >= 0x0750 and cp <= 0x077F)  -- Arabic Supplement
        or (cp >= 0x0780 and cp <= 0x07BF)  -- Thaana
        or (cp >= 0x07C0 and cp <= 0x07FF)  -- NKo
        or (cp >= 0x08A0 and cp <= 0x08FF)  -- Arabic Extended-A
        or (cp >= 0xFB1D and cp <= 0xFB4F)  -- Hebrew presentation forms
        or (cp >= 0xFB50 and cp <= 0xFDFF)  -- Arabic Presentation Forms-A
        or (cp >= 0xFE70 and cp <= 0xFEFF)  -- Arabic Presentation Forms-B
    then
        return "r"
    end
    if (cp >= 0x0041 and cp <= 0x005A) or (cp >= 0x0061 and cp <= 0x007A)
        or (cp >= 0x00C0 and cp <= 0x02AF)  -- Latin-1 letters + Latin extensions
        or (cp >= 0x0370 and cp <= 0x058F)  -- Greek, Cyrillic, Armenian
        or (cp >= 0x0900 and cp <= 0x0DFF)  -- Indic scripts
        or (cp >= 0x0E00 and cp <= 0x0E7F)  -- Thai
        or (cp >= 0x0F00 and cp <= 0x0FFF)  -- Tibetan
        or (cp >= 0x1000 and cp <= 0x10FF)  -- Myanmar, Georgian
        or (cp >= 0x1100 and cp <= 0x11FF)  -- Hangul Jamo
        or (cp >= 0x1E00 and cp <= 0x1EFF)  -- Latin Extended Additional
        or (cp >= 0x3040 and cp <= 0x30FF)  -- Kana
        or (cp >= 0x3400 and cp <= 0x9FFF)  -- CJK
        or (cp >= 0xAC00 and cp <= 0xD7AF)  -- Hangul syllables
        or (cp >= 0xF900 and cp <= 0xFAFF)  -- CJK compatibility
        or (cp >= 0xFF21 and cp <= 0xFF3A) or (cp >= 0xFF41 and cp <= 0xFF5A)
    then
        return "l"
    end
    return nil
end

-- Decode one UTF-8 character at byte i; returns codepoint and next index.
local function utf8_next(s, i)
    local b = s:byte(i)
    if not b then return nil, i + 1 end
    if b < 0x80 then return b, i + 1 end
    local len = utf8_char_len(b)
    local cp
    if len == 2 then cp = b - 0xC0
    elseif len == 3 then cp = b - 0xE0
    elseif len == 4 then cp = b - 0xF0
    else return nil, i + 1 end
    for j = i + 1, i + len - 1 do
        local c = s:byte(j)
        if not c or c < 0x80 or c > 0xBF then return nil, i + 1 end
        cp = cp * 64 + (c - 0x80)
    end
    return cp, i + len
end

-- Direction class of a word: the first strong character it carries.
local function word_class(word)
    local i = 1
    while i <= #word do
        local cp, next_i = utf8_next(word, i)
        if not cp then break end
        local cls = direction_class(cp)
        if cls then return cls end
        i = next_i
    end
    return nil
end

-- Base direction of a block's plain text, plus whether it carries RTL script.
--
-- Word majority first (a sentence is Persian because its function words are
-- Persian, not because of raw letter counts), first strong character as the
-- tiebreak, and the caller's default when the block has no strong character
-- at all (a table of numbers, a bare date).
local function text_direction(text, default_rtl)
    text = text:gsub("&[#%w]+;", " ")
    local rtl_words, ltr_words = 0, 0
    for word in text:gmatch("%S+") do
        local cls = word_class(word)
        if cls == "r" then
            rtl_words = rtl_words + 1
        elseif cls == "l" then
            ltr_words = ltr_words + 1
        end
    end
    local first_strong, has_rtl_script = nil, false
    local i = 1
    while i <= #text do
        local cp, next_i = utf8_next(text, i)
        if not cp then break end
        local cls = direction_class(cp)
        if cls then
            if not first_strong then first_strong = cls end
            if cls == "r" then has_rtl_script = true end
        end
        i = next_i
    end
    local rtl
    if rtl_words > ltr_words then
        rtl = true
    elseif ltr_words > rtl_words then
        rtl = false
    elseif first_strong then
        rtl = first_strong == "r"
    else
        rtl = default_rtl
    end
    return rtl, has_rtl_script
end

-- Arabic script needs the extra leading: its ascenders, descenders and
-- diacritics clip at the shared body line-height of 1.25.
local RTL_LINE_HEIGHT = "line-height:1.35"

-- Inline mirror of the base stylesheet's left insets (see assistant_css
-- BASE): MuPDF has no logical properties and no attribute selectors, so an
-- RTL block carries its own mirrored padding.
local RTL_MIRROR_PADDING = {
    p = "1em",
    ul = "2em",
    ol = "2em",
    menu = "2em",
}

-- Block elements that carry a direction of their own. Lists are included
-- because MuPDF places list markers by the element's own markup direction.
local DIRECTION_TAGS = {
    p = true, div = true, li = true, td = true, th = true, blockquote = true,
    pre = true, ul = true, ol = true, menu = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
}

-- End of a tag, honoring quoted attribute values (a `>` inside alt="..." is
-- text, not the end of the tag).
local function find_tag_end(s, start_pos)
    local in_quote
    for i = start_pos, #s do
        local c = s:byte(i)
        if in_quote then
            if c == in_quote then in_quote = nil end
        elseif c == 34 or c == 39 then
            in_quote = c
        elseif c == 62 then
            return i
        end
    end
    return nil
end

-- Rebuild an opening tag carrying the block's direction, the RTL script
-- line-height and the mirrored inset. Any dir= already on the tag is
-- replaced, and the styles are merged into an existing style attribute
-- rather than duplicating it.
local function annotate_open_tag(tag_html, name, rtl, has_rtl_script)
    local head, attrs, tail = tag_html:match("^(<%s*[%w:]+)(.-)(/?>)$")
    if not head then return tag_html end
    attrs = attrs:gsub("%s*dir%s*=%s*\"[^\"]*\"", "")
        :gsub("%s*dir%s*=%s*'[^']*'", "")
    local styles = {}
    if has_rtl_script then
        styles[#styles + 1] = RTL_LINE_HEIGHT
    end
    local inset = rtl and RTL_MIRROR_PADDING[name]
    if inset then
        styles[#styles + 1] = "padding-left:0;padding-right:" .. inset
    end
    if #styles > 0 then
        local style = table.concat(styles, ";")
        if attrs:find('style%s*=%s*"[^"]*"') then
            attrs = attrs:gsub('style%s*=%s*"([^"]*)"', 'style="%1;' .. style .. '"', 1)
        elseif attrs:find("style%s*=%s*'[^']*'") then
            attrs = attrs:gsub("style%s*=%s*'([^']*)'", "style='%1;" .. style .. "'", 1)
        else
            attrs = attrs .. ' style="' .. style .. '"'
        end
    end
    return head .. attrs .. ' dir="' .. (rtl and "rtl" or "ltr") .. '"' .. tail
end

--- Annotate the block elements of rendered HTML with a per-block direction.
---
--- Modes: "auto" gives each block the base direction of its own text
--- (descendants included), so a Persian answer with an English quote block
--- renders each side correctly; "rtl" forces every block RTL; "ltr" returns
--- the HTML untouched. Code blocks stay LTR in every mode. RTL blocks also
--- carry the Arabic line-height and the mirrored inset. The output otherwise
--- reproduces the input verbatim.
--- @param html string rendered HTML
--- @param mode string "auto" | "rtl" | "ltr"
--- @param fallback_rtl boolean direction for blocks without any strong character (auto mode)
--- @return string annotated HTML
function M.apply_block_directions(html, mode, fallback_rtl)
    if type(html) ~= "string" or html == "" or mode == "ltr" then return html end
    local chunks = {}
    -- Open annotated elements, innermost last: tag, the chunk holding the
    -- opening tag (patched at close time) and the text seen so far.
    local stack = {}
    local pos = 1
    while true do
        local lt = html:find("<", pos, true)
        local text
        if lt then
            text = html:sub(pos, lt - 1)
        else
            text = html:sub(pos)
        end
        if text ~= "" then
            chunks[#chunks + 1] = text
            for i = 1, #stack do
                local texts = stack[i].texts
                texts[#texts + 1] = text
            end
        end
        if not lt then break end
        local gt = find_tag_end(html, lt + 1)
        if not gt then
            chunks[#chunks + 1] = html:sub(lt)
            break
        end
        local tag_html = html:sub(lt, gt)
        local closing, name = tag_html:match("^<%s*(/?)%s*([%w]+)")
        if not name then
            chunks[#chunks + 1] = tag_html
        elseif closing == "/" then
            name = name:lower()
            for i = #stack, 1, -1 do
                if stack[i].tag == name then
                    local entry = table.remove(stack, i)
                    local rtl, has_rtl_script
                    if name == "pre" then
                        -- Code is LTR whatever the answer language is.
                        rtl, has_rtl_script = false, false
                    elseif mode == "rtl" then
                        rtl = true
                        has_rtl_script = select(2, text_direction(table.concat(entry.texts), true))
                    else
                        rtl, has_rtl_script = text_direction(
                            table.concat(entry.texts), not not fallback_rtl)
                    end
                    chunks[entry.chunk_idx] = annotate_open_tag(
                        chunks[entry.chunk_idx], name, rtl, has_rtl_script)
                    break
                end
            end
            chunks[#chunks + 1] = tag_html
        else
            chunks[#chunks + 1] = tag_html
            name = name:lower()
            local self_closing = tag_html:sub(-2) == "/>"
            if DIRECTION_TAGS[name] and not self_closing then
                stack[#stack + 1] = { tag = name, chunk_idx = #chunks, texts = {} }
            end
        end
        pos = gt + 1
    end
    return table.concat(chunks)
end

--- Display label of a text direction mode for the settings UI.
--- @param mode string "auto" | "rtl" | "ltr"
--- @return string localized label
function M.direction_label(mode)
    if mode == "rtl" then return _("Right to Left") end
    if mode == "ltr" then return _("Left to Right") end
    return _("Auto")
end

-- The text direction modes, in menu order. The settings radio list builds
-- from this, so every mode stays reachable.
M.DIRECTION_MODES = { "auto", "rtl", "ltr" }

-- The next mode of the viewer menu's cycling row: auto -> rtl -> ltr -> auto.
M.DIRECTION_CYCLE = { auto = "rtl", rtl = "ltr", ltr = "auto" }

--- Single-message renderer shared by the Ask dialog and the feature dialog.
---
--- Emits the div-carrier shapes (Question / Thought / Response / Search) so
--- both result paths stay identical; the rendered HTML must stay
--- byte-identical, while _() msgids carry only human-readable words (never
--- markup). The Reasoning Text switch decides whether a stored reasoning fence
--- becomes a Thought block or is dropped. With `minimal` set (the Response
--- Settings minimalist mode) the answer-only template above is used instead.
--- @param message_history table full history, used for show_suggestions inheritance
--- @param message table the user/assistant message to format
--- @param opts table render options: title (string|nil book title),
---   msg_idx (integer|nil position in history), settings (KOReader settings),
---   default_config (table|nil suggestion fallback config),
---   minimal (boolean|nil minimalist mode: render the answer-only shape)
--- @return string formatted markdown, "" when the message carries nothing to show
function M.formatSingleMessage(message_history, message, opts)
    if not message then return "" end
    if opts.minimal then
        return M.formatAnswerOnly(message, opts)
    end
    if message.role == "user" then
        -- One right-aligned bubble per turn. A preset prompt tags the turn with
        -- its name and, when the turn had a selection, that text too; both head
        -- the bubble, e.g. "< Translate > mount Doom".
        -- Free questions carry no tag and show their content alone.
        local prompt_title = ASUtils.get_attr(message, "prompt_title")
        local title = opts.title
        if prompt_title and prompt_title ~= "" then
            title = prompt_title
        end
        local body
        if title and title ~= "" then
            body = M.compact_context_blocks(ASUtils.get_attr(message, "user_input", ""))
        elseif type(message.content) == "string" then
            body = M.compact_context_blocks(message.content)
        end
        -- Tool-payload user messages (table content, parts-only) carry no
        -- question text; a bare user-bubble div would be junk, so show nothing.
        if not (title and title ~= "") and not body then
            return ""
        end
        local selection = ASUtils.get_attr(message, "highlight_text")
        if type(selection) ~= "string" then selection = nil end
        -- The Show Highlighted Text switch moves the selection out of the
        -- caption into its own block, so the bubble stops repeating it.
        local show_source = opts.settings
            and opts.settings:readSetting("show_source_text", false)

        -- The angle quotes are non-ASCII, so they ride outside _().
        local caption, meta, source = "", "", ""
        local caption_selection = ""
        if title and title ~= "" then
            if not show_source then
                caption_selection = M.caption_highlight(selection)
            end
            caption = T('<div class="user-bubble-title">‹ %1 ›%2</div>\n',
                title, caption_selection)
            -- Markup built by the dialog.
            meta = ASUtils.get_attr(message, "bubble_meta") or ""
        end
        if show_source and selection then
            -- Raw selection text: escape it, and flatten it, since a blank line
            -- inside a raw HTML block would end the block.
            local flat = flatten_whitespace(selection)
            if flat ~= "" then
                source = T('<div class="source-text">%1</div>\n',
                    T('<b>%1</b> %2', _("Highlighted text:"),
                        util.htmlEscape(flat)))
            end
        end
        -- Width by turn length (see BUBBLE_SHORT_MAX), in body-text units:
        -- the caption and meta render smaller (0.8em / 0.75em in
        -- assistant_css), so their text costs less width. The meta block
        -- counts at all because a bubble carrying title/author lines is not an
        -- action label, whatever its caption says.
        local visible_units = display_units(body or "")
            + 0.8 * display_units((title or "") .. caption_selection)
            + 0.75 * display_units((meta:gsub("<[^>]*>", " ")))
        local bubble_class = "user-bubble tiny-text"
        if visible_units > BUBBLE_SHORT_MAX then
            bubble_class = "user-bubble long-text"
        elseif visible_units > BUBBLE_TINY_MAX then
            bubble_class = "user-bubble short-text"
        end
        return T('%1<div class="%2">%3%4%5</div>\n\n',
            source, bubble_class, caption, meta, body or "")
    elseif message.role == "assistant" then
        local assistant_content, reasoning_section
        local kw = ASUtils.get_attr(message, "search_keywords")
        if kw then
            assistant_content = string.format("%s\n\n", kw)
        else
            assistant_content = message.content or _("(No response)")
            local show_for_this = ASUtils.get_attr(message, "show_suggestions")
            if show_for_this == nil and opts.msg_idx then
                -- msg_idx may sit past the end of the history we were handed,
                -- so read the turn defensively (invariant: never index blindly).
                for j = opts.msg_idx - 1, 1, -1 do
                    local prev = message_history[j]
                    if prev and prev.role == "user" then
                        local v = ASUtils.get_attr(prev, "show_suggestions")
                        if v ~= nil then show_for_this = v; break end
                    end
                end
            end
            if show_for_this == nil then
                show_for_this = Prompts.isSuggestionsEnabled(opts.settings, opts.default_config)
            end
            if show_for_this then
                assistant_content = M.process_suggestions(assistant_content)
            else
                -- A turn answered while follow-ups were on still carries the raw
                -- block; with the switch off it must not reach the page.
                assistant_content = M.stripSuggestions(assistant_content)
            end

            -- Stored ```reasoning fence: the Reasoning Text switch decides
            -- whether it becomes a thought block above the answer or is dropped.
            local reasoning_text, body = M.splitReasoning(assistant_content)
            if reasoning_text then
                assistant_content = body
                if opts.settings and opts.settings:readSetting("show_reasoning", false) then
                    reasoning_section = T('<div class="thought-block">%1</div>\n\n', reasoning_text)
                end
            end
        end

        if reasoning_section then
            return reasoning_section .. assistant_content .. "\n\n"
        end
        return assistant_content .. "\n\n"
    end
    return "" -- Should not happen for valid roles
end

return M
