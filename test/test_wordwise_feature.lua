-- test_wordwise_feature.lua
-- feature/wordwise: the behaviour that is decided inside the feature module itself —
-- the cache key, going offline with the default source, trimming a long book's hints
-- without losing the coverage, and the background cache write. The module is exercised
-- through a stand-in `self` that has the real methods but no reader around it.
local helper = require("test.helper")
local assert = helper.assert
local WordWise = require("feature/wordwise")
local Store = require("utils/wordwise_store")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")

-- The suite's UIManager is a mock: add the scheduling calls this module makes.
for _i, name in ipairs({ "unschedule", "scheduleIn", "nextTick" }) do
    if UIManager[name] == nil then UIManager[name] = function() end end
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local function pos(n) return string.format("%06d", n) end

local function cmp(a, b)
    if a == nil or b == nil then return nil end
    if a == b then return 0 end
    return a < b and 1 or -1
end

-- A WordWise with every outside dependency replaced by a plain value or recorder.
local function fake(overrides)
    local calls = {}
    local o = {
        running = true,
        sig = "sig",
        active = {},
        retry_at = 0,
        store = Store.new(cmp),
        calls = calls,
    }
    local stubs = {
        isEnabled = function() return true end,
        signature = function(self) return self.sig end,
        settingsOpen = function() return false end,
        isUserBusy = function() return false end,
        pagedBlocked = function() return false end,
        source = function() return "auto" end,
        isOnline = function() return false end,
        hasProvider = function() return true end,
        dictionaryServes = function() return false end,
        planDictionary = function() calls[#calls + 1] = "planDictionary" end,
        handleOffline = function() calls[#calls + 1] = "handleOffline" end,
        schedulePlan = function() calls[#calls + 1] = "schedulePlan" end,
        abortAll = function() calls[#calls + 1] = "abortAll" end,
    }
    for k, v in pairs(overrides or {}) do stubs[k] = v end
    return setmetatable(o, { __index = function(_t, k)
        if stubs[k] ~= nil then return stubs[k] end
        return WordWise[k]
    end })
end

local tests = {
    test("signature changes with the maximum hint length (it is part of the prompt)", function()
        local settings = { level = "B2", lang = "en", density = "medium", style = "synonym", max_chars = 20, all = false }
        local function sig()
            return WordWise.signature({
                cfg = function(_self, key) return settings[key] end,
                modelId = function() return "model" end,
            })
        end
        local before = sig()
        settings.max_chars = 30
        assert.isTrue(sig() ~= before, "a new length must fetch the hints again")
        settings.max_chars = 20
        assert.equal(sig(), before)
        settings.density = "high"
        assert.isTrue(sig() ~= before)
    end),

    test("auto: offline with no dictionary prompts for the network", function()
        local w = fake()
        WordWise.plan(w)
        assert.equal(w.calls[1], "handleOffline")
        assert.equal(#w.calls, 1)
    end),

    test("auto: offline with a dictionary that serves the book uses it, no prompt", function()
        local w = fake({ dictionaryServes = function() return true end })
        WordWise.plan(w)
        assert.equal(w.calls[1], "planDictionary")
        assert.equal(#w.calls, 1)
    end),

    test("auto: offline with a dictionary that cannot read this book still prompts", function()
        -- dictionaryServes is false for a book in another language
        local w = fake({ dictionaryServes = function() return false end })
        WordWise.plan(w)
        assert.equal(w.calls[1], "handleOffline")
    end),

    test("auto: no AI provider falls back to the dictionary path", function()
        local w = fake({ hasProvider = function() return false end })
        WordWise.plan(w)
        assert.equal(w.calls[1], "planDictionary")
    end),

    test("auto: while the AI is backing off without a dictionary, the plan is rescheduled", function()
        local w = fake({ isOnline = function() return true end })
        w.retry_at = os.time() + 60
        WordWise.plan(w)
        assert.equal(w.calls[1], "schedulePlan")
        assert.equal(#w.calls, 1)
    end),

    test("source offline always goes to the dictionary", function()
        local w = fake({ source = function() return "offline" end })
        WordWise.plan(w)
        assert.equal(w.calls[1], "planDictionary")
    end),

    test("source AI: offline prompts for the network", function()
        local w = fake({ source = function() return "ai" end })
        WordWise.plan(w)
        assert.equal(w.calls[1], "handleOffline")
    end),

    test("a finished page over the limit is trimmed, not wiped", function()
        local hints = {}
        for i = 1, 1000 do hints[#hints + 1] = { p0 = pos(i * 10), p1 = pos(i * 10 + 1), t = "w", h = "h" } end
        local w = fake({
            pageRange = function() return pos(5000), pos(5100) end,
            currentPage = function() return 1 end,
            markCacheDirty = function() end,
            checkPrepare = function() end,
            invalidateLayout = function() end,
            refresh = function() end,
            pump = function() end,
        })
        w.store:addRange(pos(0), nil, hints)
        local limit = WordWise.MAX_HINTS_PER_BOOK
        assert.notNil(limit, "the limit is exposed for the tests")
        -- pretend the book is already at the limit: lower it for the test
        WordWise.MAX_HINTS_PER_BOOK = 800
        local ok, err = pcall(WordWise.applyResult, w, { a = pos(10000), b = pos(10100) }, {})
        WordWise.MAX_HINTS_PER_BOOK = limit
        assert.isTrue(ok, tostring(err))
        assert.isTrue(w.store:count() <= 800)
        assert.isTrue(w.store:count() > 600, "most hints stay")
        assert.isTrue(w.store:covers(pos(4000), pos(5100)), "coverage around the reader stays")
    end),

    test("the cache is written from a background process and read back intact", function()
        local path = os.tmpname()
        os.remove(path)
        local ls = LuaSettings:open(path)
        local w = fake({ markCacheDirty = function() end })
        w.cache_ls = ls
        w.cache_dirty, w.store_dirty = true, true
        w.sig = "variant"
        w.store:addRange(pos(0), pos(100), { { p0 = pos(10), p1 = pos(11), t = "word", h = "hint" } })
        w.flush_fn = function() end
        w.watch_fn = function() end
        WordWise.flushCacheAsync(w)
        assert.isFalse(w.cache_dirty, "marked clean as soon as the writer is started")
        WordWise.waitFlush(w)
        local back = LuaSettings:open(path)
        local stores = back:readSetting("stores")
        assert.notNil(stores, "the file was written by the child process")
        assert.notNil(stores.variant)
        assert.equal(#stores.variant.hints, 1)
        assert.equal(stores.variant.hints[1].h, "hint")
        os.remove(path)
        os.remove(path .. ".old")
    end),

    test("flushCache writes on the calling thread and leaves nothing dirty", function()
        local path = os.tmpname()
        os.remove(path)
        local w = fake()
        w.cache_ls = LuaSettings:open(path)
        w.cache_dirty, w.store_dirty = true, true
        w.sig = "variant"
        w.flush_fn = function() end
        w.store:addRange(pos(0), pos(100), {})
        WordWise.flushCache(w)
        assert.isFalse(w.cache_dirty)
        assert.notNil(LuaSettings:open(path):readSetting("stores").variant)
        os.remove(path)
        os.remove(path .. ".old")
    end),
}

return helper.runTests("wordwise_feature", tests)
