-- test_handler_timeouts.lua
-- Tests for per-provider HTTP timeout resolution in api_handlers/base.lua.
--
-- Providers may set optional `timeout` / `maxtime` keys in their
-- provider_settings entry; BaseHandler:SyncOptions merges every key of that
-- entry onto the handler instance, so they arrive as self.timeout / self.maxtime.
-- BaseHandler:resolveTimeouts owns the precedence rule:
--     explicit argument  >  provider config  >  built-in default
local helper = require("test.test_helper")
local assert = helper.assert

local BaseHandler = require("api_handlers.base")
local ASUtils = require("assistant_utils")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Build a bare handler instance carrying the given provider config keys.
local function handler(provider_config)
    local h = BaseHandler:new(provider_config or {})
    return h
end

-- Call makeRequest with ASUtils.httpRequest swapped out, and return the
-- (timeout, maxtime) it was invoked with.
local function captureRequestTimeouts(h, body)
    local captured = {}
    local original = ASUtils.httpRequest
    ASUtils.httpRequest = function(url, timeout, maxtime)
        captured.timeout = timeout
        captured.maxtime = maxtime
        return true, 200, "{}"
    end
    local ok, err = pcall(function()
        h:makeRequest("https://example.invalid/v1/chat/completions", {}, body)
    end)
    ASUtils.httpRequest = original
    if not ok then error(err) end
    return captured.timeout, captured.maxtime
end

local tests = {

    -- =========================================================================
    -- resolveTimeouts: precedence
    -- =========================================================================

    test("resolveTimeouts: falls back to defaults when nothing is configured", function()
        local block, total = handler():resolveTimeouts(nil, nil, 45, 120)
        assert.equal(block, 45, "block timeout should be the default")
        assert.equal(total, 120, "total timeout should be the default")
    end),

    test("resolveTimeouts: provider config overrides defaults", function()
        local block, total = handler({ timeout = 120, maxtime = 900 })
                                :resolveTimeouts(nil, nil, 45, 120)
        assert.equal(block, 120)
        assert.equal(total, 900)
    end),

    test("resolveTimeouts: explicit arguments override provider config", function()
        local block, total = handler({ timeout = 120, maxtime = 900 })
                                :resolveTimeouts(10, 20, 45, 120)
        assert.equal(block, 10, "explicit timeout wins over provider config")
        assert.equal(total, 20, "explicit maxtime wins over provider config")
    end),

    -- =========================================================================
    -- resolveTimeouts: the two values resolve independently
    -- =========================================================================

    test("resolveTimeouts: timeout-only provider config keeps the default maxtime", function()
        local block, total = handler({ timeout = 300 }):resolveTimeouts(nil, nil, 45, 120)
        assert.equal(block, 300)
        assert.equal(total, 120, "unset maxtime should still fall back to the default")
    end),

    test("resolveTimeouts: maxtime-only provider config keeps the default timeout", function()
        local block, total = handler({ maxtime = 900 }):resolveTimeouts(nil, nil, 45, 120)
        assert.equal(block, 45, "unset timeout should still fall back to the default")
        assert.equal(total, 900, "maxtime must survive on its own")
    end),

    test("resolveTimeouts: explicit timeout does not discard a configured maxtime", function()
        -- Regression guard for the old `if not timeout then ... end` style guard
        -- that assigned both values together.
        local block, total = handler({ maxtime = 900 }):resolveTimeouts(30, nil, 45, 120)
        assert.equal(block, 30)
        assert.equal(total, 900)
    end),

    -- =========================================================================
    -- resolveTimeouts: nil default (streaming has no total cap by default)
    -- =========================================================================

    test("resolveTimeouts: nil default total stays nil when unconfigured", function()
        local block, total = handler():resolveTimeouts(nil, nil, 120, nil)
        assert.equal(block, 120)
        assert.isTrue(total == nil, "streaming must not get a total cap by default")
    end),

    test("resolveTimeouts: nil default total is filled by provider config", function()
        local block, total = handler({ maxtime = 600 }):resolveTimeouts(nil, nil, 120, nil)
        assert.equal(block, 120)
        assert.equal(total, 600)
    end),

    -- =========================================================================
    -- resolveTimeouts: invalid provider values fall through
    -- =========================================================================

    test("resolveTimeouts: string values are rejected", function()
        local block, total = handler({ timeout = "120", maxtime = "900" })
                                :resolveTimeouts(nil, nil, 45, 120)
        assert.equal(block, 45, "a quoted number must not reach the socket layer")
        assert.equal(total, 120)
    end),

    test("resolveTimeouts: zero and negative values are rejected", function()
        local block, total = handler({ timeout = 0, maxtime = -1 })
                                :resolveTimeouts(nil, nil, 45, 120)
        assert.equal(block, 45)
        assert.equal(total, 120)
    end),

    test("resolveTimeouts: boolean and table values are rejected", function()
        local block, total = handler({ timeout = true, maxtime = {} })
                                :resolveTimeouts(nil, nil, 45, 120)
        assert.equal(block, 45)
        assert.equal(total, 120)
    end),

    -- =========================================================================
    -- makeRequest: default matrix and provider override
    -- =========================================================================

    test("makeRequest: small body uses the 45/120 defaults", function()
        local h = handler()
        h.trap_widget = {}
        local timeout, maxtime = captureRequestTimeouts(h, string.rep("x", 100))
        assert.equal(timeout, 45)
        assert.equal(maxtime, 120)
    end),

    test("makeRequest: large body uses the 300/120 defaults", function()
        local h = handler()
        h.trap_widget = {}
        local timeout, maxtime = captureRequestTimeouts(h, string.rep("x", 10001))
        assert.equal(timeout, 300)
        assert.equal(maxtime, 120)
    end),

    test("makeRequest: provider config overrides the defaults", function()
        local h = handler({ timeout = 120, maxtime = 900 })
        h.trap_widget = {}
        local timeout, maxtime = captureRequestTimeouts(h, string.rep("x", 100))
        assert.equal(timeout, 120)
        assert.equal(maxtime, 900)
    end),

    test("makeRequest: provider config applies without a trap widget too", function()
        local h = handler({ timeout = 120, maxtime = 900 })
        local timeout, maxtime = captureRequestTimeouts(h, string.rep("x", 100))
        assert.equal(timeout, 120)
        assert.equal(maxtime, 900)
    end),

    test("makeRequest: no trap widget falls back to the 20/45 defaults", function()
        local timeout, maxtime = captureRequestTimeouts(handler(), string.rep("x", 100))
        assert.equal(timeout, 20)
        assert.equal(maxtime, 45)
    end),
}

return helper.runTests("handler_timeouts", tests)
