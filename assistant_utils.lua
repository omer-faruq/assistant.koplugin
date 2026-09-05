local util = require("util")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local strbuf = require("string.buffer")
local T = require("ffi/util").template
local koutil = require("util")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local https = require("ssl.https")
local json = require("rapidjson")
local Trapper = require("ui/trapper")
local M = {}
local shared_buf = strbuf.new()

-- Standalone plugin-dir resolver. assistant_gettext must NOT require this
-- module (it resolves its own l10n dir from its own source location), so the
-- dependency stays one-way: utils -> gettext.
local lfs_plugin_dir = require("libs/libkoreader-lfs")

-- PLUGIN_DIR is lazily delegated to assistant_gettext.plugin_dir (the single
-- source of truth). Tests / direct requires without gettext fall back to the
-- self-computation below.
local _cached_dir

-- Compute the plugin dir (fallback used only when main.lua has not yet set
-- M.PLUGIN_DIR, e.g. in the test suite or a direct require).
local function computePluginDir()
  local function fromSelf()
    local info = debug.getinfo(2, "S")
    local src = info and info.source and info.source:match("^@(.+)$") or ""
    local dir = src:match("(.*/)") or ""
    dir = dir:gsub("/$", "")
    if dir ~= "" and lfs_plugin_dir.attributes(dir, "mode") == "directory" then return dir end
    info = debug.getinfo(1, "S")
    src = info and info.source and info.source:match("^@(.+)$") or ""
    dir = src:match("(.*/)") or ""
    dir = dir:gsub("/$", "")
    if dir ~= "" and lfs_plugin_dir.attributes(dir, "mode") == "directory" then return dir end
    return nil
  end
  local d = fromSelf()
  if d then
    if lfs_plugin_dir.attributes(d .. "/l10n", "mode") == "directory" or lfs_plugin_dir.attributes(d .. "/lib", "mode") == "directory" then return d end
    return d
  end
  local ok, DataStorage = pcall(require, "datastorage")
  if ok and DataStorage then
    local p = DataStorage:getDataDir() .. "/plugins/assistant.koplugin"
    if lfs_plugin_dir.attributes(p, "mode") == "directory" then return p end
    return p
  end
    if lfs_plugin_dir.attributes("plugins/assistant.koplugin", "mode") == "directory" then return "plugins/assistant.koplugin" end
  return "."
end

-- Backward-compatible accessor: prefer assistant_gettext.plugin_dir (single
-- source), then the cached self-computation for tests without gettext.
function M.getPluginDir()
  if M.PLUGIN_DIR and M.PLUGIN_DIR ~= "" then return M.PLUGIN_DIR end
  if _cached_dir then return _cached_dir end
  -- Try gettext first (single source of truth).
  local ok, gt = pcall(require, "assistant_gettext")
  if ok and gt and gt.plugin_dir and gt.plugin_dir ~= "" then
    _cached_dir = gt.plugin_dir
    return _cached_dir
  end
  -- Fallback: self-compute (tests / standalone luajit without gettext).
  _cached_dir = computePluginDir()
  return _cached_dir
end

-- Initialize PLUGIN_DIR at file load so tests without main still have it.
-- getPluginDir() now delegates to assistant_gettext.plugin_dir when available.
if not M.PLUGIN_DIR then
  M.PLUGIN_DIR = M.getPluginDir()
end

-- gettext require placed after PLUGIN_DIR is set so any consumer that reads
-- utils.PLUGIN_DIR during gettext's load sees a usable value.
local _ = require("assistant_gettext")

