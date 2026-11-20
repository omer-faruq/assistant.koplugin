-- test_wordwise_store.lua
-- utils/wordwise_store: hints by document position plus the coverage ranges.
-- Positions are zero-padded numbers, so plain string order is document order and
-- the comparator can be injected like CreDocument:compareXPointers is in the plugin.
local helper = require("test.helper")
local assert = helper.assert
local Store = require("utils/wordwise_store")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function pos(n) return string.format("%04d", n) end

local function cmp(a, b)
    if a == nil or b == nil then return nil end
    if a == b then return 0 end
    return a < b and 1 or -1
end

local function hint(from, to, text)
    return { p0 = pos(from), p1 = pos(to), t = text or "w", h = "hint" .. from }
end

local function newStore() return Store.new(cmp) end

local tests = {
    test("query returns the hints that start inside [a, b) in document order", function()
        local s = newStore()
        s:addRange(pos(0), pos(100), { hint(50, 51), hint(10, 11), hint(99, 100), hint(100, 101) })
        local got = s:query(pos(10), pos(100))
        assert.equal(#got, 3)
        assert.equal(got[1].p0, pos(10))
        assert.equal(got[3].p0, pos(99))
        assert.equal(#s:query(pos(10), nil), 4, "nil end means the end of the book")
    end),

    test("a hint at the same position replaces the old one", function()
        local s = newStore()
        s:addHint(hint(5, 6))
        s:addHint({ p0 = pos(5), p1 = pos(6), t = "w", h = "new" })
        assert.equal(s:count(), 1)
        assert.equal(s:query(pos(0), nil)[1].h, "new")
    end),

    test("covers: only completely analysed ranges", function()
        local s = newStore()
        s:addRange(pos(10), pos(20), {})
        assert.isTrue(s:covers(pos(10), pos(20)))
        assert.isTrue(s:covers(pos(12), pos(18)))
        assert.isFalse(s:covers(pos(5), pos(20)))
        assert.isFalse(s:covers(pos(10), pos(21)))
        assert.isFalse(s:covers(pos(10), nil), "a bounded range never covers the rest of the book")
    end),

    test("overlapping and touching ranges are merged", function()
        local s = newStore()
        s:addRange(pos(10), pos(20), {})
        s:addRange(pos(20), pos(30), {})
        s:addRange(pos(25), pos(40), {})
        assert.equal(#s.ranges, 1)
        assert.isTrue(s:covers(pos(10), pos(40)))
        s:addRange(pos(50), pos(60), {})
        assert.equal(#s.ranges, 2)
        assert.isFalse(s:covers(pos(40), pos(60)))
    end),

    test("a range without an end covers everything after its start", function()
        local s = newStore()
        s:addRange(pos(10), pos(20), {})
        s:addRange(pos(30), nil, {})
        assert.isTrue(s:covers(pos(30), nil))
        assert.isTrue(s:covers(pos(500), pos(900)))
        assert.isFalse(s:covers(pos(20), pos(30)))
        s:addRange(pos(20), pos(30), {})
        assert.equal(#s.ranges, 1)
        assert.isTrue(s:covers(pos(10), nil))
    end),

    test("evict forgets hints and coverage of the span only", function()
        local s = newStore()
        s:addRange(pos(0), pos(100), { hint(10, 11), hint(50, 51), hint(90, 91) })
        s:evict(pos(40), pos(60))
        assert.equal(s:count(), 2)
        assert.isTrue(s:covers(pos(0), pos(40)))
        assert.isTrue(s:covers(pos(60), pos(100)))
        assert.isFalse(s:covers(pos(40), pos(60)), "the evicted span is requested again")
        assert.isFalse(s:covers(pos(30), pos(70)))
    end),

    test("evict with open ends", function()
        local s = newStore()
        s:addRange(pos(0), nil, { hint(10, 11), hint(50, 51), hint(90, 91) })
        s:evict(nil, pos(20))
        assert.isFalse(s:covers(pos(0), pos(20)))
        assert.isTrue(s:covers(pos(20), nil))
        s:evict(pos(80), nil)
        assert.isFalse(s:covers(pos(80), pos(90)))
        assert.isTrue(s:covers(pos(20), pos(80)))
        assert.equal(s:count(), 1)
    end),

    test("trim below the limit does nothing", function()
        local s = newStore()
        s:addRange(pos(0), pos(100), { hint(10, 11), hint(20, 21) })
        assert.isFalse(s:trim(5, pos(0)))
        assert.equal(s:count(), 2)
        assert.equal(#s.ranges, 1)
    end),

    test("trim keeps the coverage around the reader (it used to wipe everything)", function()
        local s = newStore()
        local hints = {}
        for i = 1, 100 do hints[#hints + 1] = hint(i * 10, i * 10 + 1) end
        s:addRange(pos(0), nil, hints)
        -- reading near the start: the far end of the book goes
        assert.isTrue(s:trim(50, pos(100)))
        assert.isTrue(s:count() <= 50)
        assert.isTrue(s:count() >= 40, "only about a tenth of the limit is freed beyond the excess")
        assert.isTrue(s:covers(pos(0), pos(300)), "coverage near the reader stays")
        assert.isFalse(s:covers(pos(900), pos(1000)), "the forgotten end is requested again")
        assert.equal(#s:query(pos(0), pos(300)), 29, "hints near the reader stay")
    end),

    test("trim forgets the start of the book when the reader is near the end", function()
        local s = newStore()
        local hints = {}
        for i = 1, 100 do hints[#hints + 1] = hint(i * 10, i * 10 + 1) end
        s:addRange(pos(0), nil, hints)
        assert.isTrue(s:trim(50, pos(990)))
        assert.isFalse(s:covers(pos(0), pos(100)))
        assert.isTrue(s:covers(pos(800), nil))
        assert.equal(#s:query(pos(800), nil), 21)
    end),

    test("dump and load round-trip; a damaged snapshot is refused", function()
        local s = newStore()
        s:addRange(pos(0), pos(100), { hint(10, 11) })
        local back = Store.load(cmp, s:dump())
        assert.notNil(back)
        assert.equal(back:count(), 1)
        assert.isTrue(back:covers(pos(0), pos(100)))
        assert.equal(Store.load(cmp, { hints = { { p0 = 1 } }, ranges = {} }), nil)
        assert.equal(Store.load(cmp, { hints = {}, ranges = { { a = pos(1) } } }), nil)
        assert.equal(Store.load(cmp, "x"), nil)
    end),

    test("load validates sample positions with the caller's check", function()
        local s = newStore()
        s:addRange(pos(0), pos(100), { hint(10, 11) })
        local seen = {}
        local back = Store.load(cmp, s:dump(), function(p) seen[#seen + 1] = p; return true end)
        assert.notNil(back)
        assert.isTrue(#seen > 0)
        assert.equal(Store.load(cmp, s:dump(), function() return false end), nil)
    end),

    test("clear forgets hints and coverage", function()
        local s = newStore()
        s:addRange(pos(0), pos(100), { hint(10, 11) })
        s:clear()
        assert.equal(s:count(), 0)
        assert.isFalse(s:covers(pos(0), pos(100)))
    end),
}

return helper.runTests("wordwise_store", tests)
