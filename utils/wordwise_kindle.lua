--[[--
Detect a real Kindle Word Wise dictionary on-device and convert it into the
plugin's canonical schema, for personal use only.

Amazon ships the actual gloss corpus at a fixed system path once Word Wise has
been used at least once (`KLLD_PATH` below); per-book `.sdr/*.kll` files hold
only positional offsets, not text. This module never leaves the device: it
only reads a file that Amazon/Kindle already placed there, and writes the
converted result into the plugin's own user data directory. Nothing here is
ever bundled or distributed with the plugin -- see README.md.

Canonical output schema (what utils/wordwise_dict.lua reads):
  entries(word TEXT PRIMARY KEY COLLATE NOCASE,
          short_def TEXT NOT NULL, difficulty INTEGER NOT NULL, pos TEXT)

Kindle's own db has no per-word difficulty column (only a per-sense corpus
count, used below just to pick the primary sense). Rather than requiring
Kindle's separate frequency word lists, difficulty is borrowed from the
bundled open dictionary for any word it already rates; words it doesn't carry
fall back to a middle difficulty.
]]--
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local WordWiseKindle = {}

-- Kindle's on-device Word Wise corpus (present on Kindle firmware, jailbroken
-- or not, once Word Wise has been enabled/used at least once).
WordWiseKindle.KLLD_PATH = "/mnt/us/system/kll/kll.en.en.klld"

local DEFAULT_DIFFICULTY = 3 -- used only for words missing from the open dict

local POS = { [0] = "noun", [1] = "verb", [2] = "adjective", [3] = "adverb",
    [4] = "article", [5] = "number", [6] = "conjunction", [7] = "other",
    [8] = "preposition", [9] = "pronoun", [10] = "particle", [11] = "punctuation" }

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_REV = {}
for i = 1, #B64 do B64_REV[B64:byte(i)] = i - 1 end