function M.extractBookTextForAnalysis(assistant)
    local ui = assistant and assistant.ui
    local book_text = nil
      if not ui or not ui.document or not ui.document.info then return nil end
      if not ui.document.info.has_pages then
          -- Only extract text for EPUB documents
          local current_xp = ui.document:getXPointer()
          ui.document:gotoPos(0)
          local start_xp = ui.document:getXPointer()
          ui.document:gotoXPointer(current_xp)
          book_text = ui.document:getTextFromXPointers(start_xp, current_xp) or ""
          local max_text_length_for_analysis = assistant.config:getFeature("max_text_length_for_analysis", 100000)
          if #book_text > max_text_length_for_analysis then
              book_text = M.truncateToTailUtf8Safe(book_text, max_text_length_for_analysis)
          end
      else
        -- Extract text from the last n pages up to current reading position for page-based documents
        local current_page = ui.view.state.page
        local total_pages = ui.document:getPageCount()
        local max_page_size_for_analysis = assistant.config:getFeature("max_page_size_for_analysis", 250)
        local start_page = math.max(1, current_page - max_page_size_for_analysis)
        local buf = shared_buf
        buf:reset()
        for page = start_page, current_page do
            local page_text = pageTextToString(ui.document:getPageText(page))
            buf:put(page_text, "\n")
        end
        book_text = buf:get()
        local max_text_length_for_analysis = assistant.config:getFeature("max_text_length_for_analysis", 100000)
        if #book_text > max_text_length_for_analysis then
            book_text = M.truncateToTailUtf8Safe(book_text, max_text_length_for_analysis)
        end
    end
    return book_text
end

function M.extractHighlightsNotesAndNotebook(assistant, include_notebook)
    local ui = assistant and assistant.ui
    local highlights_and_notes = ""
    if ui and ui.annotation and ui.annotation.annotations then
        local buf = shared_buf
        buf:reset()
        for _, annotation in ipairs(ui.annotation.annotations) do
            if annotation.text and annotation.text ~= "" then
                buf:put("Highlight: ", annotation.text, "\n")
            end
            if annotation.note and annotation.note ~= "" then
                buf:put("Note: ", annotation.note, "\n")
            end
            if annotation.chapter then
                buf:put("Chapter: ", annotation.chapter, "\n")
            end
            if annotation.pageno then
                buf:put("Page: ", annotation.pageno, "\n")
            end
            buf:put("\n")
        end
        highlights_and_notes = buf:get()
    end
    
    local notebook_content = ""
    if include_notebook then
      pcall(function()
          local notebookfile = ui.bookinfo:getNotebookFile(ui.doc_settings)
          if notebookfile then
              local file = io.open(notebookfile, "r")
              if file then
                  local content = file:read("*all")
                  file:close()
                  local success, data = pcall(json.decode, content)
                  if success and data then
                      notebook_content = "Notebook Data:\n" .. json.encode(data)
                  else
                      notebook_content = "Notebook Content (raw):\n" .. content
                  end
              end
          end
      end)
    end
    
    local combined = highlights_and_notes
    if notebook_content ~= "" then
        if combined ~= "" then
            combined = combined .. "\n--- Notebook Content ---\n" .. notebook_content
        else
            combined = notebook_content
        end
    end
    
    local max_text_length_for_analysis = assistant.config:getFeature("max_text_length_for_analysis", 100000)
    if #combined > max_text_length_for_analysis then
        combined = M.truncateToTailUtf8Safe(combined, max_text_length_for_analysis)
    end

    return combined
end

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

--[[
  Convert a getPageText() result (string or table-of-blocks) into a plain string.
  Mirrors the table handling used in extractBookTextForAnalysis.
--]]
local function pageTextToString(t)
  if type(t) == "string" then
    return t
  elseif type(t) == "table" then
    local texts = {}
    for _, block in ipairs(t) do
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

function M.truncateToTailUtf8Safe(text, max_len)
  if #text <= max_len then return text end
  text = text:sub(-max_len)
  text = text:gsub("^[\128-\191]+", "")
  return util.fixUtf8(text, "_")
end
function M.truncateToHeadUtf8Safe(text, max_len)
  if #text <= max_len then return text end
  text = text:sub(1, max_len)
  text = text:gsub("[\128-\191]+$", "")
  return util.fixUtf8(text, "_")
end

