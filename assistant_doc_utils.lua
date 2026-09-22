--- KOReader support helpers: book extraction, page info, online guard, fields.
local koutil = require("util")
local strbuf = require("string.buffer")
local TextUtils = require("assistant_text_utils")
local _ = require("assistant_gettext")

local M = {}

--- Extract book text up to the current reading position for analysis.
--- @param assistant table plugin object with ui and config
--- @param pages_ahead number|nil extra pages past the position (defaults to 0)
--- @return string|nil book text, or nil when no document is open
function M.extractBookTextForAnalysis(assistant, pages_ahead)
    local ui = assistant and assistant.ui
    pages_ahead = pages_ahead or 0
    local book_text = nil
      if not ui or not ui.document or not ui.document.info then return nil end
      if not ui.document.info.has_pages then
          -- Only extract text for EPUB documents
          local current_xp = ui.document:getXPointer()
          ui.document:gotoPos(0)
          local start_xp = ui.document:getXPointer()
          ui.document:gotoXPointer(current_xp)
          -- getXPointer() is the top of the current view, so the range would end
          -- before the page the reader is on. Extend `pages_ahead` pages so the
          -- visible page (and the text the reader selected there) is included.
          local end_xp = current_xp
          if pages_ahead > 0 then
              local current_page = ui.document:getPageFromXPointer(current_xp)
              if current_page then
                  local ahead_xp = ui.document:getPageXPointer(current_page + pages_ahead)
                  if ahead_xp then end_xp = ahead_xp end
              end
          end
          book_text = ui.document:getTextFromXPointers(start_xp, end_xp) or ""
          local max_text_length_for_analysis = assistant.config:getFeature("max_text_length_for_analysis", 100000)
          if #book_text > max_text_length_for_analysis then
              book_text = TextUtils.truncateToTailUtf8Safe(book_text, max_text_length_for_analysis)
          end
      else
        -- Extract text from the last n pages up to current reading position for page-based documents
        local current_page = ui.view.state.page
        local total_pages = ui.document:getPageCount()
        local max_page_size_for_analysis = assistant.config:getFeature("max_page_size_for_analysis", 250)
        local start_page = math.max(1, current_page - max_page_size_for_analysis)
        local end_page = math.min(total_pages, current_page + pages_ahead)
        local buf = strbuf.new()
        buf:reset()
        for page = start_page, end_page do
            local page_text = TextUtils.pageTextToString(ui.document:getPageText(page))
            buf:put(page_text, "\n")
        end
        book_text = buf:get()
        local max_text_length_for_analysis = assistant.config:getFeature("max_text_length_for_analysis", 100000)
        if #book_text > max_text_length_for_analysis then
            book_text = TextUtils.truncateToTailUtf8Safe(book_text, max_text_length_for_analysis)
        end
    end
    return book_text
end

--- Describe the current selection position as " (Page N - NN%) - chapter".
--- @param ui table KOReader ui object
--- @return string page info fragment, "" when no selection is active
function M.getPageInfo(ui)
  local page_number = nil
  local percentage = 0
  local total_pages = nil
  local chapter_title = nil
  if ui.highlight and ui.highlight.selected_text and ui.highlight.selected_text.pos0 then
    if ui.paging then
      page_number = ui.highlight.selected_text.pos0.page
    else
      -- For rolling mode, we could get page number using document:getPageFromXPointer
      page_number = ui.document:getPageFromXPointer(ui.highlight.selected_text.pos0)
    end

    total_pages = ui.document.info.number_of_pages
    if page_number and total_pages and total_pages ~= 0 then
      percentage = math.floor((page_number / total_pages) * 100 + 0.5)
    end

    if ui.toc and page_number then
      chapter_title = ui.toc:getTocTitleByPage(page_number)
    end
  end

  local page_lbl = _("Page")
  local page_info = ""
  if page_number and total_pages then
    page_info = string.format(" (%s %s - %s%%)", page_lbl, page_number, percentage)
  elseif page_number then
    page_info = string.format(" (%s %s)", page_lbl, page_number)
  end

  if chapter_title then
    page_info = page_info .. " - " .. chapter_title
  end

  return page_info
end

