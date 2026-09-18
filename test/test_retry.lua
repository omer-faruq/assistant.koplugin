-- test_retry.lua
-- Tests for the 429 retry mechanism in api_handlers/base.lua:
--   getMaxRetries / parseRetryAfter / isRetryable429 / getRetryDelay
--   and the makeRequest retry loop (with a mocked ASUtils.httpRequest).
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils

local BaseHandler = require("api_handlers.base")
local OpenAIHandler = require("api_handlers.openai")

-- Captured before the makeRequest tests replace the module field with stubs.
local realSleepWithInfo = ASUtils.sleepWithInfo

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Format an epoch timestamp as an RFC1123 HTTP-date (UTC).
local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local function formatHttpDate(epoch)
    local t = os.date("!*t", epoch)
    return string.format("%s, %02d %s %04d %02d:%02d:%02d GMT",
        DAYS[t.wday], t.day, MONTHS[t.month], t.year, t.hour, t.min, t.sec)
end

local function newHandler(additional_parameters)
    return BaseHandler:new{ name = "test", additional_parameters = additional_parameters or {} }
end

-- OpenAI-compatible handler: the only layer with detail.* proxy fallback,
-- so detail-wrapped 429 bodies are exercised here, not on the base default.
local function newOpenAIHandler(additional_parameters)
    return OpenAIHandler:new{ name = "test", additional_parameters = additional_parameters or {} }
end