--[[
  Pure budget-assembly helper for nearby-page context.

  Given three text segments (prev / current / next), assemble them into a single
  string bounded by max_chars:
    - current-page text has priority within max_chars;
    - any remaining budget is split evenly between prev (keep its TAIL, closest
      to the highlight) and next (keep its HEAD, closest to the highlight);
    - when current alone exceeds max_chars, only its HEAD is kept;
    - truncations drop a broken leading/trailing UTF-8 byte sequence (mirroring
      the guard style at extractBookTextForAnalysis :45-49 / :78-83);
    - non-empty parts are joined with "\n\n";
    - returns "" when everything is empty.

  Kept factored (not a method) so tests can inline a copy of it.
--]]
local function assemblePageContext(prev, current, next, max_chars)
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
      parts.prev = M.truncateToTailUtf8Safe(prev, half)
    end

    if next ~= "" then
      parts.next = M.truncateToHeadUtf8Safe(next, half)
    end
  else
    -- current alone exceeds the budget: keep its HEAD only
    parts.current = M.truncateToHeadUtf8Safe(current, max_chars)
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

  @param ui table        The KOReader ui object (ui.document, ui.highlight, ...)
  @param before number   Pages before the anchor to include in the prev segment
  @param after  number   Pages after the anchor to include in the current segment
  @param max_chars number Maximum total characters for the assembled context

  Anchor page resolution (mirrors getPageInfo):
    - paging mode:   ui.highlight.selected_text.pos0.page
    - rolling mode:  ui.document:getPageFromXPointer(pos0)

  Paged documents (document.info.has_pages): collect prev/current/next page
  texts via getPageText (clamped to [1, total], out-of-range sides skipped).

  Reflowable documents: save the xpointer, extract three segments via
  getTextFromXPointers over getPageXPointer ranges, then restore the xpointer.
--]]
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
      local t = pageTextToString(ui.document:getPageText(p))
      if t ~= "" then table.insert(prev_pages, t) end
    end
    prev = table.concat(prev_pages, "\n\n")

    current = pageTextToString(ui.document:getPageText(anchor_page))

    local next_end = math.min(total_pages, anchor_page + after)
    local next_pages = {}
    for p = anchor_page + 1, next_end do
      local t = pageTextToString(ui.document:getPageText(p))
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

  return assemblePageContext(prev, current, next, max_chars)
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

  -- Current reading position (mirrors extractBookTextForAnalysis conventions).
  -- For reflowable documents the xpointer is passed straight to the TOC
  -- lookup when the reader's TOC can handle it (ReaderToc:getTocIndexByPage
  -- accepts xpointer strings via getAccurateTocIndexByXPointer for sub-page
  -- precision); the page-based lookup remains the fallback.
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
  keeping the TAIL so the text nearest the reading position survives
  (same guard style as extractBookTextForAnalysis).

  Extraction mutates the view position and the engine's selection rendering;
  both are saved before and restored after (best effort for the selection).
--]]
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
    local buf = shared_buf
    buf:reset()
    for page = range.start_page, range.end_page do
      local ok_text, text = pcall(function() return ui.document:getPageText(page) end)
      if ok_text and text then
        buf:put(pageTextToString(text), "\n")
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
      saved_selection = util.tableDeepCopy(ui.highlight.selected_text)
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
    book_text = M.truncateToTailUtf8Safe(book_text, max_text_length_for_analysis)
  end
  return book_text
end