--- Read every field of a MultiInputDialog and trim surrounding whitespace.
--- Returns the trimmed values; the dialog's own widgets are not modified.
---@param dialog table A widget exposing getFields()
---@return string[]
function M.trimDialogFields(dialog)
    local fields = dialog:getFields()
    for i = 1, #fields do
        fields[i] = koutil.trim(fields[i])
    end
    return fields
end

--- Normalize record[key] in place (trim) and validate it as a credential or
--- URL. Callers pass their own localized messages so each registry keeps its
--- context-specific wording.
---@param record table
---@param key string Field name to normalize and validate
---@param opts table { required: string, whitespace: string, scheme?: string }
---        Providing `scheme` also enforces an "http(s)://" prefix (for URLs).
---@return boolean ok
---@return string|nil err
function M.validate_credential_field(record, key, opts)
    if type(record[key]) == "string" then
        record[key] = koutil.trim(record[key])
    end
    if type(record[key]) ~= "string" or record[key] == "" then
        return false, opts.required
    end
    if opts.scheme and not record[key]:match("^https?://") then
        return false, opts.scheme
    end
    if record[key]:match("%s") then
        return false, opts.whitespace
    end
    return true
end

--[[
  Pure budget-assembly helper for nearby-page context.

  Given three text segments (prev / current / next), assemble them into a single
  string bounded by max_chars:
    - current-page text has priority within max_chars;
    - any remaining budget is split evenly between prev (keep its TAIL, closest
      to the highlight) and next (keep its HEAD, closest to the highlight);
    - when current alone exceeds max_chars, only its HEAD is kept;
    - truncations drop a broken leading/trailing UTF-8 byte sequence;
    - non-empty parts are joined with "\n\n";
    - returns "" when everything is empty.
--]]
--- @param prev string|nil text before the anchor page
--- @param current string|nil anchor-page text (budget priority)
--- @param next string|nil text after the anchor page
--- @param max_chars number|nil maximum total bytes (defaults to 6000)
--- @return string assembled context, "" when everything is empty
function M.assemblePageContext(prev, current, next, max_chars)
  prev = (type(prev) == "string" and prev ~= "") and prev or ""
  current = (type(current) == "string" and current ~= "") and current or ""
  next = (type(next) == "string" and next ~= "") and next or ""

  if prev == "" and current == "" and next == "" then
    return ""
  end

  max_chars = max_chars or 6000
  local parts = {}

  if #current <= max_chars then
    parts.current = current
    local remaining = max_chars - #current
    local half = math.floor(remaining / 2)

    if prev ~= "" then
      parts.prev = TextUtils.truncateToTailUtf8Safe(prev, half)
    end

    if next ~= "" then
      parts.next = TextUtils.truncateToHeadUtf8Safe(next, half)
    end
  else
    -- current alone exceeds the budget: keep its HEAD only
    parts.current = TextUtils.truncateToHeadUtf8Safe(current, max_chars)
  end

  local out = {}
  if parts.prev and parts.prev ~= "" then table.insert(out, parts.prev) end
  if parts.current and parts.current ~= "" then table.insert(out, parts.current) end
  if parts.next and parts.next ~= "" then table.insert(out, parts.next) end
  return table.concat(out, "\n\n")
end

