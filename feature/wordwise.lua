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
  * Offline dictionary (optional, setting "source"): instead of the AI, the hints
    of a page come from a local dictionary (utils/wordwise_dict) - no internet, no
    provider. The AI stays the default. "auto" uses the AI and falls back to the
    dictionary while there is no connection or the AI fails. Dictionary hints go
    through the same placement (Core.resolve), level and density as AI hints, but
    live in memory only: they cost milliseconds to make, and the per-book AI cache
    is never touched by them.
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
local Dict = require("utils/wordwise_dict")

local Screen = Device.screen

local DEFAULTS = {
  enabled = false,
  level = "B1",
  lang = "English",
  density = "medium",
  prefetch = 2,
  size = 65,         -- hint font size, % of the book font
  offset = 0,        -- extra vertical offset in px (positive = lower)
  max_chars = 32,    -- longest hint (a short explanation needs more room than a synonym)
  all = true,        -- hint every occurrence of an expression on the page (up to three)
  color = "gray",    -- "gray" | "black"
  bold = false,
  position = "close", -- "close" | "middle" | "high" (inside the extra line spacing)
  style = "definition", -- "synonym" | "definition" (short explanation)
  auto_spacing = true, -- raise the book's line spacing automatically to make room
  spacing = 150,       -- % line spacing used for that (the font itself is never changed)
  provider = "",     -- "" = same provider as the AI Assistant
  pdf_min_size = 8,  -- PDF: smallest hint font (px) before a hint is left out for lack of room
  pdf_squeeze = 35,  -- PDF: % of a line's height a hint may borrow from the line above (descender zone)
  repeat_hints = "always", -- "always" | "once": hide a hint (same word, same meaning) after its first showing in the book
  tap_hint = true,   -- tapping a hint opens the AI explanation of that word (on: such a tap does not turn the page)
  connector = "line", -- "off" | "line": rule under the hint with a notch pointing at the hinted word
  source = "auto",    -- "ai" | "auto" (AI, dictionary while offline) | "offline" (dictionary only)
  source_prev = "auto", -- last source that was not "offline" (kept for the menu)
  prepare_pages = 10, -- "Prepare Pages Ahead": how many pages after the current one
}

-- The hint sources, in the order of the menu.
local SOURCES = { "ai", "auto", "offline" }

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
local MENU_WAIT_MAX = 90         -- s: longest wait for an open settings menu before fetching anyway
local READ_CHUNK = 16384
local DICT_MAX_PREFETCH = 2     -- pages ahead for the offline dictionary (a page costs a little CPU)
local DICT_STEP_DELAY = 0.03    -- s between two pages of dictionary work, so the UI stays responsive
local PREPARE_MAX = 100          -- most pages one "Prepare Pages Ahead" may queue
local PREPARE_MAX_FAILURES = 3  -- consecutive AI errors after which preparing stops
local DICT_VERSION = "d1"       -- bump when the dictionary logic changes the hints it makes

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
  o.showing_dict = false      -- the page on screen shows dictionary hints although the AI is allowed
  o.dict = nil                -- open offline dictionary (utils/wordwise_dict)
  o.off_store = nil           -- dictionary hints (memory only, see "Offline dictionary" above)
  o.off_sig = nil
  o.off_queue = {}            -- pages waiting for dictionary hints
  o.empty_store = nil
  o.book_lang = nil
  o.off_fn = function() o:offlineStep() end
  o.prep = nil                -- "Prepare Pages Ahead" in progress: { ranges, total, started }
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
  local v = tonumber(self:cfg("spacing")) or DEFAULTS.spacing
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

--- Provider and model Word Wise requests hints with right now (the Word Wise
--- provider if one is chosen, else the one of the AI Assistant, including the
--- model picked in the model picker).
function WordWise:modelId()
  local a = self.assistant
  local id = self:cfg("provider")
  if id and id ~= "" and a.config and a.config:isProviderEnabled(id) then
    local ps = a.config:getProvider(id) or {}
    local m = a.settings:readSetting("selected_model_" .. id)
    if m == nil or m == "" then m = ps.model end
    return id .. ":" .. tostring(m or "")
  end
  local q = a.querier
  if q and q.provider_name then
    local ok, m = pcall(function() return q:getEffectiveModel() end)
    return q.provider_name .. ":" .. tostring(ok and m or "")
  end
  return "none"
end

--- Cache signature: hints made with other settings (or another AI model) are kept apart.
function WordWise:signature()
  return table.concat({
    self:cfg("level"), self:cfg("lang"), self:cfg("density"), self:cfg("style"),
    self:cfg("all") and "all" or "first", Core.PROMPT_VERSION, self:modelId(),
  }, "|")
end

---------------------------------------------------------------------------
-- Hint source: AI, offline dictionary, or both
---------------------------------------------------------------------------

--- "ai" | "auto" | "offline". Anything unknown counts as "ai", the default.
function WordWise:source()
  local s = self:cfg("source")
  if s == "auto" or s == "offline" then return s end
  return "ai"
end

--- Is there an AI provider that could answer? Quiet: unlike Assistant:isConfigured()
--- this never opens a dialog.
function WordWise:hasProvider()
  local ok, res = pcall(function() return self:resolveProvider() ~= nil end)
  return ok and res == true
end

--- May Word Wise be turned on with the chosen hint source? "ai" needs a provider
--- (the Assistant asks to set one up), the dictionary sources need the dictionary.
--- Works without a book (file manager), too.
function WordWise.canTurnOn(assistant)
  local src = assistant.settings:readSetting("wordwise_source")
  if src == nil then src = DEFAULTS.source end
  if src ~= "auto" and src ~= "offline" then src = "ai" end
  if src ~= "ai" then
    if Dict.available() then return true end
    if src == "auto" then return assistant:isConfigured() ~= nil end -- AI, as before
    UIManager:show(InfoMessage:new{
      text = _("No offline dictionary was found. Reinstall the plugin (it contains data/wordwise_offline.db) or put a dictionary of your own into the wordwise folder of KOReader's data directory."),
    })
    return false
  end
  return assistant:isConfigured() ~= nil
end