function M.normalizeMarkdownHeadings(content, heading_offset, max_heading_level)
  if type(content) ~= "string" or content == "" then
    return content
  end

  heading_offset = tonumber(heading_offset) or 0
  max_heading_level = tonumber(max_heading_level) or 6

  if heading_offset <= 0 then
    return content
  end

  -- Phase 1: Find the maximum heading level found in the content.
  -- Use a lightweight gmatch pattern that only captures hashes to avoid slicing full lines.
  local max_heading_level_found = nil
  for hashes in content:gmatch("\n%s*(#+)") do
    local level = #hashes
    if not max_heading_level_found or level > max_heading_level_found then
      max_heading_level_found = level
    end
  end
  
  -- Handle the first line separately since the gmatch pattern above relies on a leading newline.
  local first_hashes = content:match("^%s*(#+)")
  if first_hashes then
    local level = #first_hashes
    if not max_heading_level_found or level > max_heading_level_found then
      max_heading_level_found = level
    end
  end

  if not max_heading_level_found then
    return content
  end

  local target_max_level = heading_offset + 1
  local heading_shift = target_max_level - max_heading_level_found
  if heading_shift <= 0 then
    return content
  end

  -- Phase 2: Process and rebuild content using LuaJIT's string.buffer.
  -- Pre-allocate buffer size close to content length to prevent frequent reallocations.
  local buf = shared_buf
  buf:reset()
  
  local start_index = 1
  local content_length = #content

  while start_index <= content_length do
    local newline_index = content:find("\n", start_index, true)
    local line_end = newline_index and (newline_index - 1) or content_length
    
    local line = content:sub(start_index, line_end)
    
    -- Optimized pattern: %s* automatically strips spaces after the hashes.
    local leading_spaces, hashes, heading_text = line:match("^(%s*)(#+)%s*(.*)$")
    
    if hashes then
      -- Trim trailing spaces only, as leading spaces are already handled by the match pattern.
      heading_text = heading_text:gsub("%s*$", "")
      local new_level = #hashes + heading_shift
      
      buf:put(leading_spaces)
      if new_level > max_heading_level then
        if heading_text ~= "" then
          buf:put("**", heading_text, "**")
        else
          buf:put("**", "**")
        end
      else
        buf:put(string.rep("#", new_level)) 
        if heading_text ~= "" then
          buf:put(" ", heading_text)
        end
      end
    else
      -- Regular line, write directly to the buffer.
      buf:put(line)
    end

    if newline_index then
      buf:put("\n")
      start_index = newline_index + 1
    else
      break
    end
  end

  -- Extract the final consolidated string from continuous memory.
  return buf:get()
end

--[[
    Processes the model content, converting everything after the <suggestions> tag
    into Markdown links. It safely handles cases where the closing </suggestions> tag is missing.
    
    @param content string: The raw LLM response text.
    @param shared_buf table: The reusable string.buffer instance.
    @return string: The processed Markdown text.
--]]
function M.process_suggestions(content)
    if type(content) ~= "string" or content == "" then
        return content
    end

    -- Ignore <suggestions> inside reasoning: search only after last reasoning close tag (plain search)
    local function last_pos(tag)
        local last, pos = nil, 1
        while true do
            local s = string.find(content, tag, pos, true)
            if not s then break end
            last = s
            pos = s + 1
        end
        return last
    end
    local last_close_end
    for _, tag in ipairs({ "</div>", "</pre>" }) do
        local p = last_pos(tag)
        if p then
            local e = p + #tag - 1
            if not last_close_end or e > last_close_end then last_close_end = e end
        end
    end
    local tag_start
    if last_close_end then
        tag_start = string.find(content, "<suggestions>", last_close_end + 1, true)
        if not tag_start then return content end
    else
        if string.find(content, '<div class="reasoningtext">', 1, true)
            or string.find(content, "<pre>", 1, true) then
            return content -- has start but no close = truncated, ignore
        end
        tag_start = string.find(content, "<suggestions>", 1, true)
        if not tag_start then return content end
    end

    -- Extract the main text before the tag
    local main_body = string.sub(content, 1, tag_start - 1)
    
    -- Extract everything after the "<suggestions>" tag (length is 13)
    local suggestions_block = string.sub(content, tag_start + 13)

    -- Reset the shared buffer to reuse its memory pool
    shared_buf:reset()
    
    -- Append the clean main body first
    shared_buf:put(main_body)
    shared_buf:putf("\n\n%s\n\n", _("##### You may find these topics interesting:"))

    -- Iterate through each line after the opening tag
    for line in string.gmatch(suggestions_block, "[^\r\n]+") do
        -- Extract the question text. If a line is just "</suggestions>", 
        -- it lacks a leading hyphen and will fail this match automatically.
        local question = string.match(line, "^%s*-%s*(.-)%s*$")
        if question and question ~= "" and question:find("[^%-]") then
            -- Append formatted links into C memory
            shared_buf:putf("- [%s](#q:%s)\n", question, koutil.urlEncode(question))
        end
    end

    -- Serialize and return the final string
    return shared_buf:get()