--[[
  Returns nearby-page text around the current text selection, or "" whenever
  anything is unavailable (no ui / document / selection pos0).

  Anchor page resolution (mirrors getPageInfo):
    - paging mode:   ui.highlight.selected_text.pos0.page
    - rolling mode:  ui.document:getPageFromXPointer(pos0)

  Paged documents (document.info.has_pages): collect prev/current/next page
  texts via getPageText (clamped to [1, total], out-of-range sides skipped).

  Reflowable documents: save the xpointer, extract three segments via
  getTextFromXPointers over getPageXPointer ranges, then restore the xpointer.
--]]
--- @param ui table KOReader ui object (ui.document, ui.highlight, ...)
--- @param before number Pages before the anchor to include in the prev segment
--- @param after number Pages after the anchor to include in the current segment
--- @param max_chars number Maximum total characters for the assembled context
--- @return string nearby-page context, "" when unavailable
function M.getPageRangeText(ui, before, after, max_chars)
  if not ui or not ui.document then
    return ""
  end
  if not ui.highlight or not ui.highlight.selected_text or not ui.highlight.selected_text.pos0 then
    return ""
  end
  if not ui.document.info then
    return ""
  end

  local pos0 = ui.highlight.selected_text.pos0
  local anchor_page
  if ui.paging then
    anchor_page = pos0.page
  else
    anchor_page = ui.document:getPageFromXPointer(pos0)
  end
  if not anchor_page then
    return ""
  end

  local total_pages = ui.document:getPageCount()
  if not total_pages or total_pages < 1 then
    return ""
  end

  before = before or 1
  after = after or 1

  local prev, current, next = "", "", ""

  if ui.document.info.has_pages then
    -- Paged documents: collect prev/current/next page texts via getPageText.
    local prev_start = math.max(1, anchor_page - before)
    local prev_pages = {}
    for p = prev_start, anchor_page - 1 do
      local t = TextUtils.pageTextToString(ui.document:getPageText(p))
      if t ~= "" then table.insert(prev_pages, t) end
    end
    prev = table.concat(prev_pages, "\n\n")

    current = TextUtils.pageTextToString(ui.document:getPageText(anchor_page))

    local next_end = math.min(total_pages, anchor_page + after)
    local next_pages = {}
    for p = anchor_page + 1, next_end do
      local t = TextUtils.pageTextToString(ui.document:getPageText(p))
      if t ~= "" then table.insert(next_pages, t) end
    end
    next = table.concat(next_pages, "\n\n")
  else
    -- Reflowable documents: use xpointer ranges (getTextFromXPointers mutates
    -- the view position, so save/restore the xpointer around extraction).
    local saved_xp = ui.document:getXPointer()
    local ok = pcall(function()
      local xp_anchor = ui.document:getPageXPointer(anchor_page)
      local xp_prev_start = ui.document:getPageXPointer(math.max(1, anchor_page - before))
      prev = ui.document:getTextFromXPointers(xp_prev_start, xp_anchor) or ""

      local xp_after = ui.document:getPageXPointer(math.min(total_pages, anchor_page + after))
      current = ui.document:getTextFromXPointers(xp_anchor, xp_after) or ""

      local xp_next_end = ui.document:getPageXPointer(math.min(total_pages, anchor_page + after + 1))
      next = ui.document:getTextFromXPointers(xp_after, xp_next_end) or ""
    end)
    -- Always restore the view position.
    pcall(function() ui.document:gotoXPointer(saved_xp) end)
    if not ok then
      return ""
    end
  end

  return M.assemblePageContext(prev, current, next, max_chars)
end

