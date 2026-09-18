-- test_error_message.lua
-- Tests for the shared ASUtils.extractErrorMessage helper (assistant_utils.lua):
-- single implementation every module must use instead of hand-rolled chains.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils

local BaseHandler = require("api_handlers.base")

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("extractErrorMessage: error.message wins", function()
        local d = ASUtils.extractErrorMessage('{"error":{"message":"boom"},"message":"ignored"}')
        assert.equal(d, "boom")
    end),

    test("extractErrorMessage: flat string error", function()
        assert.equal(ASUtils.extractErrorMessage('{"error":"flat bad"}'), "flat bad")
    end),

    test("extractErrorMessage: unwraps detail.error.message", function()
        local body = '{"detail":{"error":{"message":"concurrency limit (80)","type":"rate_limit_error"}}}'
        assert.equal(ASUtils.extractErrorMessage(body), "concurrency limit (80)")
    end),

    test("extractErrorMessage: unwraps detail.message and string detail", function()
        assert.equal(ASUtils.extractErrorMessage('{"detail":{"message":"slow"}}'), "slow")
        assert.equal(ASUtils.extractErrorMessage('{"detail":"just slow"}'), "just slow")
    end),

    test("extractErrorMessage: bare message", function()
        assert.equal(ASUtils.extractErrorMessage('{"message":"bare"}'), "bare")
    end),

    test("extractErrorMessage: accepts an already-decoded table", function()
        assert.equal(ASUtils.extractErrorMessage({ error = { message = "tab" } }), "tab")
        assert.equal(ASUtils.extractErrorMessage({ detail = { error = { message = "deep" } } }), "deep")
    end),

    test("extractErrorMessage: nil/empty/garbage returns nil", function()
        assert.equal(ASUtils.extractErrorMessage(nil), nil)
        assert.equal(ASUtils.extractErrorMessage(""), nil)
        assert.equal(ASUtils.extractErrorMessage("not json"), nil)
        assert.equal(ASUtils.extractErrorMessage('{"ok":true}'), nil)
        assert.equal(ASUtils.extractErrorMessage('{"error":{"code":429}}'), nil)
    end),

    test("extractErrorMessage: numeric message becomes string", function()
        assert.equal(ASUtils.extractErrorMessage('{"error":{"message":429}}'), "429")
    end),

    test("prefixHttpCode: numeric code adds prefix", function()
        assert.equal(BaseHandler.prefixHttpCode(400, "Bad Request"), "[400] Bad Request")
        assert.equal(BaseHandler.prefixHttpCode(500, "oops"), "[500] oops")
    end),

    test("prefixHttpCode: string digit code adds prefix", function()
        assert.equal(BaseHandler.prefixHttpCode("429", "slow"), "[429] slow")
    end),

    test("prefixHttpCode: USER_CANCELED passes through", function()
        assert.equal(BaseHandler.prefixHttpCode("USER_CANCELED", "bye"), "bye")
    end),

    test("prefixHttpCode: missing/non-numeric code gets [0]", function()
        assert.equal(BaseHandler.prefixHttpCode(nil, "timeout"), "[0] timeout")
        assert.equal(BaseHandler.prefixHttpCode("NETWORK_ERROR", "down"), "[0] down")
        assert.equal(BaseHandler.prefixHttpCode("wantread", "socket fail"), "[0] socket fail")
    end),

    test("prefixHttpCode: already prefixed is idempotent", function()
        assert.equal(BaseHandler.prefixHttpCode(500, "[400] Bad Request"), "[400] Bad Request")
        assert.equal(BaseHandler.prefixHttpCode(nil, "[0] timeout"), "[0] timeout")
    end),

    test("prefixHttpCode: non-string msg returned as-is", function()
        assert.equal(BaseHandler.prefixHttpCode(400, nil), nil)
        assert.equal(BaseHandler.prefixHttpCode(400, 42), 42)
    end),
}

return helper.runTests("assistant_error_message", tests)