--- Gesture: switch the hint source one step: AI -> AI + Offline -> Offline -> AI.
--- Works without a book, too (the setting is global).
--- @return string|nil the new source; nil (and a reason) when there is no dictionary
function WordWise.toggleOffline(assistant)
  local settings = assistant.settings
  local cur = settings:readSetting("wordwise_source")
  if cur == nil then cur = DEFAULTS.source end
  if cur ~= "auto" and cur ~= "offline" then cur = "ai" end
  local nxt = (cur == "ai") and "auto" or ((cur == "auto") and "offline" or "ai")
  -- Both dictionary sources need the dictionary; the way back to "ai" never does.
  if nxt ~= "ai" and not Dict.available() then return nil, "no_dictionary" end
  -- Same bookkeeping as the menu: source_prev is the last source that was not "offline".
  if nxt == "offline" then
    settings:saveSetting("wordwise_source_prev", cur)
  else
    settings:saveSetting("wordwise_source_prev", nxt)
  end
  settings:saveSetting("wordwise_source", nxt)
  assistant.updated = true
  local ww = assistant.wordwise
  if ww then ww:onSourceChanged() end
  return nxt
end

--- Does the dictionary supply the hints right now? "offline": always. "auto": while
--- the AI cannot answer - no provider, no connection, or waiting after a failure.
function WordWise:dictionaryActive()
  local src = self:source()
  if src == "offline" then return true end
  if src ~= "auto" then return false end
  return not self:hasProvider() or not self:isOnline() or now() < self.retry_at
end

--- Language of the book: "en", "other", or "unknown" when the file does not say.
function WordWise:bookLanguage()
  local lang
  pcall(function()
    local props = self.ui.doc_props
    lang = props and props.language
    if (type(lang) ~= "string" or lang == "") and self.ui.document and self.ui.document.getProps then
      local p = self.ui.document:getProps()
      lang = p and p.language
    end
  end)
  if type(lang) ~= "string" then return "unknown" end
  lang = lang:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if lang == "" or lang == "und" or lang == "unknown" then return "unknown" end
  if lang == "en" or lang:match("^en[%-_]") or lang:match("^eng") then return "en" end
  return "other"
end

--- The open dictionary (opened on first use), or nil.
function WordWise:openDict()
  if self.dict then return self.dict end
  local ok, d = pcall(Dict.open)
  if ok and d then self.dict = d end
  return self.dict
end

function WordWise:closeDict()
  if self.dict then pcall(function() self.dict:close() end) end
  self.dict = nil
end

--- Forget the dictionary hints of this session (they are cheap to make again).
function WordWise:dropDictHints()
  self.off_store, self.off_sig, self.off_queue = nil, nil, {}
  UIManager:unschedule(self.off_fn)
end

--- The dictionary file changed (converted, replaced): start over with the new one.
function WordWise:reloadDictionary()
  self:closeDict()
  self:dropDictHints()
  self.dict_notified, self.lang_notified = nil, nil
  if self.running and self:isEnabled() then
    self:invalidateLayout()
    self:refresh()
    self:schedulePlan(0.2)
  end
end

--- Dictionary hints depend on these; the AI settings (model, style, language) do not.
function WordWise:dictSignature()
  local d = self:openDict()
  return table.concat({
    self:cfg("level"), self:cfg("density"), self:cfg("all") and "all" or "first",
    tostring(self:cfg("max_chars")), d and d.path or "none", DICT_VERSION,
  }, "|")
end

--- The store of dictionary hints, made anew when the settings behind it changed.
function WordWise:dictStore()
  local sig = self:dictSignature()
  if self.off_store and self.off_sig == sig then return self.off_store end
  self.off_store = Store.new(self:cmp())
  self.off_sig = sig
  self.off_queue = {}
  return self.off_store
end

-- What is painted when the source is "auto": the AI's hints on pages the AI has
-- analysed, the dictionary's on the others.
local Combined = {}
Combined.__index = Combined

function Combined.new(ai, dict)
  return setmetatable({ ai = ai, dict = dict }, Combined)
end

function Combined:covers(a, b)
  return self.ai:covers(a, b) or self.dict:covers(a, b)
end

function Combined:query(a, b)
  if self.ai:covers(a, b) then return self.ai:query(a, b) end
  return self.dict:query(a, b)
end

--- Are the hints of [a, b) the dictionary's although the AI is allowed (so they
--- have to be replaced when the AI's arrive)?
function Combined:usesDict(a, b)
  return not self.ai:covers(a, b) and self.dict:covers(a, b)
end

--- The hints to paint for the current source.
function WordWise:viewStore()
  local src = self:source()
  if src == "ai" then return self.store end
  local d = self.off_store
  if not d then
    self.empty_store = self.empty_store or Store.new(self:cmp())
    d = self.empty_store
  end
  if src == "offline" then return d end
  return Combined.new(self.store, d)
end

--- The hint source was changed (menu, gesture): apply it at once.
function WordWise:onSourceChanged()
  if not self.running then return end
  if self:source() == "offline" then
    self:cancelPrepare(_("Word Wise: preparing stopped (Offline needs no preparing)"))
  end
  self:abortAll()
  self.failures, self.retry_at = 0, 0
  self.offline_prompted = false
  self.lang_notified = nil
  self:invalidateLayout()
  if self:isEnabled() then
    self:refresh()
    self:schedulePlan(0.2)
  end
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
  self:unregisterHighlightButton()
  self.running = false
  self.prep = nil
  self.store = nil
  self.cache_ls = nil
  self.seen = nil
  self:dropDictHints()
  self:closeDict()
  self.empty_store = nil
  self.dict_notified, self.lang_notified = nil, nil
end

--- Load the cache and start planning requests.
function WordWise:activate()
  self:registerHighlightButton()
  self:registerTapZone()
  self:openCache()
  self:prepareBook()
  self:dropDictHints()
  self.failures, self.retry_at = 0, 0
  self.offline_prompted = false
  self:invalidateLayout()
  self:schedulePlan(0.1)
end