--[[
  Resolve the TOC chapter range containing the current reading position.

  NOTE on nested TOCs: "chapter" here means the flat TOC entry covering the
  position, which for nested TOCs may be a subsection (depth > 1) rather than
  the top-level chapter. Resolving the top-level chapter would require
  walking up via entry.parent/depth and is left as future work; extraction is
  scoped to the entry found here.

  Returns nil when there is no usable TOC or the position is outside it:
    - no ui / document / toc module
    - empty TOC after fillToc()
    - current page lies before the first TOC entry ("outside the TOC")

  On success returns:
    { start_page, end_page, next_page, title, start_xp, end_xp }
  where next_page/end_xp are nil for the last chapter (extraction then runs
  to the end of the document).
--]]
--- @param ui table KOReader ui object (ui.document, ui.toc, ui.view, ...)
--- @return table|nil chapter range, or nil when unresolvable
function M.getCurrentChapterRange(ui)
  if not ui or not ui.document or not ui.toc then
    return nil
  end
  if not ui.document.info then
    return nil
  end

  -- Make sure the TOC is filled and non-empty.
  local ok = pcall(function() ui.toc:fillToc() end)
  if not ok or type(ui.toc.toc) ~= "table" or #ui.toc.toc == 0 then
    return nil
  end

  local page
  local index
  if ui.document.info.has_pages then
    page = ui.view and ui.view.state and ui.view.state.page
  else
    local xp_ok, xp = pcall(function() return ui.document:getXPointer() end)
    if xp_ok and xp then
      local pg_ok, pg = pcall(function() return ui.document:getPageFromXPointer(xp) end)
      if pg_ok and pg then
        page = pg
      end
      local xp_idx_ok, xp_index = pcall(function() return ui.toc:getTocIndexByPage(xp) end)
      if xp_idx_ok and xp_index then
        index = xp_index
      end
    end
  end
  if not page then
    return nil
  end

  -- TOC entry covering the current position (nil when before the first entry).
  if not index then
    local idx_ok, idx = pcall(function() return ui.toc:getTocIndexByPage(page) end)
    if not idx_ok or not idx then
      return nil
    end
    index = idx
  end

  local toc = ui.toc.toc
  local entry = toc[index]
  -- Defensive: also treat an entry starting after our position as "outside
  -- the TOC" (covers implementations returning index 1 for early pages).
  if not entry or not entry.page or entry.page > page then
    return nil
  end

  local ok_total, total_pages = pcall(function() return ui.document:getPageCount() end)
  if not ok_total or not total_pages or total_pages < 1 then
    total_pages = nil
  end
  local next_entry = toc[index + 1]
  local end_page
  if next_entry and next_entry.page then
    end_page = math.max(entry.page, next_entry.page - 1)
  else
    end_page = total_pages or entry.page
  end

  return {
    start_page = entry.page,
    end_page = end_page,
    next_page = next_entry and next_entry.page or nil,
    title = entry.title,
    start_xp = entry.xpointer,
    end_xp = next_entry and next_entry.xpointer or nil,
  }
end

--[[
  Best-effort end-of-document xpointer for reflowable documents, so the last
  TOC chapter extracts to the true end (a page xpointer only reaches the
  start of the last page, cutting its tail). Candidates, first valid one wins:
    1. xpointer of the page after the last (engines may clamp it to the end;
       some return nil for the out-of-range page, which is discarded)
    2. gotoPos beyond the document (clamps to the end) then getXPointer()
  Falls back to the last page's start xpointer (tail loss accepted over a
  wrong range). Every probe is pcall-guarded. Candidates must be non-nil,
  differ from the current xpointer, be in-document and ordered after the
  current position (compareXPointers). The gotoPos probe, which could clamp
  mid-document in a broken engine, must additionally resolve to the last page
  (getPageFromXPointer == page_count) to be trusted.

  There is no API for "the last page's end xpointer": getXPointer() returns
  the current position and getTextFromXPointers requires both endpoints, so
  a nil end does not mean "to the end" here.
--]]
--- @param ui table KOReader ui object (ui.document, ...)
--- @return string|nil end-of-document xpointer, or nil when unresolvable
local function getDocumentEndXPointer(ui)
  -- Defensive: without a page count there is nothing to anchor the end
  -- probes on.
  local ok_count, page_count = pcall(function() return ui.document:getPageCount() end)
  if not ok_count or not page_count or page_count < 1 then
    return nil
  end
  local ok_start, start_xp = pcall(function() return ui.document:getXPointer() end)
  if not ok_start or not start_xp then
    start_xp = nil
  end

  local xp_after_last, xp_after_goto = nil, nil
  pcall(function()
    local xp = ui.document:getPageXPointer(page_count + 1)
    if xp and xp ~= start_xp then
      xp_after_last = xp
    end
  end)
  pcall(function()
    ui.document:gotoPos(2 ^ 30)
    local xp = ui.document:getXPointer()
    if xp and xp ~= start_xp then
      xp_after_goto = xp
    end
  end)
  -- Always restore the view position.
  pcall(function()
    if start_xp then ui.document:gotoXPointer(start_xp) end
  end)

  local function accepted(xp)
    if not xp or xp == start_xp then
      return false
    end
    local ok_valid, valid = pcall(function()
      return ui.document:isXPointerInDocument(xp)
          and (not start_xp or ui.document:compareXPointers(start_xp, xp) == 1)
    end)
    return ok_valid and valid
  end

  -- The page-after-last xpointer, when the engine returns one, marks the
  -- document boundary by construction.
  if accepted(xp_after_last) then
    return xp_after_last
  end
  -- The gotoPos probe must resolve to the last page to prove it reached the
  -- true end (and not some mid-document clamp); when the engine cannot tell
  -- us, trust the in-document + ordered checks above.
  if accepted(xp_after_goto) then
    local ok_page, page = pcall(function() return ui.document:getPageFromXPointer(xp_after_goto) end)
    if not ok_page or not page or page == page_count then
      return xp_after_goto
    end
  end
  local ok_last, last_xp = pcall(function() return ui.document:getPageXPointer(page_count) end)
  return ok_last and last_xp or nil