end

--- Sets a metadata attribute on an object
--- The attribute is stored in the object's metatable under the __attr field
--- This keeps metadata separate from the object's own data fields
--- 
--- @param obj table The object to attach metadata to
--- @param key string The attribute key name
--- @param value any The attribute value (can be any Lua type)
--- @throws Error if obj is not a table
function M.set_attr(obj, key, value)
    -- Validate that we're working with a table
    if type(obj) ~= "table" then
        error("obj must be a table")
    end
    
    -- Get or create the metatable
    local mt = getmetatable(obj)
    if not mt then
        mt = {}
        setmetatable(obj, mt)
    end
    
    -- Get or create the __attr sub-table within the metatable
    if not mt.__attr then
        mt.__attr = {}
    end
    
    -- Store the key-value pair in the __attr table
    mt.__attr[key] = value
end

--- Retrieves a metadata attribute from an object
--- Looks up the attribute in the object's metatable __attr field
--- Returns nil if the object has no metatable, no __attr field, or the key doesn't exist
---
--- @param obj table The object to query
--- @param key string The attribute key name
--- @param default any Optional default value to return if attribute doesn't exist
--- @return any The attribute value, or the default value if provided, or nil
function M.get_attr(obj, key, default)
    -- Safety check: ensure we're working with a table
    if type(obj) ~= "table" then
        return default
    end
    
    -- Attempt to retrieve the metatable and __attr field
    local mt = getmetatable(obj)
    if mt and mt.__attr then
        local value = mt.__attr[key]
        -- Explicitly check for nil to distinguish between nil and false
        if value ~= nil then
            return value
        end
    end
    
    -- Return default if attribute doesn't exist or is nil
    return default
end

-- default_value for rapidjson decoded object
function M.json_default(value, default_value)
    if value == nil or value == json.null then
        return default_value
    end
    return value
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

require("ffi/zlib_h")
local libz = ffi.loadlib("z", 1)
local ZLIB_HEADER = "\x78\x9c"
local scratch = strbuf.new()
-- Enhanced uncompress that natively tolerates the Gzip-to-Zlib trailer mismatch
local function zlib_uncompress_gzip(gzip_data, max_datalen)
    local total_len = #gzip_data
    if total_len < 18 then return nil, "Data truncated" end

    local deflate_len = total_len - 18
    local src_ptr = ffi.cast("const uint8_t*", gzip_data)

    -- reused buffer
    scratch:reset()
    -- 1. Prepend a valid standard Zlib header (0x78 0x9C)
    scratch:put(ZLIB_HEADER)
    -- 2. Strip the 10-byte Gzip header
    scratch:putcdata(src_ptr + 10, deflate_len)
    local payload_ptr, payload_len = scratch:ref()

    -- 3. Prepare the memory buffers
    local buf = ffi.new("uint8_t[?]", max_datalen)
    local buflen = ffi.new("unsigned long[1]", max_datalen)

    -- 4. Invoke the low-level libz
    local res = libz.uncompress(buf, buflen,
        ffi.cast("const unsigned char*", payload_ptr), payload_len)

    -- res == 0 means perfect zlib format
    -- res == -3 (Z_DATA_ERROR) happens here because the tail has a Gzip CRC32 instead of Zlib Adler32.
    -- But since the Deflate payload itself is 100% correct, the bytes in 'buf' are ALREADY completely deflated!
    if res == 0 or res == -3 then
        local actual_len = buflen[0]
        if actual_len > 0 then
            return ffi.string(buf, actual_len)
        end
    end
    
    return nil, "Zlib core uncompress failed with severe code: " .. tostring(res)
end

--- GET HTTP HEADER VALUE
--- @param headers table
--- @param header_name string
--- @return string|nil
local function http_get_header(headers, header_name)
    if not headers then return nil end
    local lower_name = header_name:lower()

    for k, v in pairs(headers) do
        if k:lower() == lower_name then
            return v
        end
    end
    return nil
