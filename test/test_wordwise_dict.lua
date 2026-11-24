-- test_wordwise_dict.lua
-- utils/wordwise_dict (offline dictionary) and utils/wordwise_kindle (conversion of
-- Kindle's own corpus): lookups with inflected forms, hint shortening, page items that
-- Core.resolve can place, and a conversion run on a small synthetic Kindle database.
local helper = require("test.helper")
local assert = helper.assert
local Dict = require("utils/wordwise_dict")
local Kindle = require("utils/wordwise_kindle")
local Core = require("utils/wordwise_core")
local SQ3 = require("lua-ljsqlite3/init")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function words(text)
    local out = {}
    for token in text:gmatch("%S+") do out[#out + 1] = { text = token } end
    return out
end

-- b64 of a short string, as Kindle stores the glosses
local function b64(s)
    local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2, c3, c4 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64,
            math.floor(n / 64) % 64, n % 64
        out[#out + 1] = B:sub(c1 + 1, c1 + 1) .. B:sub(c2 + 1, c2 + 1)
            .. (b and B:sub(c3 + 1, c3 + 1) or "=") .. (c and B:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

local tests = {
    test("the bundled dictionary exists, opens and counts its entries", function()
        assert.isTrue(Dict.available(), "data/wordwise_offline.db must be in the plugin")
        local db = Dict.open()
        assert.notNil(db)
        assert.isTrue(db:count() > 20000)
        db:close()
    end),

    test("lookup: a rare word has a gloss, a difficulty and a part of speech", function()
        local db = Dict.open()
        local r = db:lookup("Solemn")
        assert.notNil(r)
        assert.equal(r.gloss, "serious and dignified")
        assert.equal(r.pos, "adjective")
        assert.equal(db:lookup("zzzzqx"), nil)
        assert.equal(db:lookup(""), nil)
        db:close()
    end),

    test("lookup: inflected forms land on the base word, guarded by part of speech", function()
        local db = Dict.open()
        local forms = Dict._candidates("studies")
        assert.equal(forms[1][1], "studies")
        local found = false
        for _i, c in ipairs(forms) do
            if c[1] == "study" and c[2] == "plural" then found = true end
        end
        assert.isTrue(found, "studies -> study")
        assert.equal(Dict._candidates("morning")[2], nil, "words that only look inflected are left alone")
        db:close()
    end),

    test("shorten: a gloss that fits is unchanged, a long one is cut sensibly", function()
        assert.equal(Dict._shorten("serious and dignified", 40), "serious and dignified")
        assert.equal(Dict._shorten("peaceful; calm and quiet", 12), "peaceful")
        assert.equal(Dict._shorten("relating to peaceful country life", 24), "peaceful country life")
        assert.equal(Dict._shorten("an old story", 5), "old story")
    end),

    test("looksEnglish tells English prose from another language", function()
        assert.isTrue(Dict.looksEnglish(words("He said that it was the end of the day and they had to go")))
        assert.isFalse(Dict.looksEnglish(words("Der Hund lief durch den Garten und bellte laut vor dem Haus")))
    end),

    test("items: hard words become picks that Core.resolve places; names and easy words do not", function()
        local db = Dict.open()
        local page = words("Then Solemn walked in. The solemn judge, a lugubrious man, spoke to the cat.")
        local items = db:items(page, { max_chars = 30 })
        local by = {}
        for _i, it in ipairs(items) do by[it.t] = it end
        assert.equal(by.solemn, nil, "capitalised in mid-sentence somewhere on the page: a name")
        assert.notNil(by.lugubrious)
        assert.equal(by.lugubrious.l, "C2", "difficulty 1 is the hardest grade")
        assert.equal(by.cat, nil, "easy words are not in the dictionary")
        local cands = Core.resolve(items, page, { level = "B1", density = "medium" })
        assert.isTrue(#cands >= 1)
        db:close()
    end),

    test("a gloss respects the hint length", function()
        local db = Dict.open()
        for _i, it in ipairs(db:items(words("lugubrious solemn ubiquitous"), { max_chars = 12 })) do
            assert.isTrue(Core.utf8len(it.h) <= 24, "never absurdly long: " .. it.h)
        end
        db:close()
    end),

    test("kindle convert: picks the first sense, skips initialisms and placeholders", function()
        local dir = os.tmpname()
        os.remove(dir)
        assert.equal(require("libs/libkoreader-lfs").mkdir(dir), true)
        local klld, out = dir .. "/kll.en.en.klld", dir .. "/wordwise.db"
        local src = SQ3.open(klld, "rwc")
        src:exec([[
            CREATE TABLE lemmas(id INTEGER, lemma TEXT);
            CREATE TABLE senses(term_lemma_id INTEGER, sense_number INTEGER, corpus_count INTEGER,
                pos_type INTEGER, short_def TEXT);
        ]])
        local lem = src:prepare("INSERT INTO lemmas VALUES(?1,?2);")
        local sen = src:prepare("INSERT INTO senses VALUES(?1,?2,?3,?4,?5);")
        local function lemma(id, w) lem:reset():clearbind(); lem:bind(id, w); lem:step() end
        local function sense(id, n, cc, pos, def) sen:reset():clearbind(); sen:bind(id, n, cc, pos, b64(def)); sen:step() end
        lemma(1, "Solemn"); sense(1, 2, 90, 2, "second sense"); sense(1, 1, 5, 2, "serious and dignified")
        lemma(2, "led"); sense(2, 1, 9, 0, "light-emitting diode")
        lemma(3, "junk"); sense(3, 1, 9, 0, "DO NOT USE THIS ENTRY")
        lemma(4, "two words"); sense(4, 1, 9, 0, "ignored")
        lem:close(); sen:close(); src:close()

        assert.isTrue(Kindle.convert(klld, out, Dict.bundledPath()))
        local db = SQ3.open(out, "ro")
        local rows = {}
        for row in db:prepare("SELECT word, short_def, difficulty, pos FROM entries;"):rows() do
            rows[#rows + 1] = row[1] .. "|" .. row[2] .. "|" .. tostring(tonumber(row[3])) .. "|" .. row[4]
        end
        db:close()
        assert.equal(#rows, 1, "only the real word survives: " .. table.concat(rows, ";"))
        assert.equal(rows[1], "solemn|serious and dignified|3|adjective", "sense 1, difficulty borrowed from the bundled dictionary")
        assert.equal(Kindle.convert(dir .. "/missing.klld", out), false)
        os.remove(klld); os.remove(out); os.remove(dir)
    end),
}

return helper.runTests("wordwise_dict", tests)