-- Run fn(env) with the Trapper / UIManager / socket dependencies of
-- sleepWithInfo replaced by a deterministic simulation, then restore them.
-- `render` models the e-ink repaint cost inside Trapper:info.
local function withSleepEnv(render, fn)
    local Trapper = require("ui/trapper")
    local UIManager = require("ui/uimanager")
    local socket = require("socket")
    local saved = {
        gettime = socket.gettime,
        info = Trapper.info,
        clear = Trapper.clear,
        scheduleIn = UIManager.scheduleIn,
        unschedule = UIManager.unschedule,
    }
    local env = { now = 0, pending_at = nil, log = {}, cleared = false }
    socket.gettime = function() return env.now end
    UIManager.scheduleIn = function(_, delay) env.pending_at = env.now + delay end
    UIManager.unschedule = function() env.pending_at = nil end
    Trapper.info = function(_, text)
        env.log[#env.log + 1] = text
        env.now = env.now + render
        return true
    end
    Trapper.clear = function() env.cleared = true end
    local ok, err = pcall(fn, env)
    socket.gettime = saved.gettime
    Trapper.info = saved.info
    Trapper.clear = saved.clear
    UIManager.scheduleIn = saved.scheduleIn
    UIManager.unschedule = saved.unschedule
    if not ok then error(err, 0) end
    return env
end

local tests = {
    -- ------------------------------------------------------------------
    -- getMaxRetries
    -- ------------------------------------------------------------------
    test("getMaxRetries defaults to 8", function()
        assert.equal(newHandler():getMaxRetries(), 8)
    end),

    test("getMaxRetries honors additional_parameters.max_retries", function()
        assert.equal(newHandler{ max_retries = 3 }:getMaxRetries(), 3)
    end),

    test("getMaxRetries clamps to 0..8", function()
        assert.equal(newHandler{ max_retries = -5 }:getMaxRetries(), 0)
        assert.equal(newHandler{ max_retries = 99 }:getMaxRetries(), 8)
        assert.equal(newHandler{ max_retries = "abc" }:getMaxRetries(), 8)
    end),

    -- ------------------------------------------------------------------
    -- parseRetryAfter
    -- ------------------------------------------------------------------
    test("parseRetryAfter: retry-after-ms wins over retry-after", function()
        local h = newHandler()
        local delay = h:parseRetryAfter({ ["Retry-After"] = "120", ["retry-after-ms"] = "2500" }, "")
        assert.equal(delay, 2.5)
    end),

    test("parseRetryAfter: x-ms-retry-after-ms", function()
        local h = newHandler()
        local delay = h:parseRetryAfter({ ["x-ms-retry-after-ms"] = "5000" }, "")
        assert.equal(delay, 5)
    end),

    test("parseRetryAfter: retry-after delta-seconds", function()
        local h = newHandler()
        assert.equal(h:parseRetryAfter({ ["retry-after"] = "42" }, ""), 42)
    end),

    test("parseRetryAfter: retry-after HTTP-date in the future", function()
        local h = newHandler()
        local future = os.time() + 120
        local delay = h:parseRetryAfter({ ["retry-after"] = formatHttpDate(future) }, "")
        assert.isTrue(delay ~= nil and delay >= 119 and delay <= 121, "delay ~= " .. tostring(delay))
    end),

    test("parseRetryAfter: retry-after HTTP-date in the past clamps to 0", function()
        local h = newHandler()
        local past = os.time() - 60
        assert.equal(h:parseRetryAfter({ ["retry-after"] = formatHttpDate(past) }, ""), 0)
    end),

    test("parseRetryAfter: Gemini error.details[].retryDelay", function()
        local h = newHandler()
        local body = '{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"42s"}]}}'
        assert.equal(h:parseRetryAfter({}, body), 42)
    end),

    test("parseRetryAfter: error.message 'try again in Xs'", function()
        local h = newHandler()
        local body = '{"error":{"message":"Quota exceeded. Please try again in 7.5s."}}'
        assert.equal(h:parseRetryAfter({}, body), 7.5)
    end),

    test("parseRetryAfter: detail-wrapped 'try again in Xs'", function()
        local h = newOpenAIHandler()
        local body = '{"detail":{"error":{"message":"Busy. Please try again in 3s."}}}'
        assert.equal(h:parseRetryAfter({}, body), 3)
    end),

    test("parseRetryAfter: accepts an already-decoded table body", function()
        local h = newHandler()
        local body = { error = { message = "Please try again in 3s." } }
        assert.equal(h:parseRetryAfter({}, body), 3)
    end),

    test("parseRetryAfter: returns nil when nothing is present", function()
        local h = newHandler()
        assert.equal(h:parseRetryAfter({}, ""), nil)
        assert.equal(h:parseRetryAfter({ ["content-type"] = "application/json" }, "not json"), nil)
    end),

    -- ------------------------------------------------------------------
    -- isRetryable429
    -- ------------------------------------------------------------------
    test("isRetryable429: plain 429 is retryable", function()
        local h = newHandler()
        assert.isTrue(h:isRetryable429(429, {}, ""))
        assert.isTrue(h:isRetryable429("429", {}, ""))
    end),

    test("isRetryable429: non-429 is never retryable", function()
        local h = newHandler()
        assert.isFalse(h:isRetryable429(500, {}, ""))
        assert.isFalse(h:isRetryable429(200, {}, ""))
    end),

    test("isRetryable429: x-should-retry:false is not retryable", function()
        local h = newHandler()
        assert.isFalse(h:isRetryable429(429, { ["x-should-retry"] = "false" }, ""))
        assert.isTrue(h:isRetryable429(429, { ["x-should-retry"] = "true" }, ""))
    end),

    test("isRetryable429: insufficient_quota is not retryable", function()
        local h = newHandler()
        local body = '{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}'
        assert.isFalse(h:isRetryable429(429, {}, body))
    end),

    test("isRetryable429: billing_hard_limit_reached is not retryable", function()
        local h = newHandler()
        local body = '{"error":{"code":"billing_hard_limit_reached","message":"Billing hard limit"}}'
        assert.isFalse(h:isRetryable429(429, {}, body))
    end),

    test("isRetryable429: quotaExceeded with explicit daily exhaustion is not retryable", function()
        local h = newHandler()
        local body = '{"error":{"code":"quotaExceeded","message":"Daily limit exceeded for this model"}}'
        assert.isFalse(h:isRetryable429(429, {}, body))
    end),

    test("isRetryable429: RESOURCE_EXHAUSTED with quota wording is not retryable", function()
        local h = newHandler()
        local body = '{"error":{"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded"}}'
        assert.isFalse(h:isRetryable429(429, {}, body))
    end),

    test("isRetryable429: quotaExceeded without daily/quota wording stays retryable", function()
        local h = newHandler()
        local body = '{"error":{"code":"quotaExceeded","message":"Too many concurrent requests"}}'
        assert.isTrue(h:isRetryable429(429, {}, body))
    end),

    -- ------------------------------------------------------------------
    -- getRetryDelay
    -- ------------------------------------------------------------------
    test("getRetryDelay: retry-after is capped at 5s", function()
        local h = newHandler()
        local info = h:getRetryDelay(429, { ["retry-after"] = "10" }, "", 1)
        assert.isTrue(info.retryable)
        assert.equal(info.delay, 5)
        assert.equal(info.reason, "retry-after")
    end),

    test("getRetryDelay: backoff fallback stays within jitter range", function()
        local h = newHandler()
        local info = h:getRetryDelay(429, {}, "", 1)
        assert.isTrue(info.retryable)
        assert.equal(info.reason, "backoff")
        assert.isTrue(info.delay >= 0.75 and info.delay <= 1.25, "delay ~= " .. tostring(info.delay))
    end),

    test("getRetryDelay: backoff caps at 5s", function()
        local h = newHandler()
        local info = h:getRetryDelay(429, {}, "", 10)
        assert.isTrue(info.delay >= 3.75 and info.delay <= 5, "delay ~= " .. tostring(info.delay))
    end),

    test("getRetryDelay: small retry-after still backs off progressively", function()
        local h = newHandler()
        -- Retry-After:1 alone would finish 8 retries in 8s; backoff must lift it.
        local info = h:getRetryDelay(429, { ["retry-after"] = "1" }, "", 5)
        assert.isTrue(info.retryable)
        assert.equal(info.reason, "backoff")
        -- attempt 5 backoff base 5s +/-25% clamped to 5 => 3.75..5s
        assert.isTrue(info.delay >= 3.75 and info.delay <= 5, "delay ~= " .. tostring(info.delay))
    end),

    test("getRetryDelay: large retry-after is capped at 5s", function()
        local h = newHandler()
        local info = h:getRetryDelay(429, { ["retry-after"] = "30" }, "", 1)
        assert.isTrue(info.retryable)
        assert.equal(info.delay, 5)
        assert.equal(info.reason, "retry-after")
    end),

    test("getRetryDelay: zero server hint falls back to backoff", function()
        local h = newHandler()
        local past = os.time() - 60
        local info = h:getRetryDelay(429, { ["retry-after"] = formatHttpDate(past) }, "", 1)
        assert.isTrue(info.retryable)
        assert.equal(info.reason, "backoff")
        assert.isTrue(info.delay >= 0.75 and info.delay <= 1.25, "delay ~= " .. tostring(info.delay))
    end),

    test("getRetryDelay: non-retryable 429 returns retryable=false", function()
        local h = newHandler()
        local info = h:getRetryDelay(429, {}, '{"error":{"code":"insufficient_quota"}}', 1)
        assert.isFalse(info.retryable)
    end),

    -- ------------------------------------------------------------------
    -- makeRequest retry loop (mocked httpRequest + sleepWithInfo)
    -- ------------------------------------------------------------------
    test("makeRequest: retries 429 then succeeds", function()
        local h = newHandler()
        local calls = 0
        local responses = {
            { success = true, code = 429, content = '{"error":{"message":"busy"}}', headers = { ["retry-after"] = "1" } },
            { success = true, code = 429, content = '{"error":{"message":"busy"}}', headers = { ["retry-after"] = "1" } },
            { success = true, code = 200, content = '{"ok":true}', headers = {} },
        }
        ASUtils.httpRequest = function()
            calls = calls + 1
            local r = responses[calls]
            return r.success, r.code, r.content, r.headers
        end
        ASUtils.sleepWithInfo = function() return true end
        local success, code, content = h:makeRequest("https://x", {}, "{}")
        assert.equal(calls, 3)
        assert.isTrue(success)
        assert.equal(code, 200)
        assert.equal(content, '{"ok":true}')
    end),

    test("makeRequest: exhausts retries and returns final 429 as error", function()
        local h = newHandler{ max_retries = 2 }
        local calls = 0
        ASUtils.httpRequest = function()
            calls = calls + 1
            return true, 429, '{"error":{"message":"busy"}}', { ["retry-after"] = "1" }
        end
        ASUtils.sleepWithInfo = function() return true end
        local success, code, content = h:makeRequest("https://x", {}, "{}")
        assert.equal(calls, 3) -- 1 initial + 2 retries
        assert.isFalse(success)
        assert.equal(code, 429)
        assert.matches(content, "busy")
    end),

    test("makeRequest: max_retries=0 disables retry", function()
        local h = newHandler{ max_retries = 0 }
        local calls = 0
        ASUtils.httpRequest = function()
            calls = calls + 1
            return true, 429, '{"error":{"message":"busy"}}', {}
        end
        local success, code = h:makeRequest("https://x", {}, "{}")
        assert.equal(calls, 1)
        assert.isFalse(success)
        assert.equal(code, 429)
    end),

    test("makeRequest: non-retryable 429 returns immediately", function()
        local h = newHandler()
        local calls = 0
        ASUtils.httpRequest = function()
            calls = calls + 1
            return true, 429, '{"error":{"code":"insufficient_quota"}}', {}
        end
        local success, code = h:makeRequest("https://x", {}, "{}")
        assert.equal(calls, 1)
        assert.isFalse(success)
        assert.equal(code, 429)
    end),

    test("makeRequest: user cancellation during wait returns CODE_CANCELLED", function()
        local h = newHandler()
        local calls = 0
        ASUtils.httpRequest = function()
            calls = calls + 1
            return true, 429, '{"error":{"message":"busy"}}', { ["retry-after"] = "1" }
        end
        ASUtils.sleepWithInfo = function() return false end -- user cancels
        local success, code, content = h:makeRequest("https://x", {}, "{}")
        assert.equal(calls, 1)
        assert.isFalse(success)
        assert.equal(code, BaseHandler.CODE_CANCELLED)
        assert.equal(content, BaseHandler.CODE_CANCELLED)
    end),

    test("makeRequest: non-429 error passes through unchanged", function()
        local h = newHandler()
        local calls = 0
        ASUtils.httpRequest = function()
            calls = calls + 1
            return false, BaseHandler.CODE_TIMEOUT, "timed out", nil
        end
        local success, code, content = h:makeRequest("https://x", {}, "{}")
        assert.equal(calls, 1)
        assert.isFalse(success)
        assert.equal(code, BaseHandler.CODE_TIMEOUT)
        assert.equal(content, "timed out")
    end),

    -- ------------------------------------------------------------------
    -- extractRetryDetail + sleepWithRetryInfo display
    -- ------------------------------------------------------------------
    test("extractRetryDetail: prefers error.message from JSON", function()
        local h = newHandler()
        local d = h:extractRetryDetail('{"error":{"message":"Rate limit reached, slow down."}}')
        assert.equal(d, "Rate limit reached, slow down.")
    end),

    test("extractRetryDetail: unwraps detail.error.message proxy wrapper", function()
        local h = newOpenAIHandler()
        local body = '{"detail":{"error":{"message":"Model \'DeepSeek-V4-Flash\' is at its concurrency limit (80)","type":"rate_limit_error"}}}'
        local d = h:extractRetryDetail(body)
        assert.notNil(d)
        assert.matches(d, "concurrency limit")
        assert.isTrue(h:isRetryable429(429, {}, body))
    end),

    test("extractRetryDetail: unwraps detail.message and string detail", function()
        local h = newOpenAIHandler()
        assert.matches(h:extractRetryDetail('{"detail":{"message":"slow down"}}'), "slow down")
        assert.matches(h:extractRetryDetail('{"detail":"just slow down"}'), "just slow down")
    end),

    test("extractRetryDetail: falls back to raw text and truncates", function()
        local h = newHandler()
        assert.equal(h:extractRetryDetail(nil), nil)
        assert.equal(h:extractRetryDetail(""), nil)
        local long = string.rep("x", 300)
        local d = h:extractRetryDetail(long)
        assert.equal(#d, 203) -- 200 chars + "..."
        assert.matches(d, "%.%.%.$")
        -- multi-line collapses to one line, bold markers stripped
        local multi = h:extractRetryDetail("line1\n  line2\n<b>hi</b>")
        assert.equal(multi, "line1 line2 hi")
    end),

    -- ------------------------------------------------------------------
    -- sleepWithInfo wall-clock countdown
    -- ------------------------------------------------------------------
    test("sleepWithInfo: template without %d keeps the legacy suffix", function()
        local env = withSleepEnv(0.8, function(e)
            local co = coroutine.create(function() return realSleepWithInfo(5, "Busy") end)
            local _, finished = coroutine.resume(co)
            while coroutine.status(co) == "suspended" do
                assert.notNil(e.pending_at, "expected a scheduled resume")
                e.now = e.pending_at
                e.pending_at = nil
                _, finished = coroutine.resume(co, true)
            end
            e.finished = finished
        end)
        assert.isTrue(env.finished)
        assert.equal(table.concat(env.log, ","), "Busy (5),Busy (4),Busy (3),Busy (2),Busy (1)")
        assert.equal(env.now, 5)
    end),

    test("sleepWithInfo: template %d is filled each tick", function()
        local env = withSleepEnv(0.8, function(e)
            local co = coroutine.create(function() return realSleepWithInfo(5, "Busy (%d)") end)
            local _, finished = coroutine.resume(co)
            while coroutine.status(co) == "suspended" do
                assert.notNil(e.pending_at, "expected a scheduled resume")
                e.now = e.pending_at
                e.pending_at = nil
                _, finished = coroutine.resume(co, true)
            end
            e.finished = finished
        end)
        assert.isTrue(env.finished)
        assert.equal(table.concat(env.log, ","), "Busy (5),Busy (4),Busy (3),Busy (2),Busy (1)")
        assert.equal(env.now, 5)
    end),

    test("sleepWithInfo: tap cancels before the countdown ends", function()
        local env = withSleepEnv(0, function(e)
            local co = coroutine.create(function() return realSleepWithInfo(5, "Busy") end)
            coroutine.resume(co)
            assert.notNil(e.pending_at)
            -- A tap dismisses the InfoMessage, resuming the coroutine with false.
            local _, cancelled = coroutine.resume(co, false)
            e.cancelled = cancelled
        end)
        assert.isFalse(env.cancelled)
        assert.isTrue(env.cleared)
    end),

    test("sleepWithRetryInfo: shows API detail when present", function()
        local h = newHandler()
        local captured = nil
        ASUtils.sleepWithInfo = function(_, text) captured = text return true end
        h:sleepWithRetryInfo(1, 2, 8, "Rate limit abc")
        assert.notNil(captured)
        assert.matches(captured, "API Busy")
        assert.matches(captured, "Rate limit abc")
        assert.notNil(captured:find("%d", 1, true), "countdown placeholder belongs to the caller template")
        captured = nil
        h:sleepWithRetryInfo(1, 2, 8, nil)
        assert.notNil(captured)
        assert.matches(captured, "API Busy")
        assert.notMatches(captured, "Rate limit abc")
    end),
}

return helper.runTests("assistant_retry", tests)