--- The "Word Wise is on" message of the first time hints are turned on in a kind of
--- document. With the AI as the source these are the original texts (and their
--- translations); with the dictionary they say what is different.
--- @param kind string "pdf" | "reflow"
function WordWise:tipText(kind)
  local src = self:source()
  if src == "ai" then
    if kind == "pdf" then
      return _([[Word Wise is on.

Hints are fetched from your AI provider while you read, so an internet connection is needed. Pages you have already seen are cached and cost nothing.

A PDF has a fixed layout, so hints can only go into the gap above a line, a little over the lower part of the line above. Where even that is too small for readable text, the hint is left out. You can tune this in Hint Appearance (PDF: Squeeze Hints Closer, PDF: Smallest Hint Size). Zooming in does not help, as the gaps grow with the text. Scanned PDFs without a text layer are not supported, and neither is Reflow mode.]])
    end
    return _([[Word Wise is on.

Hints are fetched from your AI provider while you read, so an internet connection is needed. Pages you have already seen are cached and cost nothing.

Hints sit in the gap above each word, so the line spacing of the book was raised a little to leave room for them. You can change it any time in the Typeset menu.

Tip: a fast model without "thinking" gives the quickest hints.]])
  end
  local intro
  if src == "offline" then
    intro = _([[Word Wise is on.

Hints come from the offline dictionary of the plugin, so no internet connection and no AI provider are needed. The dictionary knows rare English words only and cannot tell from the sentence which meaning is meant, so it is less precise than the AI. It is for English books; hints are always English.]])
  else
    intro = _([[Word Wise is on.

Hints are fetched from your AI provider while you read. Without a connection, or while the AI fails, the offline dictionary of the plugin gives simpler hints for English books until the AI is back. Pages the AI has already done are cached and cost nothing.]])
  end
  if kind == "pdf" then
    return intro .. "\n\n" .. _([[A PDF has a fixed layout, so hints can only go into the gap above a line, and where it is too small for readable text the hint is left out. You can tune this in Hint Appearance. Scanned PDFs without a text layer are not supported, and neither is Reflow mode.]])
  end
  return intro .. "\n\n" .. _([[Hints sit in the gap above each word, so the line spacing of the book was raised a little to leave room for them. You can change it any time in the Typeset menu.]])
end

function WordWise:setEnabled(on)
  if not self:isSupported() then return false end
  if on then
    if not WordWise.canTurnOn(self.assistant) then return false end
    self:setCfg("enabled", true)
    self:activate()
    if self:isPaged() and not self.settings:readSetting("wordwise_pdf_tip_shown") then
      self.settings:saveSetting("wordwise_pdf_tip_shown", true)
      UIManager:show(InfoMessage:new{ text = self:tipText("pdf") })
    elseif self:isReflowable() and not self.settings:readSetting("wordwise_tip_shown") then
      self.settings:saveSetting("wordwise_tip_shown", true)
      UIManager:show(InfoMessage:new{ text = self:tipText("reflow") })
    end
  else
    self:setCfg("enabled", false)
    self.prep = nil
    self:unregisterHighlightButton()
    self:abortAll()
    self:flushCache()
    self:freeLayout()
    self:dropDictHints()
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
  if type(self.seen) ~= "table" then
    local seen = self.cache_ls:readSetting("seen")
    self.seen = type(seen) == "table" and seen or {}
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
  -- Only the variant in use is kept: hints made with other settings or by another
  -- model are dropped as soon as the current variant is written. When only the
  -- list of shown hints changed (dictionary hints, "show once"), the AI hints on
  -- disk are left exactly as they are.
  if self.store_dirty then
    local data = self.store:dump()
    data.used = now()
    self.cache_ls:saveSetting("stores", { [self.sig] = data })
  end
  if type(self.seen) == "table" then self.cache_ls:saveSetting("seen", self.seen) end
  local ok, err = pcall(function() self.cache_ls:flush() end)
  if ok then
    self.cache_dirty = false
    self.store_dirty = false
  else
    logger.warn("Word Wise: cache write failed:", err)
  end
end

--- @param seen_only boolean|nil true when only the "shown once" list changed, not the AI hints
function WordWise:markCacheDirty(seen_only)
  self.cache_dirty = true
  if not seen_only then self.store_dirty = true end
  UIManager:unschedule(self.flush_fn)
  UIManager:scheduleIn(FLUSH_DELAY, self.flush_fn)
end

--- Forget all hints of this book (all settings variants).
function WordWise:clearCache()
  self.prep = nil
  self:abortAll()
  self:dropDictHints()
  self.seen = {}
  if self.store then self.store:clear() end
  if self.cache_ls then
    self.cache_ls:saveSetting("stores", {})
    self.cache_ls:saveSetting("seen", {})
    pcall(function() self.cache_ls:flush() end)
  end
  self.cache_dirty = false
  self.store_dirty = false
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
function WordWise:onRequestSettingsChanged(delay)
  if not self:isEnabled() then return end
  -- the hints being prepared would be made with the old settings
  self:cancelPrepare(_("Word Wise: preparing stopped because the settings changed"))
  self:abortAll()
  self:dropDictHints()
  self:flushCache()
  self:openCache()
  -- Fresh start: errors and the waiting time after them belong to the old settings.
  self.failures, self.retry_at = 0, 0
  self.offline_prompted = false
  self:invalidateLayout()
  self:refresh()
  self:schedulePlan(delay or 0.3)
end

--- Call after the AI provider or model changed (Word Wise provider, AI Assistant
--- provider, model picker). Hints of the new model are fetched; the old model's
--- hints are removed from the cache once the first new ones are saved.
function WordWise:onModelChanged()
  if not self.running then return end
  -- Nothing to do when Word Wise uses its own provider and that did not change.
  if self.sig and self:signature() == self.sig then return end
  -- A short pause: the thinking depth is often changed right after the model.
  self:onRequestSettingsChanged(3)
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
--- Keep fetching on hold while `widget` (a dialog opened from the settings menu,
--- for example Reasoning Option) is still on screen.
function WordWise:holdWhileShown(widget)
  self.hold_widget = widget
end