end

--- 
--- Checks content-encoding
local function http_is_encoded(headers, encoding)
    local value = http_get_header(headers, "content-encoding")
    if not value then return false end
    return value:lower():find((encoding or "gzip"):lower()) ~= nil
end

--- 
--- these codes are first defined in api_handlers/base.lua
local BaseHandler = {}
BaseHandler.CODE_CANCELLED          = "USER_CANCELED"
BaseHandler.CODE_NETWORK_ERROR      = "NETWORK_ERROR"
BaseHandler.CODE_TIMEOUT            = "REQUEST_TIMEOUT"
BaseHandler.CODE_UNSUPPORTED_PROTO  = "UNSUPPORTED_PROTOCOL"
BaseHandler.CODE_INCOMPLETE         = "INCOMPLETE_CONTENT"
BaseHandler.CODE_DECOMPRESS_ERROR   = "DECOMPRESS_ERROR"
BaseHandler.CODE_SERVER_ERROR       = "SERVER_ERROR"
M.HANDLERCODE = BaseHandler

-- httpRequest with gzip compress support, GET/POST method only
function M.httpRequest(url, timeout, maxtime, post_body, post_content_type, headers)
    local parsed = socket_url.parse(url)
    if not parsed then
        return false, BaseHandler.CODE_UNSUPPORTED_PROTO, "URL cannot reconized" .. tostring(url)
    end
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return false, BaseHandler.CODE_UNSUPPORTED_PROTO, "Unsupported protocol"
    end
    if parsed.scheme == "https" then
        https.cert_verify = false
    end
    if not timeout then timeout = 10 end
    socketutil:set_timeout(timeout, maxtime or 30)

    if not headers then
        headers = {}
    end
    headers["Accept-Encoding"] = "gzip"

    local sink = {}
    local request = {
        url     = url,
        method  = post_body and "POST" or "GET",
        headers = headers,
        sink    = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
    }
    if post_body then
        if type(post_body) ~= "string" then post_body = json.encode(post_body) end
        request.source = ltn12.source.string(post_body)
        headers["Content-Type"]   = headers["Content-Type"] or post_content_type or "application/json"
        headers["Content-Length"] = headers["Content-Length"] or tostring(#post_body)
    end

    local code, resp_headers, status = socket.skip(1, http.request(request))
    local content = table.concat(sink)
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE or
       code == socketutil.SSL_HANDSHAKE_CODE or
       code == socketutil.SINK_TIMEOUT_CODE
    then
        logger.warn("request interrupted:", code)
        return false, BaseHandler.CODE_TIMEOUT, "Request interrupted/timed out"
    end
    if resp_headers == nil then
        logger.warn("No HTTP headers:", status or code or "network unreachable")
        return false, BaseHandler.CODE_NETWORK_ERROR, "Network Error: " .. (status or code)
    end
    if not code then
        logger.warn("HTTP status not okay:", status or code or "network unreachable")
        return false, code, content or "Remote server error or unavailable"
    end

    local http_len = http_get_header(resp_headers, "content-length")
    if http_len then
        if #content ~= tonumber(http_len) then
            return false, BaseHandler.CODE_INCOMPLETE, "Incomplete content received"
        end
    end

    if http_is_encoded(resp_headers, "gzip") then
        local decompressed, err = zlib_uncompress_gzip(content, 8*1024*1024)
        if not decompressed then
            logger.warn("Failed to decompress data:", err)
            return false, BaseHandler.CODE_DECOMPRESS_ERROR, "Failed to decompress data: " .. tostring(err)
        end
        content = decompressed
    end

    return true, code, content, resp_headers
end

--- Display a count down (seconds) InfoMessage while waiting
--- for coroutine only (Trapper wrapped functions)
--- returns false when user pressed to cancel,
---         true when count down finished
function M.sleepWithInfo(seconds, info_text)
    local _coroutine = coroutine.running()
    local refresh_interval = 1
    local remaining = seconds
    while remaining > 0 do
        local wait_time = math.min(remaining, refresh_interval)
        local display_text = string.format("%s (%d)", info_text, math.ceil(remaining))
        local go_on = Trapper:info(display_text, remaining < seconds)
        if not go_on then
            Trapper:clear()
            return false
        end
        local resume_func = function() coroutine.resume(_coroutine, true) end
        UIManager:scheduleIn(wait_time, resume_func)
        local result = coroutine.yield()
        UIManager:unschedule(resume_func)
        if not result then
            Trapper:clear()
            return false
        end
        remaining = remaining - wait_time
    end
    Trapper:clear()
    return true
end


--- Extract a human-readable error message from an API response body.
--- Single shared implementation; all modules must use this instead of
--- hand-rolled tableGetValue chains. Handles common shapes:
---   { error = { message = "..." } }  -- OpenAI/standard
---   { error = "..." }                -- flat string error
---   { detail = { error = { message = "..." } } }  -- proxied (e.g. DeepSeek)
---   { detail = { message = "..." } } / { detail = "..." }
---   { message = "..." }              -- bare message
--- @param body string|table|nil raw body or already-decoded JSON
--- @return string|nil error message, or nil if none found
function M.extractErrorMessage(body)
    local decoded = body
    if type(body) == "string" then
        if #body == 0 then return nil end
        local ok, j = pcall(json.decode, body)
        if not ok or type(j) ~= "table" then return nil end
        decoded = j
    end
    if type(decoded) ~= "table" then return nil end
    local function pick(v)
        if type(v) == "string" and #v > 0 then return v end
        if type(v) == "number" then return tostring(v) end
        return nil
    end
    return pick(koutil.tableGetValue(decoded, "error", "message"))
        or pick(decoded.error)
        or pick(koutil.tableGetValue(decoded, "detail", "error", "message"))
        or pick(koutil.tableGetValue(decoded, "detail", "error"))
        or pick(koutil.tableGetValue(decoded, "detail", "message"))
        or pick(decoded.detail)
        or pick(decoded.message)
end


function M.fetchJSON(url, header, string_or_widget, timeout, maxtime, post_body)
  
  local completed, success, code, body = Trapper:dismissableRunInSubprocess(function()
    return M.httpRequest(url, timeout, maxtime, post_body, "application/json", header or {})
  end, string_or_widget)

  if type(string_or_widget) == "table" then
    UIManager:close(string_or_widget)
  end

  if not completed then
    return nil, BaseHandler.CODE_CANCELLED
  end

  if not success then
    return nil, BaseHandler.CODE_NETWORK_ERROR
  end

  if code ~= 200 then
    if body and #body > 0 then
      local ok, parsed = pcall(json.decode, body)
      if ok and parsed then
        local err_msg = M.extractErrorMessage(parsed)
        if err_msg then return nil, err_msg end
      end
      return nil, T("HTTP Status %1: %2", code, body)
    end
    return nil, T("HTTP Status %1", code)
  end

  local ok, parsed = pcall(json.decode, body)
  if not ok or not parsed then
    return nil, _("fetchJSON: failed to parse returned data")
  end

  return parsed, nil
end

--- Like NetworkMgr:runWhenOnline(), but checks Wi-Fi radio state first.
-- NetworkMgr:runWhenOnline() calls isOnline(), which does a real DNS
-- resolution and can take up to ~20s to time out before falling back to
-- the "Do you want to turn on Wi-Fi?" prompt. When Wi-Fi is already off,
-- isWifiOn() is an instant local check that reaches the same prompt
-- without waiting on the network first.
-- NOTE: NetworkMgr is lazy-required inside the function body to avoid
-- pulling in the full KOReader UI/network stack during test suite init.
function M.runWhenOnlineFast(callback)
  local NetworkMgr = require("ui/network/manager")
  if not NetworkMgr:isWifiOn() then
    NetworkMgr:promptWifiOn(callback)
    return
  end
  NetworkMgr:runWhenOnline(callback)
end

return M