--[[--
Offline dictionary of Word Wise.

Gives short glosses for hard words without any AI request or internet
connection. Based on the approach of wordwise.koplugin: a small SQLite
database in the canonical schema

    entries(word TEXT PRIMARY KEY COLLATE NOCASE,
            short_def TEXT NOT NULL,
            difficulty INTEGER NOT NULL,   -- 1 rarest .. 5 most common
            pos TEXT)                      -- optional

Which database is used (first match wins, like in wordwise.koplugin):
  1. <KOReader data dir>/wordwise/wordwise.db
  2. the first *.db in that directory
  3. the dictionary shipped with the plugin (data/wordwise_offline.db)

Nothing here touches the UI. Every function that talks to SQLite or the file
system is guarded: a missing or broken database means "no offline hints",
never an error.
]]

local logger = require("logger")
local Core = require("utils/wordwise_core")

local Dict = {}
Dict.__index = Dict

local SQL_POS = "SELECT short_def, difficulty, pos FROM entries WHERE word = ?1 LIMIT 1;"
local SQL_NOPOS = "SELECT short_def, difficulty FROM entries WHERE word = ?1 LIMIT 1;"

-- difficulty of the dictionary (1 rarest .. 5 most common) -> CEFR grade, so that the
-- reader's level and the hint density apply exactly as they do for AI hints.
local LEVEL_OF = { [1] = "C2", [2] = "C1", [3] = "B2", [4] = "B1", [5] = "A2" }

---------------------------------------------------------------------------
-- Locations
---------------------------------------------------------------------------

local function lfsModule()
    local ok, m = pcall(require, "libs/libkoreader-lfs")
    return ok and m or nil
end

local function sqlite()
    local ok, m = pcall(require, "lua-ljsqlite3/init")
    return ok and m or nil
end

local function dataDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage then return nil end
    local ok2, dir = pcall(function() return DataStorage:getDataDir() end)
    return ok2 and dir or nil
end

--- Directory of the plugin (with a trailing slash).
local function pluginDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source and info.source:match("^@(.+)$") or ""
    local dir = src:match("(.*/)") or ""
    dir = dir:gsub("utils/$", "")
    if dir == "" then
        local dd = dataDir()
        dir = dd and (dd .. "/plugins/assistant.koplugin/") or "./"
    end
    return dir
end

--- Directory for a dictionary of your own (shared with wordwise.koplugin).
function Dict.userDir()
    local dd = dataDir()
    return dd and (dd .. "/wordwise") or nil
end

function Dict.bundledPath()
    return pluginDir() .. "data/wordwise_offline.db"
end