-- short_def is base64-encoded in Kindle's db; decode 4 chars -> up to 3 bytes.
local function b64decode(data)
    if not data or data == "" then return nil end
    local out = {}
    for i = 1, #data, 4 do
        local c1, c2, c3, c4 = data:byte(i, i + 3)
        local v1, v2 = B64_REV[c1], B64_REV[c2]
        if not v1 or not v2 then break end
        local pad3, pad4 = (not c3 or c3 == 61), (not c4 or c4 == 61)
        local v3 = pad3 and 0 or B64_REV[c3]
        local v4 = pad4 and 0 or B64_REV[c4]
        if not v3 or not v4 then break end
        local n = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if not pad3 then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
        if not pad4 then out[#out + 1] = string.char(n % 256) end
    end
    return table.concat(out)
end

-- True if the headword is just the initials of its gloss, i.e. an acronym
-- expansion (led -> "light-emitting diode"). These collide with common words
-- when lowercased (notably led = past tense of lead), so skip such senses.
local function isInitialism(word, gloss)
    local initials = {}
    for tok in gloss:lower():gmatch("%a+") do
        initials[#initials + 1] = tok:sub(1, 1)
    end
    if #word < 2 or #initials ~= #word then return false end
    return table.concat(initials) == word
end

-- True if Kindle's own device has ever populated its Word Wise corpus.
function WordWiseKindle.available()
    return lfs.attributes(WordWiseKindle.KLLD_PATH, "mode") == "file"
end

-- word -> difficulty, borrowed from the bundled/override open dictionary.
local function loadDifficulty(difficulty_db_path)
    local difficulty = {}
    if not difficulty_db_path then return difficulty end
    local ok, db = pcall(SQ3.open, difficulty_db_path, "ro")
    if not ok or not db then return difficulty end
    pcall(function()
        for row in db:prepare("SELECT word, difficulty FROM entries;"):rows() do
            difficulty[row[1]:lower()] = tonumber(row[2])
        end
    end)
    pcall(function() db:close() end)
    return difficulty
end

-- Convert Kindle's kll.en.en.klld (klld_path) into the canonical schema at
-- out_path. difficulty_db_path (optional) is queried for difficulty ratings.
-- Returns true on success.
function WordWiseKindle.convert(klld_path, out_path, difficulty_db_path)
    local ok, src = pcall(SQ3.open, klld_path, "ro")
    if not ok or not src then
        logger.warn("WordWiseKindle: cannot open", klld_path, tostring(src))
        return false
    end

    local difficulty = loadDifficulty(difficulty_db_path)

    local lemma = {}
    local ok_l = pcall(function()
        -- ids come back as boxed int64_t cdata; tonumber() them so they hash
        -- consistently as plain Lua table keys.
        for row in src:prepare("SELECT id, lemma FROM lemmas;"):rows() do
            lemma[tonumber(row[1])] = row[2]
        end
    end)
    if not ok_l then
        pcall(function() src:close() end)
        logger.warn("WordWiseKindle: failed reading lemmas from", klld_path)
        return false
    end

    -- best[word] = { key = {sense_number, -corpus_count}, short_def, pos }
    local best = {}
    local ok_s = pcall(function()
        local stmt = src:prepare(
            "SELECT term_lemma_id, sense_number, corpus_count, pos_type, short_def " ..
            "FROM senses WHERE short_def IS NOT NULL AND short_def <> '';")
        for row in stmt:rows() do
            local word = lemma[tonumber(row[1])]
            if word then
                word = word:lower()
                if word ~= "" and not word:find(" ", 1, true) and word:find("%a") then
                    local sdef = b64decode(row[5])
                    if sdef and sdef ~= "" then
                        -- also trim UTF-8 NBSP (C2 A0); Kindle's own data has
                        -- a few trailing ones and Lua's %s only sees ASCII.
                        sdef = sdef:gsub("^[%s\194\160]+", ""):gsub("[%s\194\160]+$", "")
                        local up = sdef:upper()
                        if sdef ~= "" and not up:find("DO NOT USE THIS ENTRY", 1, true)
                            and not up:find("SEE MW LD", 1, true)
                            and not isInitialism(word, sdef) then
                            local sense_no = tonumber(row[2]) or 0
                            local neg_cc = -(tonumber(row[3]) or 0)
                            local cur = best[word]
                            local better = not cur
                            if cur then
                                if sense_no < cur.key[1] then
                                    better = true
                                elseif sense_no == cur.key[1] and neg_cc < cur.key[2] then
                                    better = true
                                end
                            end
                            if better then
                                best[word] = { key = { sense_no, neg_cc },
                                    short_def = sdef,
                                    pos = POS[tonumber(row[4]) or 7] or "other" }
                            end
                        end
                    end
                end
            end
        end
    end)
    pcall(function() src:close() end)
    if not ok_s then
        logger.warn("WordWiseKindle: failed reading senses from", klld_path)
        return false
    end

    local n = 0
    for _k in pairs(best) do n = n + 1 end
    if n == 0 then
        logger.warn("WordWiseKindle: no usable entries found in", klld_path)
        return false
    end

    if lfs.attributes(out_path, "mode") then os.remove(out_path) end
    local ok_out, out = pcall(SQ3.open, out_path, "rwc")
    if not ok_out or not out then
        logger.warn("WordWiseKindle: cannot create", out_path, tostring(out))
        return false
    end
    local ok_w = pcall(function()
        out:exec([[
            PRAGMA journal_mode=OFF;
            CREATE TABLE entries(word TEXT PRIMARY KEY COLLATE NOCASE,
                short_def TEXT NOT NULL, difficulty INTEGER NOT NULL, pos TEXT);
        ]])
        -- Without an explicit transaction each INSERT auto-commits (and syncs
        -- to flash) on its own -- fine on an SSD, but 50k+ individual commits
        -- on a Kindle's slow storage can block the UI thread for minutes.
        out:exec("BEGIN;")
        local ins = out:prepare("INSERT OR IGNORE INTO entries VALUES(?1,?2,?3,?4);")
        for word, v in pairs(best) do
            ins:reset():clearbind()
            ins:bind(word, v.short_def, difficulty[word] or DEFAULT_DIFFICULTY, v.pos)
            ins:step()
        end
        ins:close()
        out:exec("COMMIT;")
    end)
    pcall(function() out:close() end)
    if not ok_w then
        logger.warn("WordWiseKindle: failed writing", out_path)
        os.remove(out_path)
        return false
    end

    logger.info("WordWiseKindle: converted", n, "entries from", klld_path, "to", out_path)
    return true
end

return WordWiseKindle