--- True while the reader's settings menu or a dialog opened from it is open:
--- changes made there (provider, model, thinking depth, level ...) are applied
--- together once it is closed. Defensive on purpose: if the menu cannot be
--- inspected this is simply false.
function WordWise:settingsOpen()
  local ok, shown = pcall(function()
    local held = self.hold_widget
    if held then
      if UIManager:isWidgetShown(held) then return true end
      self.hold_widget = nil
    end
    local menu = self.ui and self.ui.menu
    local container = menu and menu.menu_container
    return container ~= nil and UIManager:isWidgetShown(container) == true
  end)
  return ok and shown or false
end

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
  -- The model may have changed in a way nobody told us about (edited provider, ...).
  if self:signature() ~= self.sig then return self:onRequestSettingsChanged() end
  -- Wait while the settings menu is open (it may take several changes), but not forever.
  if self:settingsOpen() then
    self.menu_wait_since = self.menu_wait_since or now()
    if now() - self.menu_wait_since < MENU_WAIT_MAX then return self:schedulePlan(1.5) end
  end
  self.menu_wait_since = nil
  if self:isUserBusy() then return self:schedulePlan(1.5) end
  if self:pagedBlocked() then
    if not self.reflow_notified then
      self.reflow_notified = true
      Notification:notify(_("Word Wise: hints are not available in PDF Reflow mode"))
    end
    return
  end

  local src = self:source()
  if src == "offline" then return self:planDictionary() end

  local t = now()
  if src == "auto" then
    -- The AI first. The dictionary takes over while the AI cannot answer; the AI
    -- comes back by itself (after the waiting time, or on onNetworkConnected).
    local online = self:isOnline()
    local waiting = t < self.retry_at
    local provider = self:hasProvider()
    if waiting or not online or not provider then
      if not online and #self.active > 0 then self:abortAll() end
      self:planDictionary()
      if provider and waiting then self:schedulePlan(self.retry_at - t + 0.5) end
      return
    end
  else
    if t < self.retry_at then
      return self:schedulePlan(self.retry_at - t + 0.5)
    end
    if not self:isOnline() then
      self:handleOffline()
      return -- onNetworkConnected resumes
    end
  end

  local doc = self.ui.document
  local ok, err = pcall(function()
    local total = doc:getPageCount()
    local wanted = {}
    local running = {}
    local queued = {}
    for _, j in ipairs(self.active) do running[j.key] = true end
    for k, p in ipairs(self:pagesToPlan(self:cfg("prefetch"))) do
      if p > total then break end
      local a, b = self:pageRange(p)
      if not self.store:covers(a, b) then
        local key = jobKey(a, b)
        if not running[key] then
          wanted[#wanted + 1] = { a = a, b = b, key = key, sig = self.sig, prio = k - 1 }
          queued[key] = true
        end
      end
    end
    -- "Prepare Pages Ahead": after the pages being read, never before them.
    self:checkPrepare()
    if self.prep then
      for i, r in ipairs(self.prep.ranges) do
        if not self.store:covers(r.a, r.b) then
          local key = jobKey(r.a, r.b)
          if not running[key] and not queued[key] then
            wanted[#wanted + 1] = { a = r.a, b = r.b, key = key, sig = self.sig, prio = 100 + i }
            queued[key] = true
          end
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
-- Offline dictionary: hints of a page without AI
---------------------------------------------------------------------------

--- Can dictionary hints be made for this book? Says why not, once per book.
function WordWise:dictionaryReady()
  if not self:openDict() then
    if not self.dict_notified then
      self.dict_notified = true
      Notification:notify(_("Word Wise: no offline dictionary found"), Notification.SOURCE_ALWAYS_SHOW)
    end
    return false
  end
  self.book_lang = self:bookLanguage()
  if self.book_lang == "other" then
    if not self.lang_notified then
      self.lang_notified = true
      Notification:notify(_("Word Wise: the offline dictionary is English only"), Notification.SOURCE_ALWAYS_SHOW)
    end
    return false
  end
  return true
end

--- Queue the pages on screen and the next few for dictionary hints. Cheap: only
--- pages that have no hints yet (from the AI cache, in "auto") are queued.
function WordWise:planDictionary()
  if not self:dictionaryReady() then return end
  local auto = self:source() == "auto"
  local ok, err = pcall(function()
    local total = self.ui.document:getPageCount()
    local store = self:dictStore()
    local wanted = {}
    local prefetch = math.min(tonumber(self:cfg("prefetch")) or 2, DICT_MAX_PREFETCH)
    for _k, p in ipairs(self:pagesToPlan(prefetch)) do
      if p > total then break end
      local a, b = self:pageRange(p)
      local covered = store:covers(a, b) or (auto and self.store:covers(a, b))
      if not covered then wanted[#wanted + 1] = { a = a, b = b } end
    end
    -- Replace the queue: pages the reader has left are no longer interesting.
    self.off_queue = wanted
  end)
  if not ok then
    logger.warn("Word Wise: dictionary plan failed:", err)
    return
  end
  if #self.off_queue > 0 then self:scheduleDictStep(0) end
end

function WordWise:scheduleDictStep(delay)
  UIManager:unschedule(self.off_fn)
  UIManager:scheduleIn(delay or DICT_STEP_DELAY, self.off_fn)
end

--- One page of dictionary work per call, so reading is never blocked for long.
function WordWise:offlineStep()
  if not (self.running and self:isEnabled() and self.store) then return end
  if self:isUserBusy() then return self:scheduleDictStep(1.5) end
  local job = table.remove(self.off_queue, 1)
  if not job then return end
  local ok, err = pcall(function() self:runDictJob(job) end)
  if not ok then
    -- Mark the page as done without hints: one broken page must not stall the rest.
    logger.warn("Word Wise: dictionary hints failed:", err)
    pcall(function() self:dictStore():addRange(job.a, job.b, {}) end)
  end
  if self.waiting_current or self.showing_dict then
    self:invalidateLayout()
    self:refresh()
  end
  if #self.off_queue > 0 then self:scheduleDictStep(DICT_STEP_DELAY) end
end

--- Dictionary hints of the page [a, b): the hard words of the page, resolved and
--- placed exactly like the AI's picks (level, density, occurrences, cap).
function WordWise:runDictJob(job)
  local store = self:dictStore()
  local words = self:walk(job.a, job.b)
  local records = {}
  if #words >= MIN_WORDS and (self.book_lang == "en" or Dict.looksEnglish(words)) then
    local dict = self:openDict()
    local items = dict and dict:items(words, { max_chars = tonumber(self:cfg("max_chars")) or 24 }) or {}
    if #items > 0 then
      local cands = Core.resolve(items, words, {
        all_occurrences = self:cfg("all"),
        max_hints = Core.maxHintsFor(#words, self:cfg("density"), self:cfg("level")) + 3,
        level = self:cfg("level"),
        density = self:cfg("density"),
      })
      for _i, c in ipairs(cands) do
        records[#records + 1] = {
          p0 = words[c.w0].xp0, p1 = words[c.w1].xp1, t = c.text, h = c.hint,
        }
      end
    end
  end
  store:addRange(job.a, job.b, records)
end

---------------------------------------------------------------------------
-- Prepare pages ahead (AI hints for the next N pages, e.g. before going offline)
---------------------------------------------------------------------------
-- Runs through the normal request queue, so every safeguard of normal reading
-- applies: two requests at a time, at most MAX_PER_MINUTE per minute, waiting
-- after errors, a request is never sent while you select text. The page being
-- read and its normal pre-fetch always go first. The result is the ordinary
-- per-book cache, so it is shown whenever those pages are read (also offline).

--- Why preparing cannot start: reason code -> text.
function WordWise.prepareReasonText(why)
  local texts = {
    off = _("Turn on Word Wise first."),
    blocked = _("Hints are not available in PDF Reflow mode."),
    offline_source = _("Switch the hint source to AI or AI + Offline first. Offline needs no preparing."),
    no_provider = _("No AI provider set up yet."),
    no_internet = _("An internet connection is needed to prepare pages."),
    end_of_book = _("There are no pages left after this one."),
  }
  return texts[why] or texts.off
end

--- The next `n` pages after the one on screen, as { a, b } text ranges. Ranges (not
--- page numbers) stay valid when the font or margins change.
function WordWise:aheadRanges(n)
  local doc = self.ui.document
  local total = doc:getPageCount()
  local first, step
  if self:isPaged() then
    local shown = self:visiblePages()
    first, step = shown[#shown] + 1, 1
  else
    step = doc:getVisiblePageCount() or 1
    first = doc:getCurrentPage() + step
  end
  local out = {}
  for k = 0, n - 1 do
    local p = first + k * step
    if p > total then break end
    local a, b = self:pageRange(p)
    out[#out + 1] = { a = a, b = b }
  end
  return out
end

--- Start preparing the next pages.
--- @param n number|nil how many (default: the "Prepare Pages Ahead" setting)
--- @return number|nil pages queued; nil and a reason code when it cannot start
function WordWise:startPrepare(n)
  n = math.floor(tonumber(n) or tonumber(self:cfg("prepare_pages")) or DEFAULTS.prepare_pages)
  n = math.max(1, math.min(PREPARE_MAX, n))
  if not (self.running and self:isEnabled()) then return nil, "off" end
  if self:pagedBlocked() then return nil, "blocked" end
  if self:source() == "offline" then return nil, "offline_source" end
  if not self:hasProvider() then return nil, "no_provider" end
  if not self:isOnline() then return nil, "no_internet" end
  local ok, ranges = pcall(self.aheadRanges, self, n)
  if not ok or type(ranges) ~= "table" or #ranges == 0 then return nil, "end_of_book" end
  self.prep = { ranges = ranges, total = #ranges, started = now() }
  self.failures, self.retry_at = 0, 0
  self:schedulePlan(0.2)
  return #ranges
end

--- Pages done and pages in all, or nil when nothing is being prepared.
function WordWise:prepareStatus()
  local p = self.prep
  if not (p and self.store) then return nil end
  local done = 0
  for _i, r in ipairs(p.ranges) do
    if self.store:covers(r.a, r.b) then done = done + 1 end
  end
  return done, p.total
end

--- Called after every answer: tell when everything is ready.
function WordWise:checkPrepare()
  if not self.prep then return end
  local ok, done, total = pcall(self.prepareStatus, self)
  if ok and done and done >= total then
    self.prep = nil
    Notification:notify(T(_("Word Wise: the next %1 pages are ready"), total), Notification.SOURCE_ALWAYS_SHOW)
  end
end

--- Stop preparing (what is done stays in the cache).
--- @param msg string|nil shown to the reader
function WordWise:cancelPrepare(msg)
  if not self.prep then return end
  local ok, done, total = pcall(self.prepareStatus, self)
  self.prep = nil
  if msg then
    -- say how far it got: "... (12 of 30 pages ready)"
    if ok and done then msg = msg .. " " .. T(_("(%1 of %2 pages ready)"), done, total) end
    Notification:notify(msg, Notification.SOURCE_ALWAYS_SHOW)
  end
end

--- Gesture: start preparing, or stop when it is running.
function WordWise:togglePrepare()
  if self.prep then
    self:cancelPrepare(_("Word Wise: preparing stopped"))
    return
  end
  local n, why = self:startPrepare()
  if n then
    Notification:notify(T(_("Word Wise: preparing the next %1 pages"), n), Notification.SOURCE_ALWAYS_SHOW)
  else
    Notification:notify(T(_("Word Wise: %1"), WordWise.prepareReasonText(why)), Notification.SOURCE_ALWAYS_SHOW)
  end
end

--- Reason why preparing cannot work at all with the current settings, or nil.
--- A missing connection is not one: that is asked for when it is needed.
function WordWise:prepareBlocker()
  if not (self.running and self:isEnabled()) then return "off" end
  if self:pagedBlocked() then return "blocked" end
  if self:source() == "offline" then return "offline_source" end
  if not self:hasProvider() then return "no_provider" end
  return nil
end

--- Ask how many pages to prepare, then prepare them. Used by the gesture and the menu.
--- Needs the AI (source "AI" or "AI + Offline"); without a connection it offers to turn
--- Wi-Fi on first, like everything else in the plugin that needs the internet.
--- @param opts table|nil { close_callback = fn, on_started = fn(n), on_failed = fn(why) }
function WordWise:askPrepare(opts)
  opts = opts or {}
  local function failed(why)
    if opts.on_failed then return opts.on_failed(why) end
    Notification:notify(T(_("Word Wise: %1"), WordWise.prepareReasonText(why)), Notification.SOURCE_ALWAYS_SHOW)
  end
  local function started(n)
    if opts.on_started then return opts.on_started(n) end
    Notification:notify(T(_("Word Wise: preparing the next %1 pages"), n), Notification.SOURCE_ALWAYS_SHOW)
  end
  local blocker = self:prepareBlocker()
  if blocker then
    failed(blocker)
    if opts.close_callback then opts.close_callback() end
    return
  end
  local SpinWidget = require("ui/widget/spinwidget")
  UIManager:show(SpinWidget:new {
    title_text = _("Pages to prepare after this one"),
    info_text = _("One AI request per page. Useful before reading without internet."),
    value = tonumber(self:cfg("prepare_pages")) or DEFAULTS.prepare_pages,
    value_min = 5,
    value_max = PREPARE_MAX,
    value_step = 5,
    default_value = DEFAULTS.prepare_pages,
    ok_text = _("Prepare"),
    ok_always_enabled = true, -- start with the shown value, no need to change it first
    callback = function(spin)
      local n = spin.value
      self:setCfg("prepare_pages", n)
      local function go()
        -- Everything is checked again: time has passed since the question.
        local queued, why = self:startPrepare(n)
        if queued then started(queued) else failed(why) end
      end
      if self:isOnline() then return go() end
      -- No connection: offer Wi-Fi, continue once it is up (nothing happens if declined).
      local ok = pcall(function()
        require("utils/net").runWhenOnlineFast(go)
      end)
      if not ok then failed("no_internet") end
    end,
    close_callback = opts.close_callback,
  })
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
    max_hints = Core.maxHintsFor(nwords, self:cfg("density"), self:cfg("level")),
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
  self.off_queue = {}
  UIManager:unschedule(self.off_fn)
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
  if self.prep and self.failures >= PREPARE_MAX_FAILURES then
    self:cancelPrepare(_("Word Wise: preparing stopped after repeated AI errors"))
  end
  if self.failures == 1 or self.failures % 5 == 0 then
    local short = tostring(msg):gsub("%s+", " ")
    if #short > 140 then short = short:sub(1, 140) .. "…" end
    Notification:notify(T(_("Word Wise: %1"), short), Notification.SOURCE_ALWAYS_SHOW)
  end
  if self:source() == "auto" then
    -- The dictionary steps in at once; plan() brings the AI back after the waiting time.
    self:schedulePlan(0.3)
  else
    self:schedulePlan(delay + 0.5)
  end
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
    local text = Core.answerText(body)
    -- Show in the log what the model actually sent, so the cause can be found.
    logger.warn(string.format("Word Wise: unreadable AI answer (%d chars, %d after cleanup): %s",
      #body, #text, text ~= "" and text:sub(1, 300) or body:gsub("%s+", " "):sub(1, 300)))
    if text == "" then
      self:onFailure(_("the model spent its whole answer on thinking: set Reasoning to Low or use another model"))
    else
      self:onFailure(_("the AI answer could not be understood"))
    end
    return
  end

  local ok, err = pcall(function()
    local records = {}
    if #items > 0 then
      local words = self:walk(job.a, job.b)
      local cands, stats = Core.resolve(items, words, {
        all_occurrences = self:cfg("all"),
        max_hints = Core.maxHintsFor(#words, self:cfg("density"), self:cfg("level")) + 3,
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
      local function names(list) return #list > 0 and table.concat(list, ", ", 1, math.min(#list, 12)) or nil end
      for what, label in pairs({ unmatched = "not found", capped = "over cap", easy = "too easy" }) do
        local n = names(stats.lost[what])
        if n then logger.info("Word Wise: " .. label .. ": " .. n) end
      end
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
  self:checkPrepare()

  if self.waiting_current or self.showing_dict then
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

---------------------------------------------------------------------------
-- Known words, repeated hints, tapping a hint
---------------------------------------------------------------------------

--- Words/expressions compare by their lower-case tokens ("Solemn." == "solemn").
local function normKey(text)
  if type(text) ~= "string" then return "" end
  return table.concat(Core.tokenize(text), " ")
end

function WordWise:knownWords()
  local known = self.settings:readSetting("wordwise_known")
  return type(known) == "table" and known or {}
end

--- Is this word/expression on the known list?
function WordWise:isKnown(text)
  local ok, res = pcall(function()
    local key = normKey(text)
    return key ~= "" and self:knownWords()[key] == true
  end)
  return ok and res == true
end

--- Visible confirmation: an InfoMessage (like the Vocabulary Builder button), because a
--- Notification toast is easily missed and may be hidden behind the result window.
local function confirmMessage(msg)
  UIManager:show(InfoMessage:new{ text = msg, timeout = 2 })
end

--- "I know this word": it is never hinted again (in any book) until the list is cleared.
function WordWise:markKnown(text)
  local key = normKey(text)
  if key == "" then return end
  local known = self:knownWords()
  known[key] = true
  self.settings:saveSetting("wordwise_known", known)
  self.assistant.updated = true
  self:invalidateLayout()
  self:refresh()
  confirmMessage(T(_("Word Wise: \"%1\" will not be hinted any more"), key))
end

--- Undo of markKnown: the word is hinted again.
function WordWise:unmarkKnown(text)
  local key = normKey(text)
  if key == "" then return end
  local known = self:knownWords()
  if known[key] == nil then return end
  known[key] = nil
  self.settings:saveSetting("wordwise_known", known)
  self.assistant.updated = true
  self:invalidateLayout()
  self:refresh()
  confirmMessage(T(_("Word Wise: \"%1\" will be hinted again"), key))
end

--- Toggle; returns true when the word is known afterwards.
function WordWise:toggleKnown(text)
  if self:isKnown(text) then
    self:unmarkKnown(text)
    return false
  end
  self:markKnown(text)
  return true
end

--- May the "known" button be offered for this text (Word Wise on, 1 to 4 words)?
function WordWise:canMarkKnown(text)
  local ok, res = pcall(function()
    local n = #Core.tokenize(type(text) == "string" and text or "")
    return self.running and self:isEnabled() and n >= 1 and n <= 4
  end)
  return ok and res == true
end

--- Drop hints of known words and, when asked, hints already shown once in the book.
--- A repeat is a hint with the same word and the same meaning at another place.
--- Never raises: on any error the hints are returned unchanged.
function WordWise:filterHints(hints)
  local ok, res = pcall(function()
    local known = self:knownWords()
    local once = self:cfg("repeat_hints") == "once" and type(self.seen) == "table"
    if not once and next(known) == nil then return hints end
    local out, changed = {}, false
    for _i, h in ipairs(hints) do
      local nk = normKey(h.t)
      local drop = known[nk] == true
      if not drop and once then
        local hk = nk .. "|" .. normKey(h.h)
        local first = self.seen[hk]
        if first == nil then
          self.seen[hk] = h.p0 -- stable position of this occurrence, survives re-layout
          changed = true
        elseif first ~= h.p0 then
          drop = true
        end
      end
      if not drop then out[#out + 1] = h end
    end
    if changed then self:markCacheDirty(true) end
    return out
  end)
  if ok and type(res) == "table" then return res end
  return hints
end

--- Button "Word Wise: known" in the popup that appears after selecting text.
--- An extra button only: the AI Assistant buttons and long press are untouched.
function WordWise:registerHighlightButton()
  pcall(function()
    local hl = self.ui and self.ui.highlight
    if not (hl and hl.addToHighlightDialog) then return end
    if hl.removeFromHighlightDialog then hl:removeFromHighlightDialog("wordwise_known") end
    hl:addToHighlightDialog("wordwise_known", function(this)
      local text = this and this.selected_text and this.selected_text.text or ""
      local n = #Core.tokenize(type(text) == "string" and text or "")
      return {
        text = self:isKnown(text) and _("Word Wise: unknown") or _("Word Wise: known"),
        enabled = (self.running and self:isEnabled() and n >= 1 and n <= 4) and true or false,
        callback = function()
          self:toggleKnown(text)
          pcall(function() this:onClose() end)
        end,
      }
    end)
  end)
end

function WordWise:unregisterHighlightButton()
  pcall(function()
    local hl = self.ui and self.ui.highlight
    if hl and hl.removeFromHighlightDialog then hl:removeFromHighlightDialog("wordwise_known") end
  end)
end

--- One full-screen tap zone that only reacts (returns true) when a hint is hit;
--- every other tap goes on to page turning, links and the rest as before.
function WordWise:registerTapZone()
  if self.zone_registered or not (self.ui and self.ui.registerTouchZones) then return end
  local function zone(with_overrides)
    return {
      id = "wordwise_hint_tap",
      ges = "tap",
      screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
      overrides = with_overrides and { "readerhighlight_tap", "tap_forward", "tap_backward" } or nil,
      handler = function(ges) return self:onHintTap(ges) end,
    }
  end
  local ok = pcall(function() self.ui:registerTouchZones({ zone(true) }) end)
  if not ok then
    ok = pcall(function() self.ui:registerTouchZones({ zone(false) }) end)
  end
  if ok then self.zone_registered = true else logger.warn("Word Wise: tap zone not registered") end
end

function WordWise:onHintTap(ges)
  local ok, res = pcall(function()
    if not (self.running and self.store and self:isEnabled() and self:cfg("tap_hint") == true) then
      return false
    end
    local pos = ges and ges.pos
    if not pos then return false end
    local ox, oy = self.paint_x or 0, self.paint_y or 0
    local pad = Screen:scaleBySize(2)
    for _i, e in ipairs(self.layout) do
      if e.t and e.x and e.y then
        local x0, y0 = ox + e.x - pad, oy + e.y - pad
        if pos.x >= x0 and pos.x <= x0 + e.tw + 2 * pad and pos.y >= y0 and pos.y <= y0 + e.th + 2 * pad then
          self:showExplanation(e.t)
          return true
        end
      end
    end
    return false
  end)
  return ok and res == true
end

--- The definition of the offline dictionary, in a small popup. Used instead of the
--- AI explanation while the dictionary is the source (no connection needed).
function WordWise:showOfflineExplanation(text)
  local ok, err = pcall(function()
    local dict = self:openDict()
    local tok = Core.tokenize(text or "")[1]
    local r = dict and tok and dict:lookup(tok)
    local msg
    if r then
      msg = tok .. (r.pos and (" (" .. r.pos .. ")") or "") .. "\n\n" .. r.gloss
    else
      msg = T(_("No definition of \"%1\" in the offline dictionary."), tostring(text))
    end
    UIManager:show(InfoMessage:new{ text = msg })
  end)
  if not ok then logger.warn("Word Wise: could not open the definition:", err) end
end

--- The AI dictionary of the assistant, the same one as after selecting a word
--- (the offline dictionary's definition while that is the source).
function WordWise:showExplanation(text)
  if self:dictionaryActive() then return self:showOfflineExplanation(text) end
  local a = self.assistant
  if not (a and a:isConfigured()) then return end
  local ok, err = pcall(function()
    local NetUtils = require("utils/net")
    local Trapper = require("ui/trapper")
    NetUtils.runWhenOnlineFast(function()
      Trapper:wrap(function()
        local showDictionaryDialog = require("dialogs/dict")
        showDictionaryDialog(a, text)
      end)
    end)
  end)
  if not ok then logger.warn("Word Wise: could not open the explanation:", err) end
end

--- Vertical offset (px) of the hints. With the marker on, a downward shift is ignored:
--- the marker may not sink onto the word, so the hint would run into its own rule.
function WordWise:hintOffset()
  local o = tonumber(self:cfg("offset")) or 0
  if o > 0 and self:cfg("connector") == "line" then o = 0 end
  return o
end

--- Depth (px) of the little caret that points from a hint down to its word.
local function caretDepth(th)
  return math.max(3, math.floor(th * 0.3 + 0.5))
end

--- Room (px) a hint must leave between its text and the top of the word when the
--- connector is on: the rule under the hint plus the caret.
local function connectorReserve(th)
  return caretDepth(th) + 2
end

--- Paint one hint and, when enabled, a Kindle-style marker under it: a thin rule
--- as wide as the hint with a small V-shaped notch that points down at the word.
--- The notch sits above the centre of the hinted word, so a hint that had to move
--- sideways (because of its neighbours) still shows which word it belongs to.
function WordWise:paintHint(bb, x, y, e, line)
  e.widget:paintTo(bb, x + e.x, y + e.y)
  if not (line and e.wx0 and e.wx1 and e.word_top) then return end
  local thick = math.max(1, Screen:scaleBySize(1))
  local half = caretDepth(e.th)
  local color = e.color or Blitbuffer.COLOR_DARK_GRAY
  -- rule: the width of the hint (at least wide enough to hold the notch)
  local x0, x1 = x + e.x, x + e.x + e.tw
  if x1 - x0 < 2 * half + 2 then
    local mid = (x0 + x1) / 2
    x0, x1 = math.floor(mid - half - 1), math.ceil(mid + half + 1)
  end
  x0, x1 = math.floor(x0), math.floor(x1)
  -- notch: above the middle of the word, but inside the rule
  local cx = math.floor(x + (e.wx0 + e.wx1) / 2 + 0.5)
  cx = math.max(x0 + half, math.min(x1 - half, cx))
  -- just under the hint text, never lower than the notch tip may go above the word
  local ytop = math.min(math.floor(y + e.y + e.th + 1), math.floor(y + e.word_top) - half - thick - 1)
  if cx - half > x0 then bb:paintRect(x0, ytop, (cx - half) - x0, thick, color) end
  if x1 > cx + half then bb:paintRect(cx + half, ytop, x1 - (cx + half), thick, color) end
  for i = 0, half do
    bb:paintRect(cx - half + i, ytop + i, thick, thick, color)
    bb:paintRect(cx + half - i, ytop + i, thick, thick, color)
  end
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
  local with_line = self:cfg("connector") == "line"
  local size_pct = tonumber(self:cfg("size")) or 65
  local min_font = Screen:scaleBySize(tonumber(self:cfg("pdf_min_size")) or 8)
  local squeeze = math.max(0, math.min(100, tonumber(self:cfg("pdf_squeeze")) or 35)) / 100
  local list, waiting, dict_shown = {}, false, false
  local min_x, max_x
  local vs = self:viewStore()

  for _, page in ipairs(pages) do
    local a, b = self:pageRange(page)
    if not vs:covers(a, b) then waiting = true end
    if vs.usesDict and vs:usesDict(a, b) then dict_shown = true end
    local hints = self:filterHints(vs:query(a, b))
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
            local function reserve() return with_line and connectorReserve(size.h) or 0 end
            while widget and size.h > gap - 1 - reserve() and tries < 4 do
              tries = tries + 1
              local smaller = math.min(px - 1, math.floor(px * (gap - 1 - reserve()) / size.h))
              widget:free()
              widget = nil
              if smaller < min_font then break end
              px = smaller
              widget = build(px)
              size = widget:getSize()
            end
            if widget and size.h <= gap - 1 - reserve() then
              local close = math.floor(rect.y - 1 + inner)
              local bottom = PDF.hintBottom(rect.y, gap, size.h, position, inner)
              if with_line then bottom = math.min(bottom, close - connectorReserve(size.h)) end
              list[#list + 1] = {
                cx = rect.x + rect.w / 2,
                top = rect.y, -- line key for collision handling
                bottom = bottom,
                tw = size.w, th = size.h,
                widget = widget,
                t = h.t, hint = h.h,
                wx0 = rect.x, wx1 = rect.x + rect.w, wy = rect.y,
                word_top = close + 1, color = color,
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
  self.showing_dict = dict_shown
  if #list == 0 then return end

  local lo = math.max(margin, min_x or 0)
  local hi = math.min(width - margin, max_x or width)
  if hi - lo < width / 3 then lo, hi = margin, width - margin end
  local placed = Core.placeHints(list, {
    min_x = lo,
    max_x = hi,
    gap = Screen:scaleBySize(3),
    offset = self:hintOffset(),
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
      self.showing_dict = false
      return
    end
    local pages = self:visiblePages()
    local key = self:pagedLayoutKey(pages)
    if key ~= self.layout_key then
      self.layout_key = key -- set first: a failing build is not retried on every repaint
      self:buildPagedLayout(pages)
    end
    local line = self:cfg("connector") == "line"
    for _, e in ipairs(self.layout) do
      self:paintHint(bb, x, y, e, line)
    end
  end)
  if not ok then
    logger.warn("Word Wise: PDF paint failed:", err)
  end
end

function WordWise:buildLayout(a, b)
  self:freeLayout()
  local doc = self.ui.document
  local vs = self:viewStore()
  local hints = self:filterHints(vs:query(a, b))
  self.waiting_current = not vs:covers(a, b)
  self.showing_dict = (vs.usesDict and vs:usesDict(a, b)) or false
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
  local with_line = self:cfg("connector") == "line"
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
    -- top of the glyphs of the hinted line: the hint (and its marker) stays above it
    local close = Core.hintBottom(box.y, box.h, spacing, size.h, "close")
    local word_top = close + 1
    local bottom = Core.hintBottom(box.y, box.h, spacing, size.h, position)
    if with_line then bottom = math.min(bottom, close - connectorReserve(size.h)) end
    list[#list + 1] = {
      cx = box.x + box.w / 2,
      top = box.y, -- line key for collision handling
      bottom = bottom,
      tw = size.w, th = size.h,
      widget = widget,
      t = f.h.t, hint = f.h.h,
      wx0 = box.x, wx1 = box.x + box.w, wy = box.y,
      word_top = word_top, color = color,
    }
  end

  local placed = Core.placeHints(list, {
    min_x = min_x,
    max_x = max_x,
    gap = Screen:scaleBySize(3),
    offset = self:hintOffset(),
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
  self.paint_x, self.paint_y = x, y -- origin of the hints, used to find a tapped hint
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
    local line = self:cfg("connector") == "line"
    for _, e in ipairs(self.layout) do
      self:paintHint(bb, x, y, e, line)
    end
  end)
  if not ok then
    logger.warn("Word Wise: paint failed:", err)
  end
end

return WordWise