--- Databases to try, best first: { { path = ..., kind = "user" | "bundled" }, ... }
function Dict.candidatePaths()
    local out = {}
    local lfs = lfsModule()
    if not lfs then return out end
    local dir = Dict.userDir()
    if dir and lfs.attributes(dir, "mode") == "directory" then
        local preferred = dir .. "/wordwise.db"
        if lfs.attributes(preferred, "mode") == "file" then
            out[#out + 1] = { path = preferred, kind = "user" }
        else
            local names = {}
            pcall(function()
                for name in lfs.dir(dir) do
                    if name:match("%.db$") then names[#names + 1] = name end
                end
            end)
            table.sort(names)
            if names[1] then out[#out + 1] = { path = dir .. "/" .. names[1], kind = "user" } end
        end
    end
    local bundled = Dict.bundledPath()
    if lfs.attributes(bundled, "mode") == "file" then
        out[#out + 1] = { path = bundled, kind = "bundled" }
    end
    return out
end

--- Path of the database that would be used, or nil when there is none.
function Dict.resolvePath()
    local first = Dict.candidatePaths()[1]
    if first then return first.path, first.kind end
    return nil
end

--- Is there any dictionary at all?
function Dict.available()
    return Dict.resolvePath() ~= nil
end

--- Short text identifying the dictionary in use (part of cache signatures).
function Dict.signature()
    local path = Dict.resolvePath()
    return path or "none"
end

---------------------------------------------------------------------------
-- Forms of a word
---------------------------------------------------------------------------

-- Words that look inflected but are not: de-inflecting them lands on an unrelated word.
local NO_DEINFLECT = { morning = true, evening = true, passing = true }

--- Possible base forms of `w`, most likely first: { { string, kind }, ... }.
--- The kind tells which part of speech the base form must have, so that for
--- example "fooled" does not end up with the noun "fool".
local function candidates(w)
    local out = { { w, "base" } }
    if NO_DEINFLECT[w] then return out end
    local n = #w
    local function add(s, kind)
        if s and #s >= 3 then out[#out + 1] = { s, kind } end
    end
    if n >= 5 and w:sub(-3) == "ies" then add(w:sub(1, n - 3) .. "y", "plural") end   -- studies -> study
    if n >= 5 and w:sub(-3) == "ves" then
        add(w:sub(1, n - 3) .. "f", "plural")                                          -- wolves -> wolf
        add(w:sub(1, n - 3) .. "fe", "plural")                                         -- knives -> knife
    end
    if n >= 5 and w:sub(-2) == "es" then add(w:sub(1, n - 2), "plural") end          -- boxes -> box
    if n >= 4 and w:sub(-1) == "s" then add(w:sub(1, n - 1), "plural") end           -- traditions -> tradition
    if n >= 6 and w:sub(-3) == "men" then add(w:sub(1, n - 3) .. "man", "plural") end -- herdsmen -> herdsman
    if n >= 5 and w:sub(-2) == "ly" then
        add(w:sub(1, n - 2), "ly")                                                     -- splendidly -> splendid
        if w:sub(-3) == "ily" then add(w:sub(1, n - 3) .. "y", "ly") end               -- happily -> happy
    end
    if n >= 5 and w:sub(-2) == "ed" then
        if w:sub(-3) == "ied" then add(w:sub(1, n - 3) .. "y", "ed") end               -- studied -> study
        add(w:sub(1, n - 1), "ed")                                                     -- glimpsed -> glimpse
        add(w:sub(1, n - 2), "ed")                                                     -- walked -> walk
        if w:sub(n - 2, n - 2) == w:sub(n - 3, n - 3) then add(w:sub(1, n - 3), "ed") end -- stopped -> stop
    end
    if n >= 6 and w:sub(-3) == "ing" then
        add(w:sub(1, n - 3), "ing")                                                    -- hurrying -> hurry
        add(w:sub(1, n - 3) .. "e", "ing")                                             -- making -> make
        if w:sub(n - 3, n - 3) == w:sub(n - 4, n - 4) then add(w:sub(1, n - 4), "ing") end -- running -> run
    end
    return out
end
Dict._candidates = candidates -- for tests

local GUARD = {
    base = function() return true end,
    plural = function(pos) return pos == nil or pos == "noun" or pos == "verb" end,
    ly = function(pos) return pos == nil or pos == "adjective" end,
    ed = function(pos) return pos == nil or pos == "verb" or pos == "adjective" end,
    ing = function(pos) return pos == nil or pos == "verb" or pos == "adjective" end,
}

---------------------------------------------------------------------------
-- Database
---------------------------------------------------------------------------

local function openDb(path, kind)
    local SQ3 = sqlite()
    if not SQ3 then return nil end
    local ok, conn = pcall(SQ3.open, path, "ro")
    if not ok or not conn then
        logger.warn("Word Wise dictionary: cannot open", path, tostring(conn))
        return nil
    end
    local stmt
    local ok2, s = pcall(function() return conn:prepare(SQL_POS) end)
    if ok2 and s then
        stmt = s
    else
        -- a database of your own may lack the optional pos column
        local ok3, s2 = pcall(function() return conn:prepare(SQL_NOPOS) end)
        if ok3 and s2 then stmt = s2 end
    end
    if not stmt then
        logger.warn("Word Wise dictionary: not a usable dictionary:", path)
        pcall(function() conn:close() end)
        return nil
    end
    return setmetatable({ conn = conn, stmt = stmt, path = path, kind = kind, cache = {} }, Dict)
end

--- Open the best usable dictionary. Returns nil when there is none.
function Dict.open()
    for _i, c in ipairs(Dict.candidatePaths()) do
        local db = openDb(c.path, c.kind)
        if db then return db end
    end
    return nil
end

-- One raw lookup of an exact key. Returns { gloss, difficulty, pos, key } or nil.
function Dict:_query(key)
    local result
    local ok, err = pcall(function()
        self.stmt:reset():clearbind()
        self.stmt:bind(key)
        local row = self.stmt:step()
        if row then
            local gloss = type(row[1]) == "string" and row[1]:gsub("^%s+", ""):gsub("%s+$", "") or nil
            local difficulty = tonumber(row[2])
            local pos = type(row[3]) == "string" and row[3] or nil
            if gloss and gloss ~= "" and difficulty then
                result = { gloss = gloss, difficulty = difficulty, pos = pos, key = key }
            end
        end
        self.stmt:clearbind():reset()
    end)
    if not ok then logger.warn("Word Wise dictionary: lookup failed for", key, tostring(err)) end
    return result
end

--- { gloss, difficulty, pos, key } for a word (lower case) or nil. Tries the word
--- itself and then its base forms. Results (also misses) are cached.
function Dict:lookup(word)
    if type(word) ~= "string" or word == "" then return nil end
    local key = Core.lower(word)
    local cached = self.cache[key]
    if cached ~= nil then return cached or nil end
    local result
    for _i, c in ipairs(candidates(key)) do
        local r = self:_query(c[1])
        if r and GUARD[c[2]](r.pos) then
            result = r
            break
        end
    end
    self.cache[key] = result or false
    return result
end

--- Number of entries (for the info screen). nil when it cannot be read.
function Dict:count()
    local SQ3 = sqlite()
    if not SQ3 then return nil end
    local n
    pcall(function()
        local conn = SQ3.open(self.path, "ro")
        local row = conn:rowexec("SELECT COUNT(*) FROM entries;")
        n = tonumber(row)
        conn:close()
    end)
    return n
end

function Dict:close()
    if self.stmt then pcall(function() self.stmt:close() end) end
    if self.conn then pcall(function() self.conn:close() end) end
    self.stmt, self.conn = nil, nil
end

---------------------------------------------------------------------------
-- Words of a page -> hint items
---------------------------------------------------------------------------

local function endsSentence(text)
    local p = text
    for _i = 1, 3 do
        p = p:gsub("[\"')%]]$", ""):gsub("\226\128[\153\157]$", ""):gsub("\194\187$", "")
    end
    return p:match("[%.!%?:]$") ~= nil or p:match("\226\128\166$") ~= nil -- ... or the ellipsis sign
end

--- Is this word probably a name (capitalised in the middle of a sentence) or a
--- word in capitals (heading)? Such words are never hinted.
local function looksLikeName(text, prev_text)
    -- skip an opening quote or bracket (also the multi-byte ones: “ ‘ «) before the first letter
    local first = text:match("^[%s%p\128-\255]*(%a)")
    if not first then return false end
    local letters = text:gsub("[^%a]", "")
    if #letters >= 2 and letters == letters:upper() then return true end
    if first ~= first:upper() then return false end
    if prev_text == nil then return false end   -- first word of the page: could start a sentence
    return not endsSentence(prev_text)
end

-- Function words of English. A page of English prose is full of them, a page in
-- another language hardly has any (see Dict.looksEnglish).
local ENGLISH_WORDS = {}
for w in ([[the and of to in that is was it for with as on he she his her they at by this from had have
  but not are you we be were him them their there which what when who would could said will an or
  if then so out up about into than its has been]]):gmatch("%a+") do
    ENGLISH_WORDS[w] = true
end

--- Does this page (list of { text = ... }) look like English? Used only for books
--- whose language is not stated: the English dictionary must not hint a page in
--- another language ("pole", "most", "list" ... exist in both).
function Dict.looksEnglish(words)
    local total, hits = 0, 0
    for _i, w in ipairs(words) do
        if type(w.text) == "string" then
            local toks = Core.tokenize(w.text)
            if toks[1] then
                total = total + 1
                if ENGLISH_WORDS[toks[1]] then hits = hits + 1 end
            end
        end
    end
    if total < 12 then return total > 0 and hits >= 1 end
    return hits / total >= 0.12
end

-- Leading phrases that only say "this is a kind of ...": dropped when a gloss is
-- too long for a hint ("relating to peaceful country life" -> "peaceful country life").
local FILLER = { "^of or relating to ", "^relating to ", "^pertaining to ", "^characteristic of ", "^having to do with " }

--- Make a gloss fit a hint of `max_chars` characters without cutting it in the
--- middle where that can be avoided. A gloss that already fits is returned as is.
local function shorten(gloss, max_chars)
    if Core.utf8len(gloss) <= max_chars then return gloss end
    local g = gloss
    local function fits() return Core.utf8len(g) <= max_chars end
    -- alternatives separated by ";" -> the first one
    local first = g:match("^([^;]+);")
    if first and Core.utf8len(first) >= 6 then g = first:gsub("%s+$", "") end
    if fits() then return g end
    for _i, pat in ipairs(FILLER) do
        local rest = g:gsub(pat, "", 1)
        if rest ~= g and rest ~= "" then g = rest end
    end
    if fits() then return g end
    g = g:gsub("^[Aa]n? ", ""):gsub("^[Tt]he ", "")
    return g
end
Dict._shorten = shorten -- for tests

--- The single word of a page word, or nil: "terrain," -> "terrain", "wolf's" -> "wolf".
local function singleToken(text)
    local toks = Core.tokenize(text)
    if #toks == 1 then return toks[1] end
    if #toks == 2 and toks[2] == "s" then return toks[1] end -- possessive 's
    return nil
end

--- Items { t, h, l } for the hard words among `words` (the same shape the AI answers
--- with), so that Core.resolve places them and applies level and density.
--- @param words table[] page words, each { text = string, ... }
--- @param o table|nil { max_chars = int }
function Dict:items(words, o)
    o = o or {}
    local max_chars = tonumber(o.max_chars) or 24
    -- A word that appears as a name on the page (capitalised in the middle of a
    -- sentence, or in capitals) is never hinted anywhere on it: Core.resolve puts
    -- a hint on the FIRST occurrence, which might be the name.
    local names = {}
    for i, w in ipairs(words) do
        local text = w.text
        if type(text) == "string" then
            local tok = singleToken(text)
            if tok and looksLikeName(text, i > 1 and words[i - 1].text or nil) then names[tok] = true end
        end
    end
    local items, seen = {}, {}
    for _i, w in ipairs(words) do
        local text = w.text
        if type(text) == "string" then
            local tok = singleToken(text)
            if tok and not seen[tok] and not names[tok] and Core.utf8len(tok) >= 3 then
                seen[tok] = true
                local r = self:lookup(tok)
                if r then
                    items[#items + 1] = { t = tok, h = shorten(r.gloss, max_chars), l = LEVEL_OF[r.difficulty] or "B2" }
                end
            end
        end
    end
    return items
end

---------------------------------------------------------------------------
-- Kindle's own Word Wise data (optional, personal use)
---------------------------------------------------------------------------

local function kindleModule()
    local ok, m = pcall(require, "utils/wordwise_kindle")
    return ok and m or nil
end

--- Does this device have Kindle's own Word Wise corpus?
function Dict.kindleAvailable()
    local K = kindleModule()
    local lfs = lfsModule()
    return K ~= nil and lfs ~= nil and lfs.attributes(K.KLLD_PATH, "mode") == "file"
end

--- Is there a database of your own (or a converted one) in the data directory?
function Dict.hasUserDb()
    local first = Dict.candidatePaths()[1]
    return first ~= nil and first.kind == "user"
end

--- One-time conversion of Kindle's corpus into <data>/wordwise/wordwise.db.
--- Can take a while on slow storage. @return boolean success
function Dict.convertKindle()
    local K = kindleModule()
    local lfs = lfsModule()
    local dir = Dict.userDir()
    if not (K and lfs and dir and Dict.kindleAvailable()) then return false end
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local ok, res = pcall(K.convert, K.KLLD_PATH, dir .. "/wordwise.db", Dict.bundledPath())
    return ok and res == true
end

return Dict
