-- test_retry.lua
-- Tests for the 429 retry mechanism in api_handlers/base.lua:
--   getMaxRetries / parseRetryAfter / isRetryable429 / getRetryDelay
--   and the makeRequest retry loop (with a mocked ASUtils.httpRequest).
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils

local BaseHandler = require("api_handlers.base")

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
    test("getRetryDelay: uses retry-after without jitter", function()
        local h = newHandler()
        local info = h:getRetryDelay(429, { ["retry-after"] = "10" }, "", 1)
        assert.isTrue(info.retryable)
        assert.equal(info.delay, 10)
        assert.equal(info.reason, "retry-after")
    end),

    test("getRetryDelay: backoff fallback stays within jitter range", function()
        local h = newHandler()
        local info = h:getRetryDelay(429, {}, "", 1)
        assert.isTrue(info.retryable)
        assert.equal(info.reason, "backoff")
        assert.isTrue(info.delay >= 0.75 and info.delay <= 1.25, "delay ~= " .. tostring(info.delay))
    end),

    test("getRetryDelay: backoff caps at 60s", function()
        local h = newHandler()
        local info = h:getRetryDelay(429, {}, "", 10)
        assert.isTrue(info.delay >= 45 and info.delay <= 75, "delay ~= " .. tostring(info.delay))
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
}

return helper.runTests("assistant_retry", tests)