end

--[[
  Extract the text of the current TOC chapter (see getCurrentChapterRange).

  Returns nil when the chapter range cannot be resolved (no TOC / position
  outside it), otherwise a string trimmed to features.max_text_length_for_analysis,
  keeping the TAIL so the text nearest the reading position survives.

  Extraction mutates the view position and the engine's selection rendering;
  both are saved before and restored after (best effort for the selection).
--]]
--- @param assistant table plugin object with ui and config
--- @return string|nil chapter text, or nil when the range cannot be resolved
function M.extractCurrentChapterText(assistant)
  local ui = assistant and assistant.ui
  local range = M.getCurrentChapterRange(ui)
  if not range then
    return nil
  end

  local book_text = ""
  if ui.document.info.has_pages then
    -- Paged documents: collect the chapter's page texts (per-page pcall so a
    -- failing page is skipped instead of aborting the whole extraction).
    local buf = strbuf.new()
    buf:reset()
    for page = range.start_page, range.end_page do
      local ok_text, text = pcall(function() return ui.document:getPageText(page) end)
      if ok_text and text then
        buf:put(TextUtils.pageTextToString(text), "\n")
      end
    end
    book_text = buf:get()
  else
    -- Reflowable documents: xpointer range (extraction mutates the view
    -- position, so save/restore the xpointer around it, as getPageRangeText).
    -- getTextFromXPointers also drives the engine's selection rendering, so
    -- preserve any active text selection alongside the position.
    local saved_xp
    local ok_xp, xp = pcall(function() return ui.document:getXPointer() end)
    if ok_xp then
      saved_xp = xp
    end
    local saved_selection
    if ui.highlight and ui.highlight.selected_text
        and ui.highlight.selected_text.pos0 and ui.highlight.selected_text.pos1 then
      saved_selection = koutil.tableDeepCopy(ui.highlight.selected_text)
    end
    local ok = pcall(function()
      local start_xp = range.start_xp
      if not start_xp then
        start_xp = ui.document:getPageXPointer(range.start_page)
      end
      local end_xp = range.end_xp
      if not end_xp then
        if range.next_page then
          -- No xpointer on the next TOC entry: an end xpointer at the START
          -- of the following page still includes the chapter's final page
          -- (same boundary convention as getPageRangeText).
          end_xp = ui.document:getPageXPointer(range.next_page)
        else
          -- Last chapter: extract to the true end of the document.
          end_xp = getDocumentEndXPointer(ui)
        end
      end
      book_text = ui.document:getTextFromXPointers(start_xp, end_xp) or ""
    end)
    -- Always restore the view position.
    pcall(function()
      if saved_xp then ui.document:gotoXPointer(saved_xp) end
    end)
    -- Restore the text selection the extraction disturbed. There is no
    -- ReaderHighlight API to re-select, so restore the state table and, for
    -- rolling documents (pos0/pos1 are xpointers), re-issue the engine's own
    -- draw-selection call the way readerhighlight.lua does.
    if saved_selection then
      pcall(function()
        ui.highlight.selected_text = saved_selection
        local sel_pos0, sel_pos1 = saved_selection.pos0, saved_selection.pos1
        if type(sel_pos0) == "string" and type(sel_pos1) == "string" then
          ui.document:getTextFromXPointers(sel_pos0, sel_pos1, true)
        end
      end)
    end
    if not ok then
      return nil
    end
  end

  local max_text_length_for_analysis = assistant.config:getFeature("max_text_length_for_analysis", 100000)
  if #book_text > max_text_length_for_analysis then
    book_text = TextUtils.truncateToTailUtf8Safe(book_text, max_text_length_for_analysis)
  end
  return book_text
end

return M
