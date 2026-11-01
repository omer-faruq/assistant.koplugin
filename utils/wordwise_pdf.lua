--[[--
Word Wise, PDF support: pure Lua helpers with NO KOReader dependencies (testable
with a plain Lua interpreter).

A PDF page is a fixed layout. Its text comes from the text layer as "text boxes":

    boxes[i]    = a line   { x0, y0, x1, y1, [j] = word ... }
    boxes[i][j] = a word   { x0, y0, x1, y1, word = "text" }

in page coordinates at zoom 1.0 (what KOReader's PdfDocument:getPageTextBoxes()
returns). Word Wise needs three things from them:

  * a stable position for every word, usable as a key in the hint store. It is the
    string "page:line:word" (zero padded, so plain string order is document order);
  * the words of a page in reading order, for the AI request and for matching its
    answer (words broken by a hyphen at the end of a line are joined);
  * how much room there is above a line, because nothing can be made room for in a
    fixed layout: a hint has to fit into the gap between two lines.
]]

local PDF = {}

---------------------------------------------------------------------------
-- Positions
---------------------------------------------------------------------------

--- Position key of word `word` on line `line` of `page`.
function PDF.key(page, line, word)
  return string.format("%06d:%04d:%04d", page, line or 0, word or 0)
end

--- @return integer|nil page
--- @return integer|nil line
--- @return integer|nil word
function PDF.parse(key)
  if type(key) ~= "string" then return nil end
  local p, l, w = key:match("^(%d+):(%d+):(%d+)$")
  if not p then return nil end
  return tonumber(p), tonumber(l), tonumber(w)
end

--- Comparator in the store's convention: 1 if b is after a, 0 if the same,
--- -1 if before, nil if a key is invalid.
function PDF.compare(a, b)
  local pa, la, wa = PDF.parse(a)
  local pb, lb, wb = PDF.parse(b)
  if not (pa and pb) then return nil end
  if pa ~= pb then return pa < pb and 1 or -1 end
  if la ~= lb then return la < lb and 1 or -1 end
  if wa ~= wb then return wa < wb and 1 or -1 end
  return 0
end

--- Start (inclusive) and end (exclusive) key of a page. The end is nil for the
--- last page of the document, like the end of a reflowable book.
function PDF.pageRange(page, total)
  local a = PDF.key(page, 0, 0)
  local b
  if page < total then b = PDF.key(page + 1, 0, 0) end
  return a, b
end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

local function num(v)
  return type(v) == "number" and v == v
end

--- Extent of a line: x0, x1, y0, y1 (nil when it has no usable box).
local function lineGeom(line)
  if type(line) ~= "table" then return end
  local x0, x1, y0, y1
  for j = 1, #line do
    local w = line[j]
    if type(w) == "table" and num(w.x0) and num(w.x1) then
      if not x0 or w.x0 < x0 then x0 = w.x0 end
      if not x1 or w.x1 > x1 then x1 = w.x1 end
    end
  end
  if num(line.y0) and num(line.y1) then
    y0, y1 = line.y0, line.y1
  else
    for j = 1, #line do
      local w = line[j]
      if type(w) == "table" and num(w.y0) and num(w.y1) then
        if not y0 or w.y0 < y0 then y0 = w.y0 end
        if not y1 or w.y1 > y1 then y1 = w.y1 end
      end
    end
  end
  if x0 and x1 and y0 and y1 then return x0, x1, y0, y1 end
end
PDF.lineGeom = lineGeom

--- Bounding box of all the text of the page.
--- @return table|nil { x0, y0, x1, y1 }
function PDF.pageExtent(boxes)
  local ext
  for i = 1, #boxes do
    local x0, x1, y0, y1 = lineGeom(boxes[i])
    if x0 then
      if not ext then
        ext = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
      else
        if x0 < ext.x0 then ext.x0 = x0 end
        if y0 < ext.y0 then ext.y0 = y0 end
        if x1 > ext.x1 then ext.x1 = x1 end
        if y1 > ext.y1 then ext.y1 = y1 end
      end
    end
  end
  return ext
end

--- Free space (page units) between line `i` and the nearest line above it that
--- overlaps the horizontal range x0..x1. Never negative. nil when there is no line
--- above (top of the page or of a column): the caller decides how much room to assume.
function PDF.gapAbove(boxes, i, x0, x1)
  local lx0, lx1, ly0, ly1 = lineGeom(boxes[i])
  if not lx0 then return nil end
  local tol = (ly1 - ly0) * 0.3 -- another piece of the same text line is not "above"
  local best
  for k = 1, #boxes do
    if k ~= i then
      local gx0, gx1, gy0, gy1 = lineGeom(boxes[k])
      if gx0 and gy0 < ly0 - tol and gx0 < x1 and gx1 > x0 then
        if not best or gy1 > best then best = gy1 end
      end
    end
  end
  if not best then return nil end
  return math.max(0, ly0 - best)
