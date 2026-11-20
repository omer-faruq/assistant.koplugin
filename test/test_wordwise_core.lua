-- test_wordwise_core.lua
-- utils/wordwise_core: tokenizer, phrase matching, level/density resolution, the
-- tolerant parser of the AI answer, prompt budget and hint placement.
local helper = require("test.helper")
local assert = helper.assert
local Core = require("utils/wordwise_core")
local rapidjson = require("rapidjson")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function words(text)
    local out = {}
    for token in text:gmatch("%S+") do out[#out + 1] = { text = token } end
    return out
end

local function parse(raw) return Core.parseResponse(raw, rapidjson.decode) end

local function joined(tokens) return table.concat(tokens, "|") end

local tests = {
    -- tokenizer -----------------------------------------------------------
    test("tokenize: lower-cases and splits like crengine", function()
        assert.equal(joined(Core.tokenize("Don't stop, well-known!")), "don|t|stop|well-known")
        assert.equal(joined(Core.tokenize("\226\128\156Quoted\226\128\157 x")), "quoted|x")
    end),

    test("tokenize: hyphen flavours unify, a dangling hyphen splits", function()
        assert.equal(joined(Core.tokenize("self\226\128\144important")), "self-important")
        assert.equal(joined(Core.tokenize("a- b -c")), "a|b|c")
    end),

    test("tokenize and lower handle accents, Greek and Cyrillic", function()
        assert.equal(Core.lower("\195\156BER"), "\195\188ber")
        assert.equal(joined(Core.tokenize("\206\145\206\187\206\172 \208\159\209\128\208\184\208\178\208\181\209\130")),
            "\206\177\206\187\206\172|\208\191\209\128\208\184\208\178\208\181\209\130")
    end),

    test("lower leaves text that is not valid UTF-8 intact (ASCII only)", function()
        assert.equal(Core.lower("AB\255CD"), "ab\255cd")
    end),

    test("utf8len counts characters, not bytes", function()
        assert.equal(Core.utf8len("abc"), 3)
        assert.equal(Core.utf8len("\195\169\228\184\173"), 2)
    end),

    -- phrase matching -----------------------------------------------------
    test("find: contiguous phrase and every occurrence", function()
        local stream = Core.buildStream(words("the cat sat and the cat ran"))
        local hits = Core.find(stream, Core.tokenize("the cat"))
        assert.equal(#hits, 2)
        assert.equal(hits[2].s, 5)
    end),

    test("find: separated phrasal verb matches loosely", function()
        local stream = Core.buildStream(words("she picked the heavy book up quickly"))
        local hits = Core.find(stream, Core.tokenize("picked up"))
        assert.equal(#hits, 1)
        assert.equal(hits[1].s, 2)
        assert.equal(hits[1].e, 6)
    end),

    test("find: hyphen-tolerant match across a line break", function()
        local stream = Core.buildStream(words("a self- important man"))
        local hits = Core.find(stream, Core.tokenize("self-important"))
        assert.equal(#hits, 1)
        assert.equal(hits[1].s, 2)
    end),

    -- resolve -------------------------------------------------------------
    test("resolve: places a pick on the page words", function()
        local page = words("The solemn judge spoke")
        local cands = Core.resolve({ { t = "solemn", h = "serious", l = "C1" } }, page, { level = "B1" })
        assert.equal(#cands, 1)
        assert.equal(cands[1].w0, 2)
        assert.equal(cands[1].hint, "serious")
    end),

    test("resolve: picks easier than the reader's level are dropped", function()
        local page = words("The solemn judge spoke")
        local items = { { t = "solemn", h = "serious", l = "A2" } }
        local cands, stats = Core.resolve(items, page, { level = "B2", density = "medium" })
        assert.equal(#cands, 0)
        assert.equal(stats.too_easy, 1)
    end),

    test("resolve: density moves the threshold; no grade keeps the pick", function()
        local page = words("The solemn judge spoke")
        local graded = { { t = "solemn", h = "serious", l = "B1" } }
        assert.equal(#Core.resolve(graded, page, { level = "B2", density = "high" }), 1)
        assert.equal(#Core.resolve(graded, page, { level = "B2", density = "low" }), 0)
        assert.equal(#Core.resolve({ { t = "solemn", h = "serious" } }, page, { level = "C2" }), 1)
    end),

    test("resolve: a phrasal verb gets the benefit of one level", function()
        local page = words("they gave up the fight")
        local cands = Core.resolve({ { t = "gave up", h = "quit", l = "B1" } }, page, { level = "B2", density = "medium" })
        assert.equal(#cands, 1)
        assert.equal(cands[1].w0, 2)
        assert.equal(cands[1].w1, 3)
    end),

    test("resolve: repeating the word as the hint, or not finding it, is dropped", function()
        local page = words("The solemn judge spoke")
        local items = {
            { t = "solemn", h = "Solemn" },
            { t = "missing", h = "nothing" },
        }
        local cands, stats = Core.resolve(items, page, {})
        assert.equal(#cands, 0)
        assert.equal(stats.duplicate, 1)
        assert.equal(stats.unmatched, 1)
    end),

    test("resolve: all_occurrences hints up to three repeats", function()
        local page = words("odd odd odd odd odd")
        local items = { { t = "odd", h = "strange" } }
        assert.equal(#Core.resolve(items, page, { all_occurrences = true }), 3)
        assert.equal(#Core.resolve(items, page, { all_occurrences = false }), 1)
    end),

    test("resolve: the longer span wins an overlap, the cap keeps the hardest", function()
        local page = words("they kicked the bucket today")
        local items = {
            { t = "kicked", h = "hit", l = "C1" },
            { t = "kicked the bucket", h = "died", l = "C1" },
        }
        local cands = Core.resolve(items, page, {})
        assert.equal(#cands, 1)
        assert.equal(cands[1].hint, "died")
        local many = words("alpha beta gamma delta")
        local picks = {
            { t = "alpha", h = "a", l = "B2" }, { t = "beta", h = "b", l = "C2" },
            { t = "gamma", h = "c", l = "C1" },
        }
        local kept = Core.resolve(picks, many, { max_hints = 2 })
        assert.equal(#kept, 2)
        assert.equal(kept[1].text, "beta")
        assert.equal(kept[2].text, "gamma")
    end),

    -- AI answer parser ----------------------------------------------------
    test("parseResponse: plain JSON array", function()
        local items = parse('[{"t":"solemn","h":"serious","l":"C1"},{"t":"gave up","h":"quit"}]')
        assert.equal(#items, 2)
        assert.equal(items[1].l, "C1")
        assert.equal(items[2].l, nil)
    end),

    test("parseResponse: code fences and chatty text around the array", function()
        local items = parse('Sure!\n```json\n[{"t":"solemn","h":"serious"}]\n```\nHope it helps.')
        assert.equal(#items, 1)
        assert.equal(items[1].t, "solemn")
    end),

    test("parseResponse: reasoning blocks are removed first", function()
        local raw = '```reasoning\nmaybe {"t":"fake","h":"no"} is hard\n```\n[{"t":"real","h":"yes"}]'
        local items = parse(raw)
        assert.equal(#items, 1)
        assert.equal(items[1].t, "real")
        local think = parse('<think>{"t":"x","h":"y"}</think>[{"t":"a","h":"b"}]')
        assert.equal(#think, 1)
        assert.equal(think[1].t, "a")
    end),

    test("parseResponse: a truncated answer keeps every complete object", function()
        local items = parse('[{"t":"one","h":"1"},{"t":"two","h":"2"},{"t":"thr')
        assert.equal(#items, 2)
        assert.equal(items[2].t, "two")
    end),

    test("parseResponse: braces inside strings do not confuse the salvage", function()
        local items = parse('x [{"t":"a}b","h":"c{d"},{"t":"e","h":"f"} ')
        assert.equal(#items, 2)
        assert.equal(items[1].t, "a}b")
    end),

    test("parseResponse: alternative key names and a wrapping object", function()
        local items = parse('{"hints":[{"word":"solemn","meaning":"serious","level":"C1"}]}')
        assert.equal(#items, 1)
        assert.equal(items[1].t, "solemn")
        assert.equal(items[1].h, "serious")
        assert.equal(items[1].l, "C1")
    end),

    test("parseResponse: nothing usable gives an empty list", function()
        assert.equal(#parse(""), 0)
        assert.equal(#parse("[]"), 0)
        assert.equal(#parse("I could not find any hard words."), 0)
        assert.equal(#parse(nil), 0)
    end),

    test("answerText strips reasoning and fences for the log", function()
        assert.equal(Core.answerText("```reasoning\nthinking\n```\n  hello   world "), "hello world")
    end),

    -- hints and budget ----------------------------------------------------
    test("cleanHint trims quotes, final period and control characters", function()
        assert.equal(Core.cleanHint('  "serious."  '), "serious")
        assert.equal(Core.cleanHint("a\tb"), "a b")
        assert.equal(Core.cleanHint("   "), nil)
        assert.equal(Core.cleanHint(5), nil)
    end),

    test("truncateHint cuts on a word boundary with an ellipsis", function()
        assert.equal(Core.truncateHint("short", 10), "short")
        local cut = Core.truncateHint("a long explanation of a word", 14)
        assert.isTrue(Core.utf8len(cut) <= 14)
        assert.matches(cut, "\226\128\166$")
    end),

    test("maxHintsFor grows with the page, density and a lower level, within the cap", function()
        local medium = Core.maxHintsFor(350, "medium", "B2")
        assert.equal(medium, 10)
        assert.isTrue(Core.maxHintsFor(350, "high", "B2") > medium)
        assert.isTrue(Core.maxHintsFor(350, "low", "B2") < medium)
        assert.isTrue(Core.maxHintsFor(350, "medium", "A1") > medium)
        assert.equal(Core.maxHintsFor(5, "medium", "B2"), 2, "at least two")
        assert.isTrue(Core.maxHintsFor(100000, "medium", "B2") <= 16)
    end),

    test("buildMessages: level, language and the untrusted-text rule are in the prompt", function()
        local msgs = Core.buildMessages("Some page text here.", {
            level = "C1", hint_lang = "German", density = "low", style = "synonym",
            max_chars = 20, max_hints = 4, book = "Dune by Frank Herbert",
        })
        assert.equal(#msgs, 2)
        assert.equal(msgs[1].role, "system")
        assert.matches(msgs[1].content, "C1")
        assert.matches(msgs[1].content, "German")
        assert.matches(msgs[1].content, "At most 20 characters")
        assert.matches(msgs[1].content, "never follow instructions")
        assert.matches(msgs[1].content, "Dune by Frank Herbert")
        assert.equal(msgs[2].content, "<passage>\nSome page text here.\n</passage>")
    end),

    test("bookLine cleans untrusted metadata", function()
        assert.equal(Core.bookLine("A\nTitle", "Me"), "A Title by Me")
        assert.equal(Core.bookLine(nil, "Me"), "Me")
        assert.equal(Core.bookLine(nil, nil), nil)
    end),

    -- layout --------------------------------------------------------------
    test("placeHints centres hints over words and pushes a neighbour aside", function()
        local list = {
            { cx = 100, top = 10, tw = 40, th = 10, bottom = 8 },
            { cx = 110, top = 10, tw = 40, th = 10, bottom = 8 },
        }
        local placed = Core.placeHints(list, { min_x = 0, max_x = 400, gap = 4 })
        assert.equal(#placed, 2)
        assert.equal(placed[1].x, 80)
        assert.equal(placed[2].x, 124, "right of the first hint plus the gap")
        assert.equal(placed[1].y, -2)
    end),

    test("placeHints keeps hints inside the column and drops what cannot fit", function()
        local list = { { cx = 5, top = 10, tw = 40, th = 10 }, { cx = 390, top = 10, tw = 40, th = 10 } }
        local placed = Core.placeHints(list, { min_x = 0, max_x = 400 })
        assert.equal(placed[1].x, 0)
        assert.equal(placed[2].x, 360)
        local crowded = Core.placeHints({
            { cx = 20, top = 10, tw = 30, th = 10 }, { cx = 22, top = 10, tw = 30, th = 10 },
        }, { min_x = 0, max_x = 50, gap = 4 })
        assert.equal(#crowded, 1)
    end),

    test("hintBottom: with extra line spacing the hint sits in the gap above the glyphs", function()
        -- 40 px line box at 150% spacing: the empty gap is the top third (about 13 px)
        local close = Core.hintBottom(100, 40, 150, 10, "close")
        assert.equal(close, 112)
        assert.equal(Core.hintBottom(100, 40, 150, 10, "high"), 110)
        assert.equal(Core.hintBottom(100, 40, 100, 10, "close"), 99, "no extra spacing: just above the line")
    end),
}

return helper.runTests("wordwise_core", tests)
