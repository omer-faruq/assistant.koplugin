--[[--
Word Wise: short AI hints printed directly above difficult words, phrasal verbs
and idioms of the page being read (reflowable books, and PDF files that have a
text layer).

How it works
  * The whole page text goes to the AI, which decides what is hard for the
    reader's level and answers with short hints (see utils/wordwise_core).
  * Requests run in a forked subprocess (the same way the streaming querier
    does it), so reading is never blocked and no "waiting" dialog appears.
  * The current page is requested first, then the next N pages are pre-fetched,
    so hints are normally ready before the page is turned.
  * Hints are stored by document position (not page number) in a per-book cache
    on disk (utils/wordwise_store): turning back, re-opening the book or
    changing the font size costs no new request.
  * The module is a ReaderView view module: hints are painted over the page in
    paintTo(); layout is computed once per page and reused on every repaint.
  * PDF: a page is a fixed layout, so no room can be made for the hints. Words and
    their boxes come from the text layer (utils/wordwise_pdf), a position is a
    "page:line:word" key instead of an xpointer, and a hint is drawn into the gap
    above its line, shrunk to fit. Where the gap is too small the hint is left out.
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Notification = require("ui/widget/notification")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local koutil = require("util")
local logger = require("logger")
local rapidjson = require("rapidjson")
local T = ffiutil.template
local _ = require("core/gettext")
local Core = require("utils/wordwise_core")
local Store = require("utils/wordwise_store")
local PDF = require("utils/wordwise_pdf")

local Screen = Device.screen

local DEFAULTS = {
  enabled = false,
  level = "B1",
  lang = "English",
  density = "medium",
  prefetch = 2,
  size = 65,         -- hint font size, % of the book font
  offset = 0,        -- extra vertical offset in px (positive = lower)
  max_chars = 24,
  all = false,       -- hint every occurrence of an expression on the page
  color = "black",   -- "gray" | "black"
  bold = true,
  position = "close", -- "close" | "middle" | "high" (inside the extra line spacing)
  style = "synonym",  -- "synonym" | "definition"
  auto_spacing = true, -- raise the book's line spacing automatically to make room
  spacing = 150,       -- % line spacing used for that (the font itself is never changed)
  provider = "",     -- "" = same provider as the AI Assistant
  pdf_min_size = 8,  -- PDF: smallest hint font (px) before a hint is left out for lack of room
  pdf_squeeze = 35,  -- PDF: % of a line's height a hint may borrow from the line above (descender zone)
}

local DEBOUNCE = 0.4            -- s to wait after a page turn before requesting
local POLL_INTERVAL = 0.2       -- s between checks of running requests
local REQUEST_TIMEOUT = 80      -- s before a request subprocess is killed
local MAX_CONCURRENT = 2        -- parallel AI requests
local MAX_PER_MINUTE = 30       -- hard brake against runaway request loops
local MAX_WORDS_WALK = 2500     -- safety cap when walking a page word by word
local MAX_TEXT_CHARS = 16000    -- longest page text sent to the AI
local MIN_WORDS = 6             -- pages with fewer words are not worth a request
local FLUSH_DELAY = 30          -- s of quiet before the cache is written to disk
local MAX_HINTS_PER_BOOK = 15000
local READ_CHUNK = 16384

local WordWise = {}
WordWise.__index = WordWise
WordWise.DEFAULTS = DEFAULTS

---------------------------------------------------------------------------
-- Subprocess bookkeeping shared by all instances (survives document close)
---------------------------------------------------------------------------

local zombies = {}
local reaper_scheduled = false

local function reapZombies()
  reaper_scheduled = false
  for i = #zombies, 1, -1 do
    if ffiutil.isSubProcessDone(zombies[i]) then table.remove(zombies, i) end
  end
  if #zombies > 0 then
    reaper_scheduled = true
    UIManager:scheduleIn(1, reapZombies)
  end
end

local function killProcess(pid)
  ffiutil.terminateSubProcess(pid)
  zombies[#zombies + 1] = pid
  if not reaper_scheduled then
    reaper_scheduled = true
    UIManager:scheduleIn(0.5, reapZombies)
  end
end

local function now()
  return os.time()
end

---------------------------------------------------------------------------
-- Construction / settings
---------------------------------------------------------------------------

function WordWise:new(assistant)
  local o = setmetatable({}, self)
  o.assistant = assistant
  o.ui = assistant.ui
  o.settings = assistant.settings
  o.running = false           -- start() called and not yet stopped
  o.queue = {}                -- jobs waiting for a free slot
  o.active = {}               -- jobs with a live subprocess
  o.layout = {}               -- painted hints of the current page
  o.layout_key = nil
  o.layout_rev = 0
  o.failures = 0
  o.retry_at = 0
  o.offline_prompted = false  -- asked about Wi-Fi during this offline spell
  o.recent = {}               -- timestamps of recent requests
  o.store = nil
  o.sig = nil
  o.cache_ls = nil
  o.cache_dirty = false
  o.waiting_current = false   -- the page on screen still lacks its hints
  o.plan_fn = function() o:plan() end
  o.poll_fn = function()
    o.poll_scheduled = false
    o:poll()
  end
  o.flush_fn = function() o:flushCache() end
  return o
end

--- Setting with default (never writes the default into the settings file).
function WordWise:cfg(key)
  local v = self.settings:readSetting("wordwise_" .. key)
  if v == nil then return DEFAULTS[key] end
  return v
end

function WordWise:setCfg(key, value)
  self.settings:saveSetting("wordwise_" .. key, value)
  self.assistant.updated = true
end

--- Reflowable book (crengine): EPUB, FB2, MOBI, HTML ...
function WordWise:isReflowable()
  local ui = self.ui
  return ui and ui.document and ui.rolling ~= nil and not ui.paging
end

--- Fixed-layout document with a text layer (PDF).
function WordWise:isPaged()
  local ui = self.ui
  local doc = ui and ui.document
  return doc ~= nil and ui.paging ~= nil and type(doc.getPageTextBoxes) == "function"
end

function WordWise:isSupported()
  return self:isReflowable() or self:isPaged()
end

--- PDF shown in reflow mode: the words are laid out again by the PDF engine, the
--- boxes of the text layer no longer match the screen, so no hints are shown.
function WordWise:pagedBlocked()
  if not self:isPaged() then return false end
  local conf = self.ui.document.configurable
  return conf ~= nil and conf.text_wrap == 1
end

function WordWise:isEnabled()
  return self:isSupported() and self:cfg("enabled") == true
end

--- Current line spacing of the book, in percent.
function WordWise:lineSpacing()
  local conf = self.ui.font and self.ui.font.configurable
  return tonumber(conf and conf.line_spacing) or 100
end

--- Line spacing (%) used to leave room for the hints.
function WordWise:targetSpacing()
  local v = tonumber(self:cfg("spacing")) or 150
  if v < 100 then v = 100 end
  return v
end

--- Leave room above the lines for the hints. The setting persists per book; the
--- previous value is remembered so that turning Word Wise off can restore it.
--- Only the line spacing is touched, never the font.
--- @return boolean true when the spacing was changed
function WordWise:raiseLineSpacing()
  if not self:isReflowable() then return false end
  local cur, target = self:lineSpacing(), self:targetSpacing()
  if cur >= target then return false end
  local ds = self.ui.doc_settings
  if ds then
    if ds:readSetting("assistant_wordwise_prev_spacing") == nil then
      ds:saveSetting("assistant_wordwise_prev_spacing", cur)
    end
    ds:saveSetting("assistant_wordwise_applied_spacing", target)
  end
  self.ui:handleEvent(Event:new("SetLineSpace", target))
  return true
end

--- Undo raiseLineSpacing(), unless the reader has changed the spacing since.
function WordWise:restoreLineSpacing()
  if not self:isReflowable() then return end
  local ds = self.ui.doc_settings
  if not ds then return end
  local prev = ds:readSetting("assistant_wordwise_prev_spacing")
  local applied = ds:readSetting("assistant_wordwise_applied_spacing") or 150
  ds:delSetting("assistant_wordwise_prev_spacing")
  ds:delSetting("assistant_wordwise_applied_spacing")
  ds:delSetting("assistant_wordwise_spacing_done")
  if prev and self:lineSpacing() == applied then
    self.ui:handleEvent(Event:new("SetLineSpace", prev))
  end
end

--- The "Line Spacing" setting or the automatic switch changed while Word Wise is on.
function WordWise:onSpacingSettingChanged()
  if not (self:isEnabled() and self:isReflowable()) then return end
  local ds = self.ui.doc_settings
  local applied = ds and ds:readSetting("assistant_wordwise_applied_spacing")
  if self:cfg("auto_spacing") == false then
    -- Automatic mode switched off: give back what we changed, then leave the spacing alone.
    if applied then self:restoreLineSpacing() end
    return
  end
  local target = self:targetSpacing()
  if applied and self:lineSpacing() == applied and applied ~= target then
    ds:saveSetting("assistant_wordwise_applied_spacing", target)
    self.ui:handleEvent(Event:new("SetLineSpace", target))
  else
    self:raiseLineSpacing()
  end
end

--- Once per book: raise the line spacing the first time hints are shown in it.
function WordWise:prepareBook()
  if not self:isReflowable() then return end
  local ds = self.ui.doc_settings
  if self:cfg("auto_spacing") == false then return end
  if not ds or ds:readSetting("assistant_wordwise_spacing_done") then return end
  ds:saveSetting("assistant_wordwise_spacing_done", true)
  self:raiseLineSpacing()
end

--- Cache signature: hints made with other settings are kept apart.
function WordWise:signature()
  return table.concat({
    self:cfg("level"), self:cfg("lang"), self:cfg("density"), self:cfg("style"),
    self:cfg("all") and "all" or "first", Core.PROMPT_VERSION,
  }, "|")
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

--- Register the paint module. Cheap; safe to call on every document open.
function WordWise:start()
  if not self:isSupported() or self.running then return end
  self.running = true
  self.ui.view:registerViewModule("assistant_wordwise", self)
  if self:cfg("enabled") then
    self:activate()
  end
end

--- Called when the document closes.
function WordWise:stop()
  if not self.running then return end
  self:abortAll()
  self:flushCache()
  self:freeLayout()
  UIManager:unschedule(self.plan_fn)
  UIManager:unschedule(self.poll_fn)
  UIManager:unschedule(self.flush_fn)
  self.running = false
  self.store = nil
  self.cache_ls = nil
end

--- Load the cache and start planning requests.
function WordWise:activate()
  self:openCache()
  self:prepareBook()
  self.failures, self.retry_at = 0, 0
  self.offline_prompted = false
  self:invalidateLayout()
  self:schedulePlan(0.1)
end

function WordWise:setEnabled(on)
  if not self:isSupported() then return false end
  if on then
    if not self.assistant:isConfigured() then return false end
    self:setCfg("enabled", true)
    self:activate()
    if self:isPaged() and not self.settings:readSetting("wordwise_pdf_tip_shown") then
      self.settings:saveSetting("wordwise_pdf_tip_shown", true)
      UIManager:show(InfoMessage:new{
        text = _([[Word Wise is on.

Hints are fetched from your AI provider while you read, so an internet connection is needed. Pages you have already seen are cached and cost nothing.

A PDF has a fixed layout, so hints can only go into the gap above a line, a little over the lower part of the line above. Where even that is too small for readable text, the hint is left out. You can tune this in Hint Appearance (PDF: Squeeze Hints Closer, PDF: Smallest Hint Size). Zooming in does not help, as the gaps grow with the text. Scanned PDFs without a text layer are not supported, and neither is Reflow mode.]]),
      })
    elseif self:isReflowable() and not self.settings:readSetting("wordwise_tip_shown") then
      self.settings:saveSetting("wordwise_tip_shown", true)
      UIManager:show(InfoMessage:new{
        text = _([[Word Wise is on.

Hints are fetched from your AI provider while you read, so an internet connection is needed. Pages you have already seen are cached and cost nothing.

Hints sit in the gap above each word, so the line spacing of the book was raised a little to leave room for them. You can change it any time in the Typeset menu.

Tip: a fast model without "thinking" gives the quickest hints.]]),
      })
    end
  else
    self:setCfg("enabled", false)
    self:abortAll()
    self:flushCache()
    self:freeLayout()
    UIManager:unschedule(self.plan_fn)
    self:restoreLineSpacing()
  end
  self:refresh()
  return true
end

---------------------------------------------------------------------------
-- Cache (per book, on disk)
---------------------------------------------------------------------------

local function cacheDir()
  return DataStorage:getDataDir() .. "/cache/assistant_wordwise"
end

function WordWise:bookId()
  local ui = self.ui
  local id = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
  if id and id ~= "" then return id end
  local path = ui.document and ui.document.file or "unknown"
  local ok, sha2 = pcall(require, "ffi/sha2")
  if ok and sha2.md5 then return sha2.md5(path) end
  return (path:gsub("[^%w]", "_"))
end

function WordWise:cmp()
  if self:isPaged() then return PDF.compare end
  local doc = self.ui.document
  return function(a, b) return doc:compareXPointers(a, b) end
end

--- Open the cache file and select the store matching the current settings.
function WordWise:openCache()
  if not self.running then return end
  local doc = self.ui.document
  local dir = cacheDir()
  koutil.makePath(dir)
  local path = dir .. "/" .. self:bookId() .. ".lua"
  if not self.cache_ls then
    self.cache_ls = LuaSettings:open(path)
  end
  self.sig = self:signature()
  local stores = self.cache_ls:readSetting("stores") or {}
  local data = stores[self.sig]
  local store
  if data then
    local is_valid
    if self:isPaged() then
      local total = doc:getPageCount()
      is_valid = function(key)
        local page = PDF.parse(key)
        return page ~= nil and page >= 1 and page <= total
      end
    else
      is_valid = function(xp)
        local ok, valid = pcall(function() return doc:isXPointerInDocument(xp) end)
        return ok and valid
      end
    end
    store = Store.load(self:cmp(), data, is_valid)
    if not store then logger.warn("Word Wise: discarded unusable cache for", self.sig) end
  end
  self.store = store or Store.new(self:cmp())
end

function WordWise:flushCache()
  UIManager:unschedule(self.flush_fn)
  if not (self.cache_ls and self.store and self.cache_dirty) then return end
  local stores = self.cache_ls:readSetting("stores") or {}
  stores[self.sig] = self.store:dump()
  stores[self.sig].used = now()
  -- Keep the three most recently used signatures.
  local sigs = {}
  for s, d in pairs(stores) do sigs[#sigs + 1] = { s = s, used = d.used or 0 } end
  if #sigs > 3 then
    table.sort(sigs, function(a, b) return a.used > b.used end)
    for i = 4, #sigs do stores[sigs[i].s] = nil end
  end
  self.cache_ls:saveSetting("stores", stores)
  local ok, err = pcall(function() self.cache_ls:flush() end)
  if ok then
    self.cache_dirty = false
  else
    logger.warn("Word Wise: cache write failed:", err)
  end
end

function WordWise:markCacheDirty()
  self.cache_dirty = true
  UIManager:unschedule(self.flush_fn)
  UIManager:scheduleIn(FLUSH_DELAY, self.flush_fn)
end

--- Forget all hints of this book (all settings variants).
function WordWise:clearCache()
  self:abortAll()
  if self.store then self.store:clear() end
  if self.cache_ls then
    self.cache_ls:saveSetting("stores", {})
    pcall(function() self.cache_ls:flush() end)
  end
  self.cache_dirty = false
  self:invalidateLayout()
  self:refresh()
  self:schedulePlan(0.1)
end

function WordWise:cachedCount()
  return self.store and self.store:count() or 0
end

---------------------------------------------------------------------------
-- Settings changes
---------------------------------------------------------------------------

--- Call after changing level / language / density / "all occurrences".
function WordWise:onRequestSettingsChanged()
  if not self:isEnabled() then return end
  self:abortAll()
  self:flushCache()
  self:openCache()
  self:invalidateLayout()
  self:refresh()
  self:schedulePlan(0.3)
end

--- Call after changing size / offset / length / color.
function WordWise:onAppearanceChanged()
  self:invalidateLayout()
  if self:isEnabled() then self:refresh() end
end

---------------------------------------------------------------------------
-- Events from the reader
---------------------------------------------------------------------------

function WordWise:onPageChanged()
  if not (self.running and self:isEnabled()) then return end
  self:schedulePlan(DEBOUNCE)
end

--- PDF in continuous scroll mode: scrolling reveals new pages without a page turn.
function WordWise:onViewChanged()
  if not (self.running and self:isPaged() and self:isEnabled()) then return end
  local view = self.view or (self.ui and self.ui.view)
  if view and view.page_scroll then self:schedulePlan(DEBOUNCE) end
end

function WordWise:onRerendered()
  if not self.running then return end
  self:invalidateLayout()
  if self:isEnabled() then
    self:refresh()
    self:schedulePlan(DEBOUNCE)
  end
end

function WordWise:onNetworkConnected()
  self.offline_prompted = false
  if self.running and self:isEnabled() then
    self.retry_at = 0
    self:schedulePlan(1)
  end
end

function WordWise:onSuspend()
  if not self.running then return end
  self:abortAll()
  self:flushCache()
end

function WordWise:onResume()
  if self.running and self:isEnabled() then self:schedulePlan(2) end
end

--- ReaderView calls this when the layout is reset (rotation, resize ...).
function WordWise:resetLayout()
  self:invalidateLayout()
end

---------------------------------------------------------------------------
-- Pages and text
---------------------------------------------------------------------------

--- Start/end xpointer of the page (or the 2-page spread) beginning at `page`.
--- The end is nil for the last page of the book.
function WordWise:pageRange(page)
  local doc = self.ui.document
  if self:isPaged() then
    local a, b = PDF.pageRange(page, doc:getPageCount())
    return a, b, 1
  end
  local vc = doc:getVisiblePageCount() or 1
  local total = doc:getPageCount()
  local a = doc:getPageXPointer(page)
  local nextp = page + vc
  local b
  if nextp <= total then b = doc:getPageXPointer(nextp) end
  return a, b, vc
end

--- Text boxes (lines of words) of a PDF page, straight from the text layer. Never
--- goes through OCR: a page without a text layer simply has no words.
function WordWise:pageBoxes(page)
  local doc = self.ui.document
  local ok, boxes = pcall(doc.getPageTextBoxes, doc, page)
  if ok and type(boxes) == "table" then return boxes end
end

--- Words and text of the PDF page whose start key is `a`.
function WordWise:pageWords(a)
  local page = PDF.parse(a)
  local boxes = page and self:pageBoxes(page)
  if not boxes then return {}, "" end
  return PDF.collect(boxes, page, MAX_WORDS_WALK)
end

--- Page on screen (the first one in continuous scroll mode).
function WordWise:currentPage()
  if self:isPaged() then return self.ui:getCurrentPage() end
  return self.ui.document:getCurrentPage()
end

--- Pages on screen, in order (several in continuous scroll mode).
function WordWise:visiblePages()
  local view = self.view or self.ui.view
  local pages = {}
  local list = view and view.getCurrentPageList and view:getCurrentPageList()
  for _, p in ipairs(list or {}) do pages[#pages + 1] = p end
  if #pages == 0 then pages[1] = self:currentPage() end
  table.sort(pages)
  return pages
end

--- Pages to look at: the ones on screen, then the next `prefetch` ones.
function WordWise:pagesToPlan(prefetch)
  local list = {}
  if self:isPaged() then
    local shown = self:visiblePages()
    for _, p in ipairs(shown) do list[#list + 1] = p end
    local last = shown[#shown]
    for k = 1, prefetch do list[#list + 1] = last + k end
  else
    local doc = self.ui.document
    local page = doc:getCurrentPage()
    local vc = doc:getVisiblePageCount() or 1
    for k = 0, prefetch do list[#list + 1] = page + k * vc end
  end
  return list
end

--- Walk the words in [a, b) and return them with their positions.
--- @return table[] { xp0, xp1, text }
function WordWise:walk(a, b)
  if self:isPaged() then
    local words = self:pageWords(a)
    return words
  end
  local doc = self.ui.document
  local words = {}
  local xp0 = a
  local xp1 = doc:getNextVisibleWordEnd(xp0)
  local guard = 0
  while xp1 and guard < MAX_WORDS_WALK do
    guard = guard + 1
    if b and doc:compareXPointers(xp0, b) ~= 1 then break end
    local text = doc:getTextFromXPointers(xp0, xp1)
    if text and Core.tokenize(text)[1] then
      words[#words + 1] = { xp0 = xp0, xp1 = xp1, text = text }
    end
    local nxt = doc:getNextVisibleWordStart(xp1)
    if not nxt then break end
    xp0 = nxt
    xp1 = doc:getNextVisibleWordEnd(xp0)
  end
  return words
end

--- Page text for the AI.
function WordWise:extractText(a, b)
  local doc = self.ui.document
  local ok, text = pcall(function()
    if self:isPaged() then
      local _words, page_text = self:pageWords(a)
      return page_text
    end
    if b then return doc:getTextFromXPointers(a, b) end
    local words = self:walk(a, nil)
    if #words == 0 then return nil end
    return doc:getTextFromXPointers(a, words[#words].xp1)
  end)
  if not ok or type(text) ~= "string" then return nil end
  text = text:gsub("[ \t\194\160]+", " "):gsub("%s*\n%s*", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if #text > MAX_TEXT_CHARS then text = text:sub(1, MAX_TEXT_CHARS) end
  return text
end

--- True while the user is selecting text. Extracting page text goes through
--- crengine's selection machinery, which must not clobber a live selection.
function WordWise:isUserBusy()
  local hl = self.ui.highlight
  return hl and (hl.hold_pos ~= nil or hl.selected_text ~= nil) or false
end

local function jobKey(a, b)
  return a .. "|" .. (b or "END")
end

---------------------------------------------------------------------------
-- Planning: which pages need a request
---------------------------------------------------------------------------

function WordWise:schedulePlan(delay)
  UIManager:unschedule(self.plan_fn)
  UIManager:scheduleIn(delay or DEBOUNCE, self.plan_fn)
end

function WordWise:isOnline()
  local ok, NetworkMgr = pcall(require, "ui/network/manager")
  if not ok then return true end
  if not Device:hasWifiToggle() then return true end
  return NetworkMgr:isWifiOn() and NetworkMgr:isConnected() or false
end

--- No connection: when the page being read still needs hints, offer to turn
--- Wi-Fi on, like the rest of the plugin does. Asked once per offline spell, so
--- turning pages never nags; pages that are already cached need nothing.
function WordWise:handleOffline()
  if self.offline_prompted or not self.store then return end
  local ok, covered = pcall(function()
    local a, b = self:pageRange(self:currentPage())
    return self.store:covers(a, b)
  end)
  if ok and covered then return end
  self.offline_prompted = true
  local okm, NetworkMgr = pcall(require, "ui/network/manager")
  if not okm then return end
  if NetworkMgr:isWifiOn() then
    -- Radio is on but not connected yet: connecting resumes by itself.
    Notification:notify(_("Word Wise: waiting for a network connection"))
    return
  end
  NetworkMgr:promptWifiOn(function()
    self.retry_at = 0
    self:schedulePlan(1)
  end)
end

function WordWise:plan()
  if not (self.running and self:isEnabled() and self.store) then return end
  if self:isUserBusy() then return self:schedulePlan(1.5) end
  if self:pagedBlocked() then
    if not self.reflow_notified then
      self.reflow_notified = true
      Notification:notify(_("Word Wise: hints are not available in PDF Reflow mode"))
    end
    return
  end

  local t = now()
  if t < self.retry_at then
    return self:schedulePlan(self.retry_at - t + 0.5)
  end
  if not self:isOnline() then
    self:handleOffline()
    return -- onNetworkConnected resumes
  end

  local doc = self.ui.document
  local ok, err = pcall(function()
    local total = doc:getPageCount()
    local wanted = {}
    local running = {}
    for _, j in ipairs(self.active) do running[j.key] = true end
    for k, p in ipairs(self:pagesToPlan(self:cfg("prefetch"))) do
      if p > total then break end
      local a, b = self:pageRange(p)
      if not self.store:covers(a, b) then
        local key = jobKey(a, b)
        if not running[key] then
          wanted[#wanted + 1] = { a = a, b = b, key = key, sig = self.sig, prio = k - 1 }
        end
      end
    end
    -- Replace the queue: pages the reader has left are no longer interesting.
    self.queue = wanted
  end)
  if not ok then
    logger.warn("Word Wise: plan failed:", err)
    return
  end
  self:pump()
end

--- Start queued jobs while slots are free.
function WordWise:pump()
  while #self.active < MAX_CONCURRENT and #self.queue > 0 do
    if self:isUserBusy() then return self:schedulePlan(1.5) end
    -- request budget
    local t = now()
    local fresh = {}
    for _, ts in ipairs(self.recent) do
      if t - ts < 60 then fresh[#fresh + 1] = ts end
    end
    self.recent = fresh
    if #self.recent >= MAX_PER_MINUTE then
      return self:schedulePlan(15)
    end

    local job = table.remove(self.queue, 1)
    local started = self:startJob(job)
    if started == "failed" then return end
  end
end

---------------------------------------------------------------------------
-- Provider
---------------------------------------------------------------------------

--- The provider table handed to handler:SyncOptions() inside the subprocess.
function WordWise:resolveProvider()
  local a = self.assistant
  local id = self:cfg("provider")
  if id and id ~= "" and a.config:isProviderEnabled(id) then
    local ps = a.config:getProvider(id)
    local handler_name = ps.handler or id:match("^([^_]+)")
    local ok, handler = pcall(require, "api_handlers." .. tostring(handler_name))
    if ok and handler then
      return {
        provider_name = id,
        provider_setting = koutil.tableDeepCopy(ps),
        handler_name = handler_name,
        handler = handler,
        settings = a.settings,
      }
    end
  end
  local q = a.querier
  if q and q.handler then return q end
  return nil, _("No provider set up yet.")
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------

--- Build the request and fork. Returns "ok", "skipped" or "failed".
function WordWise:startJob(job)
  local text = self:extractText(job.a, job.b)
  if not text then
    self:onFailure(_("could not read the page text"))
    return "failed"
  end
  local nwords = Core.countWords(text)
  if nwords < MIN_WORDS then
    -- Nothing worth hinting (title page, image, ...): remember that.
    self.store:addRange(job.a, job.b, {})
    self:markCacheDirty()
    return "skipped"
  end

  local provider, perr = self:resolveProvider()
  if not provider then
    self:onFailure(perr)
    return "failed"
  end

  local messages = Core.buildMessages(text, {
    level = self:cfg("level"),
    hint_lang = self:cfg("lang"),
    density = self:cfg("density"),
    style = self:cfg("style"),
    max_chars = self:cfg("max_chars"),
    max_hints = Core.maxHintsFor(nwords, self:cfg("density")),
    book = Core.bookLine(koutil.tableGetValue(self.ui.doc_props or {}, "display_title")
      or koutil.tableGetValue(self.ui.doc_props or {}, "title"),
      koutil.tableGetValue(self.ui.doc_props or {}, "authors")),
  })

  local pid, fd = ffiutil.runInSubProcess(function(_pid, write_fd)
    local ok, res, err = pcall(function()
      local h = provider.handler
      h:SyncOptions(provider)
      -- The child must never touch the UI: no trap widget, silent 429 waits.
      h.trap_widget = nil
      h.sleepWithRetryInfo = function(_, delay)
        ffiutil.sleep(math.min(tonumber(delay) or 3, 15))
        return true
      end
      if type(h.additional_parameters) == "table" then
        h.additional_parameters.max_retries = 2
      end
      return h:query(messages, { use_stream_mode = false, use_websearch = "none" })
    end)
    local payload
    if not ok then
      payload = "ER\n" .. tostring(res)
    elseif type(res) == "string" and res ~= "" then
      payload = "OK\n" .. res
    else
      payload = "ER\n" .. tostring(err or (type(res) == "table" and "unexpected tool call" or "empty response"))
    end
    ffiutil.writeToFD(write_fd, payload, true)
  end, true)

  if not pid then
    self:onFailure(T(_("could not start request (%1)"), tostring(fd)))
    return "failed"
  end

  job.pid, job.fd = pid, fd
  job.parts = {}
  job.rbuf = ffi.new("char[?]", READ_CHUNK)
  job.started = now()
  self.active[#self.active + 1] = job
  self.recent[#self.recent + 1] = job.started
  self:schedulePoll()
  return "ok"
end

function WordWise:schedulePoll()
  if self.poll_scheduled then return end
  self.poll_scheduled = true
  UIManager:scheduleIn(POLL_INTERVAL, self.poll_fn)
end

local function drain(job)
  local avail = ffiutil.getNonBlockingReadSize(job.fd)
  while avail and avail > 0 do
    local n = tonumber(ffi.C.read(job.fd, job.rbuf, math.min(avail, READ_CHUNK)))
    if not n or n <= 0 then break end
    job.parts[#job.parts + 1] = ffi.string(job.rbuf, n)
    avail = avail - n
  end
end

function WordWise:poll()
  local t = now()
  for i = #self.active, 1, -1 do
    local job = self.active[i]
    drain(job)
    local finished, timed_out = false, false
    if ffiutil.isSubProcessDone(job.pid) then
      drain(job) -- whatever the child wrote right before exiting
      finished = true
    elseif t - job.started > REQUEST_TIMEOUT then
      killProcess(job.pid)
      finished, timed_out = true, true
    end
    if finished then
      ffi.C.close(job.fd)
      table.remove(self.active, i)
      local data = table.concat(job.parts)
      job.parts, job.rbuf = nil, nil
      UIManager:nextTick(function()
        self:finishJob(job, data, timed_out)
      end)
    end
  end
  if #self.active > 0 then self:schedulePoll() end
end

--- Kill every running request and empty the queue.
function WordWise:abortAll()
  self.queue = {}
  for _, job in ipairs(self.active) do
    killProcess(job.pid)
    pcall(ffi.C.close, job.fd)
  end
  self.active = {}
  UIManager:unschedule(self.poll_fn)
  self.poll_scheduled = false
end

function WordWise:onFailure(msg)
  self.failures = self.failures + 1
  local delay = math.min(600, 15 * 2 ^ (self.failures - 1))
  self.retry_at = now() + delay
  logger.warn("Word Wise: request failed:", msg, "- retry in", delay, "s")
  if self.failures == 1 or self.failures % 5 == 0 then
    local short = tostring(msg):gsub("%s+", " ")
    if #short > 140 then short = short:sub(1, 140) .. "…" end
    Notification:notify(T(_("Word Wise: %1"), short), Notification.SOURCE_ALWAYS_SHOW)
  end
  self:schedulePlan(delay + 0.5)
end

function WordWise:finishJob(job, data, timed_out)
  if not (self.running and self:isEnabled() and self.store) then return end
  if job.sig ~= self.sig then return end -- settings changed meanwhile
  if timed_out then
    self:onFailure(_("the AI took too long to answer"))
    return
  end
  local tag, body = data:match("^(%u%u)\n(.*)$")
  if tag ~= "OK" then
    self:onFailure(body and body ~= "" and body or _("no answer from the AI"))
    return
  end

  local items = Core.parseResponse(body, rapidjson.decode)
  if #items == 0 and not body:find("%[%s*%]") then
    self:onFailure(_("the AI answer could not be understood"))
    return
  end

  local ok, err = pcall(function()
    local records = {}
    if #items > 0 then
      local words = self:walk(job.a, job.b)
      local cands, stats = Core.resolve(items, words, {
        all_occurrences = self:cfg("all"),
        max_hints = Core.maxHintsFor(#words, self:cfg("density")) + 3,
        level = self:cfg("level"),
        density = self:cfg("density"),
      })
      for _, c in ipairs(cands) do
        records[#records + 1] = {
          p0 = words[c.w0].xp0, p1 = words[c.w1].xp1, t = c.text, h = c.hint,
        }
      end
      -- Where did the AI's picks go? (visible in KOReader's debug log)
      logger.info(string.format(
        "Word Wise: %d picks -> %d hints (too easy %d, not found on page %d, duplicate %d, overlap %d, over cap %d, invalid %d)",
        stats.asked, #records, stats.too_easy, stats.unmatched, stats.duplicate,
        stats.overlap, stats.capped, stats.invalid))
    end
    self.store:addRange(job.a, job.b, records)
  end)
  if not ok then
    logger.warn("Word Wise: could not apply result:", err)
    self:onFailure(_("could not place the hints"))
    return
  end

  self.failures, self.retry_at = 0, 0
  if self.store:count() > MAX_HINTS_PER_BOOK then
    logger.warn("Word Wise: cache limit reached, starting over")
    self.store:clear()
  end
  self:markCacheDirty()

  if self.waiting_current then
    self:invalidateLayout()
    self:refresh()
  end
  -- a slot is free: continue with the queue
  self:pump()
end

---------------------------------------------------------------------------
-- Painting
---------------------------------------------------------------------------

function WordWise:invalidateLayout()
  self.layout_rev = self.layout_rev + 1
  self.layout_key = nil
end

function WordWise:freeLayout()
  for _, e in ipairs(self.layout) do
    if e.widget and e.widget.free then e.widget:free() end
  end
  self.layout = {}
  self.layout_key = nil
end

function WordWise:refresh()
  local view = self.view or (self.ui and self.ui.view)
  UIManager:setDirty(view and view.dialog or "all", "ui")
end

function WordWise:getFace()
  local doc = self.ui.document
  local book_px = doc:getFontSize() or Screen:scaleBySize(20)
  local target = math.max(Screen:scaleBySize(5), math.floor(book_px * self:cfg("size") / 100 + 0.5))
  -- Font:getFace() scales by DPI itself, so hand it the unscaled size.
  local scale = Screen:scaleBySize(1000) / 1000
  return Font:getFace("cfont", target / scale)
end

--- Left/right edge of the text column of the page, in screen pixels, so that hints
--- never stick out into the page margin. Uses the lines of the whole page; on the
--- last page (no end position) the page margins, else the hinted words' own extent.
function WordWise:textBounds(a, b, hint_boxes)
  local doc = self.ui.document
  local width = Screen:getWidth()
  local lo, hi
  local function take(x0, x1)
    if type(x0) ~= "number" or type(x1) ~= "number" then return end
    lo = lo and math.min(lo, x0) or x0
    hi = hi and math.max(hi, x1) or x1
  end
  if b then
    local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, a, b, true)
    if ok and type(boxes) == "table" then
      for _, bx in ipairs(boxes) do
        if bx.w and bx.w > 0 then take(bx.x, bx.x + bx.w) end
      end
    end
  end
  if not lo then
    local okm, m = pcall(function() return doc:getPageMargins() end)
    if okm and type(m) == "table" and tonumber(m.left) and tonumber(m.right)
        and m.left >= 0 and m.right >= 0 and m.left < width / 4 and m.right < width / 4 then
      take(m.left, width - m.right)
    end
  end
  if not lo then
    for _, bx in ipairs(hint_boxes) do take(bx.x, bx.x + bx.w) end
  end
  -- Never trust it blindly: stay on screen and keep a usable width.
  local min_x, max_x = Screen:scaleBySize(2), width - Screen:scaleBySize(2)
  if lo and hi and hi - lo > width / 3 then
    min_x = math.max(min_x, math.floor(lo))
    max_x = math.min(max_x, math.ceil(hi))
  end
  return min_x, max_x
end

--- Face for a hint whose text is `px` screen pixels high.
function WordWise:faceForPx(px)
  -- Font:getFace() scales by DPI itself, so hand it the unscaled size.
  local scale = Screen:scaleBySize(1000) / 1000
  return Font:getFace("cfont", px / scale)
end

--- Does the word at a stored position still match the hint (guards against stale positions)?
--- The word may be only the first half of a hyphenated word, hence the prefix test.
local function wordMatchesHint(word, hint_text)
  local w = Core.tokenize(word or "")[1]
  local t = Core.tokenize(hint_text or "")[1]
  if not w or not t then return false end
  return t:sub(1, #w) == w
end

--- Layout of the hints of the PDF page(s) on screen. Every hint goes into the gap
--- above its line; the text is made smaller until it fits, and the hint is left out
--- when it would have to be smaller than the "smallest hint size" setting.
function WordWise:buildPagedLayout(pages)
  self:freeLayout()
  local view = self.view
  local width = Screen:getWidth()
  local margin = Screen:scaleBySize(2)
  local color = self:cfg("color") == "black" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
  local max_chars = self:cfg("max_chars")
  local bold = self:cfg("bold") ~= false
  local position = self:cfg("position")
  local size_pct = tonumber(self:cfg("size")) or 65
  local min_font = Screen:scaleBySize(tonumber(self:cfg("pdf_min_size")) or 8)
  local squeeze = math.max(0, math.min(100, tonumber(self:cfg("pdf_squeeze")) or 35)) / 100
  local list, waiting = {}, false
  local min_x, max_x

  for _, page in ipairs(pages) do
    local a, b = self:pageRange(page)
    if not self.store:covers(a, b) then waiting = true end
    local hints = self.store:query(a, b)
    local boxes = #hints > 0 and self:pageBoxes(page) or nil
    if boxes then
      -- Text column of the page, so that hints never stick out into the margin.
      local ext = PDF.pageExtent(boxes)
      if ext then
        local er = view:pageToScreenTransform(page,
          Geom:new{ x = ext.x0, y = ext.y0, w = ext.x1 - ext.x0, h = ext.y1 - ext.y0 })
        if er then
          local lo, hi = math.floor(er.x), math.ceil(er.x + er.w)
          min_x = min_x and math.min(min_x, lo) or lo
          max_x = max_x and math.max(max_x, hi) or hi
        end
      end
      for _, h in ipairs(hints) do
        local loc = PDF.locate(boxes, h.p0, h.p1)
        if loc and wordMatchesHint(loc.word, h.t) then
          local line_h = loc.y1 - loc.y0
          local rect = view:pageToScreenTransform(page,
            Geom:new{ x = loc.x0, y = loc.y0, w = loc.x1 - loc.x0, h = line_h })
          if rect and rect.h > 0 and rect.w > 0 then
            local zoom = rect.h / line_h
            -- Room above the line, in screen pixels (at the top of a column: one line).
            -- The boxes of the text layer are font boxes: they touch or overlap although
            -- there is usually free space between the baseline of one line and the capitals
            -- of the next (only descenders reach down). So a hint may borrow part of the
            -- line above ("squeeze") and the empty top of its own line box.
            local gap = (PDF.gapAbove(boxes, loc.line, loc.x0, loc.x1) or line_h) * zoom
            local inner = rect.h * 0.05
            gap = gap + rect.h * squeeze + inner
            local text = Core.truncateHint(h.h, max_chars)
            local px = math.max(Screen:scaleBySize(5), math.floor(rect.h / 1.2 * size_pct / 100 + 0.5))
            local function build(p)
              return TextWidget:new{
                text = text,
                face = self:faceForPx(p),
                fgcolor = color,
                bold = bold,
                padding = 0,
                max_width = math.max(1, width - 2 * margin),
              }
            end
            local widget = build(px)
            local size = widget:getSize()
            local tries = 0
            while widget and size.h > gap - 1 and tries < 4 do
              tries = tries + 1
              local smaller = math.min(px - 1, math.floor(px * (gap - 1) / size.h))
              widget:free()
              widget = nil
              if smaller < min_font then break end
              px = smaller
              widget = build(px)
              size = widget:getSize()
            end
            if widget and size.h <= gap - 1 then
              list[#list + 1] = {
                cx = rect.x + rect.w / 2,
                top = rect.y, -- line key for collision handling
                bottom = PDF.hintBottom(rect.y, gap, size.h, position, inner),
                tw = size.w, th = size.h,
                widget = widget,
              }
            elseif widget then
              widget:free()
            end
          end
        end
      end
    end
  end
  self.waiting_current = waiting
  if #list == 0 then return end

  local lo = math.max(margin, min_x or 0)
  local hi = math.min(width - margin, max_x or width)
  if hi - lo < width / 3 then lo, hi = margin, width - margin end
  local placed = Core.placeHints(list, {
    min_x = lo,
    max_x = hi,
    gap = Screen:scaleBySize(3),
    offset = self:cfg("offset"),
  })
  local kept = {}
  for _, e in ipairs(placed) do kept[e] = true end
  for _, e in ipairs(list) do
    if not kept[e] then e.widget:free() end
  end
  self.layout = placed
end

--- Everything that changes where the words of a PDF page are on screen.
function WordWise:pagedLayoutKey(pages)
  local view = self.view
  local st = view.state or {}
  local parts = { "P", table.concat(pages, ","), tostring(st.zoom), tostring(st.rotation) }
  local va = view.visible_area
  if va then parts[#parts + 1] = table.concat({ va.x, va.y, va.w, va.h }, ",") end
  local off = st.offset
  if off then parts[#parts + 1] = off.x .. "," .. off.y end
  if view.page_scroll and view.page_states then
    for _, s in ipairs(view.page_states) do
      local v, o = s.visible_area, s.offset
      parts[#parts + 1] = table.concat({
        tostring(s.page), tostring(s.zoom), v and v.x or 0, v and v.y or 0, v and v.h or 0,
        o and o.x or 0, o and o.y or 0,
      }, ",")
    end
  end
  parts[#parts + 1] = self.layout_rev
  parts[#parts + 1] = self.sig
  return table.concat(parts, "|")
end

function WordWise:paintPaged(bb, x, y)
  local view = self.view
  local ok, err = pcall(function()
    local st = view.state or {}
    if self:pagedBlocked() or (st.rotation or 0) ~= 0 then
      -- Reflow mode / rotated pages: the text boxes do not match what is on screen.
      if #self.layout > 0 then self:freeLayout() end
      self.waiting_current = false
      return
    end
    local pages = self:visiblePages()
    local key = self:pagedLayoutKey(pages)
    if key ~= self.layout_key then
      self.layout_key = key -- set first: a failing build is not retried on every repaint
      self:buildPagedLayout(pages)
    end
    for _, e in ipairs(self.layout) do
      e.widget:paintTo(bb, x + e.x, y + e.y)
    end
  end)
  if not ok then
    logger.warn("Word Wise: PDF paint failed:", err)
  end
end

function WordWise:buildLayout(a, b)
  self:freeLayout()
  local doc = self.ui.document
  local hints = self.store:query(a, b)
  self.waiting_current = not self.store:covers(a, b)
  if #hints == 0 then return end

  -- Screen boxes of the hinted words first: they give the text column.
  local found = {}
  for _, h in ipairs(hints) do
    local boxes = doc:getScreenBoxesFromPositions(h.p0, h.p1, true)
    local box = boxes and boxes[1]
    if box and box.w > 0 and box.h > 0 then
      found[#found + 1] = { h = h, box = box }
    end
  end
  if #found == 0 then return end
  local min_x, max_x = self:textBounds(a, b, (function()
    local t = {}
    for _, f in ipairs(found) do t[#t + 1] = f.box end
    return t
  end)())

  local face = self:getFace()
  local color = self:cfg("color") == "black" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
  local max_chars = self:cfg("max_chars")
  local bold = self:cfg("bold") ~= false
  local position = self:cfg("position")
  local spacing = self:lineSpacing()
  local list = {}
  for _, f in ipairs(found) do
    local box = f.box
    local widget = TextWidget:new{
      text = Core.truncateHint(f.h.h, max_chars),
      face = face,
      fgcolor = color,
      bold = bold,
      padding = 0,
      max_width = math.max(1, max_x - min_x), -- a hint never wider than the text column
    }
    local size = widget:getSize()
    list[#list + 1] = {
      cx = box.x + box.w / 2,
      top = box.y, -- line key for collision handling
      bottom = Core.hintBottom(box.y, box.h, spacing, size.h, position),
      tw = size.w, th = size.h,
      widget = widget,
    }
  end

  local placed = Core.placeHints(list, {
    min_x = min_x,
    max_x = max_x,
    gap = Screen:scaleBySize(3),
    offset = self:cfg("offset"),
  })
  local kept = {}
  for _, e in ipairs(placed) do kept[e] = true end
  for _, e in ipairs(list) do
    if not kept[e] then e.widget:free() end
  end
  self.layout = placed
end

--- ReaderView view-module hook. Must never raise: an error here would blank
--- the page.
function WordWise:paintTo(bb, x, y)
  if not (self.running and self.store and self:isEnabled()) then return end
  local view = self.view
  if not view then return end
  if self:isPaged() then return self:paintPaged(bb, x, y) end
  if view.view_mode ~= "page" then return end
  local ok, err = pcall(function()
    local doc = self.ui.document
    local a, b = self:pageRange(doc:getCurrentPage())
    local key = table.concat({ a, b or "END", self.layout_rev, self.sig }, "|")
    if key ~= self.layout_key then
      self.layout_key = key -- set first: a failing build is not retried on every repaint
      self:buildLayout(a, b)
    end
    for _, e in ipairs(self.layout) do
      e.widget:paintTo(bb, x + e.x, y + e.y)
    end
  end)
  if not ok then
    logger.warn("Word Wise: paint failed:", err)
  end
end

return WordWise