end

--- Bottom edge (screen y) of a hint label of height `th` in a gap of `gap` pixels
--- above a line starting at screen y `top`. "close" is next to the word, "high"
--- at the top of the gap, "middle" in between. `inner` (pixels, default 0) lets the
--- label reach that far into the empty top of the line box, and `gap` is then the
--- whole room measured from `top - inner`.
function PDF.hintBottom(top, gap, th, position, inner)
  local close = math.floor(top - 1 + (inner or 0))
  local free = math.max(0, gap - th - 1)
  if position == "high" then return math.floor(close - free) end
  if position == "middle" then return math.floor(close - free / 2) end
  return close
end

---------------------------------------------------------------------------
-- Words
---------------------------------------------------------------------------

-- Hyphens that may end a line: "-", U+2010, U+00AD (soft hyphen).
local HYPHENS = { "-", "\226\128\144", "\194\173" }

--- "inter-" -> "inter" (nil when the word does not end with a hyphen or is too short).
local function stripHyphen(text)
  for _, h in ipairs(HYPHENS) do
    if #text > #h and text:sub(-#h) == h then
      local stem = text:sub(1, #text - #h)
      local last = stem:byte(-1)
      -- the character before the hyphen must be a letter (ASCII or any non-ASCII byte)
      local letter = last and ((last >= 65 and last <= 90) or (last >= 97 and last <= 122) or last >= 128)
      if letter and #stem >= 2 then return stem end
    end
  end
end

--- Does the text continue a word, i.e. start with a lower-case letter?
local function startsLower(s)
  local b = s:byte(1)
  return b ~= nil and ((b >= 97 and b <= 122) or b >= 195)
end

--- First word of the first non-empty line after line `i`.
local function nextWord(boxes, i)
  for k = i + 1, #boxes do
    local line = boxes[k]
    if type(line) == "table" then
      for j = 1, #line do
        local w = line[j]
        if type(w) == "table" and type(w.word) == "string" and w.word ~= "" then
          return k, j
        end
      end
    end
  end
end

--- The words of a page in reading order.
--- A word broken by a hyphen at the end of a line is joined with its second half;
--- it counts as one word that starts on the first line (xp1 points at the second half).
--- @param boxes table text boxes of the page
--- @param page integer
--- @param max_words integer|nil safety cap
--- @return table[] words { text, xp0, xp1, line, j0 }
--- @return string text of the page, one text line per line of the layer
function PDF.collect(boxes, page, max_words)
  local words, out = {}, {}
  local skip = {}
  max_words = max_words or math.huge
  for i = 1, #boxes do
    local line = boxes[i]
    local texts = {}
    if type(line) == "table" then
      local n = #line
      for j = 1, n do
        local w = line[j]
        if not (skip[i] and skip[i][j]) and type(w) == "table"
            and type(w.word) == "string" and w.word ~= "" then
          local entry = {
            text = w.word,
            xp0 = PDF.key(page, i, j), xp1 = PDF.key(page, i, j),
            line = i, j0 = j,
          }
          if j == n then
            local stem = stripHyphen(w.word)
            if stem then
              local ni, nj = nextWord(boxes, i)
              if ni and startsLower(boxes[ni][nj].word) then
                entry.text = stem .. boxes[ni][nj].word
                entry.xp1 = PDF.key(page, ni, nj)
                skip[ni] = skip[ni] or {}
                skip[ni][nj] = true
              end
            end
          end
          words[#words + 1] = entry
          texts[#texts + 1] = entry.text
          if #words >= max_words then break end
        end
      end
    end
    if #texts > 0 then out[#out + 1] = table.concat(texts, " ") end
    if #words >= max_words then break end
  end
  return words, table.concat(out, "\n")
end

--- Where a stored hint goes: the first word of the hint and, when the hint covers
--- several words of the same line, all of them.
--- @return table|nil { x0, x1, y0, y1, word, line } y0/y1 = top/bottom of the text line
function PDF.locate(boxes, k0, k1)
  local p0, i0, j0 = PDF.parse(k0)
  if not p0 then return nil end
  local p1, i1, j1 = PDF.parse(k1 or k0)
  local line = boxes[i0]
  if type(line) ~= "table" then return nil end
  local first = line[j0]
  if type(first) ~= "table" or type(first.word) ~= "string" then return nil end
  local last = first
  if p1 == p0 and i1 == i0 and j1 and j1 > j0 then
    local l = line[j1]
    if type(l) == "table" and num(l.x1) then last = l end
  end
  local _, _, y0, y1 = lineGeom(line)
  if not (y0 and num(first.x0) and num(last.x1) and last.x1 > first.x0 and y1 > y0) then
    return nil
  end
  return { x0 = first.x0, x1 = last.x1, y0 = y0, y1 = y1, word = first.word, line = i0 }
end

return PDF
