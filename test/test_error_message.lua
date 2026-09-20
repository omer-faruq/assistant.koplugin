-- test_error_message.lua
-- Tests for the extractErrorMessage implementations:
-- NetUtils.extractErrorMessage owns the canonical default (error.message >
-- flat error > detail.* proxy fallback > bare message, plus the machine-code
-- TAG suffix); BaseHandler delegates to it. OpenAIHandler alone keeps its own
-- override (same message chain, plain human text, no TAG).
local helper = require("test.helper")
local assert = helper.assert
local NetUtils = helper.NetUtils

local BaseHandler = require("api_handlers.base")
local OpenAIHandler = require("api_handlers.openai")
local AnthropicHandler = require("api_handlers.anthropic")
local GeminiHandler = require("api_handlers.gemini")
local ResponsesHandler = require("api_handlers.responses")

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
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

    test("base default: error.message wins over bare message", function()
        local h = BaseHandler:new{}
        assert.equal(h:extractErrorMessage('{"error":{"message":"boom"},"message":"ignored"}'), "boom")
    end),

    test("base default: flat string error and bare message", function()
        local h = BaseHandler:new{}
        assert.equal(h:extractErrorMessage('{"error":"flat bad"}'), "flat bad")
        assert.equal(h:extractErrorMessage('{"message":"bare"}'), "bare")
        assert.equal(h:extractErrorMessage('{"error":{"message":429}}'), "429")
    end),

    test("base default: machine-code suffix from top error object", function()
        local h = BaseHandler:new{}
        assert.equal(h:extractErrorMessage('{"error":{"message":"boom","type":"invalid_request_error"}}'), "boom [invalid_request_error]")
        assert.equal(h:extractErrorMessage('{"error":{"message":"x","status":"INVALID_ARGUMENT","code":400}}'), "x [INVALID_ARGUMENT/400]")
        assert.equal(h:extractErrorMessage('{"error":{"message":"x","code":400,"status":400}}'), "x [400]")
        assert.equal(h:extractErrorMessage('{"error":{"message":"x"},"status":"NOT_FOUND"}'), "x [NOT_FOUND]")
    end),

    test("base default: detail proxy fallback (no TAG on detail bodies)", function()
        local h = BaseHandler:new{}
        assert.equal(h:extractErrorMessage('{"detail":{"error":{"message":"proxied"}}}'), "proxied")
        assert.equal(h:extractErrorMessage('{"detail":{"message":"slow"}}'), "slow")
        assert.equal(h:extractErrorMessage('{"detail":"just slow"}'), "just slow")
        assert.equal(h:extractErrorMessage('{"detail":{"error":"flat proxied"}}'), "flat proxied")
        assert.equal(NetUtils.extractErrorMessage('{"detail":{"error":{"message":"proxied"}}}'), "proxied")
        assert.equal(NetUtils.extractErrorMessage('{"error":{"message":"boom","type":"invalid_request_error"}}'), "boom [invalid_request_error]")
    end),

    test("base default: nil/empty/garbage returns nil", function()
        local h = BaseHandler:new{}
        assert.equal(h:extractErrorMessage(nil), nil)
        assert.equal(h:extractErrorMessage(""), nil)
        assert.equal(h:extractErrorMessage("not json"), nil)
        assert.equal(h:extractErrorMessage('{"ok":true}'), nil)
    end),

    test("openai: native error.message", function()
        local h = OpenAIHandler:new{}
        assert.equal(h:extractErrorMessage('{"error":{"message":"boom"}}'), "boom")
        assert.equal(h:extractErrorMessage({ error = { message = "tab" } }), "tab")
    end),

    test("openai: detail proxy fallback", function()
        local h = OpenAIHandler:new{}
        assert.equal(h:extractErrorMessage('{"detail":{"error":{"message":"concurrency limit (80)"}}}'), "concurrency limit (80)")
        assert.equal(h:extractErrorMessage('{"detail":{"message":"slow"}}'), "slow")
        assert.equal(h:extractErrorMessage('{"detail":"just slow"}'), "just slow")
        assert.equal(h:extractErrorMessage('{"detail":{"error":"flat proxied"}}'), "flat proxied")
    end),

    test("openai: native wins over detail proxy", function()
        local h = OpenAIHandler:new{}
        local body = '{"error":{"message":"native"},"detail":{"error":{"message":"proxied"}}}'
        assert.equal(h:extractErrorMessage(body), "native")
    end),

    test("openai: ignores machine-code fields, returns plain message", function()
        local h = OpenAIHandler:new{}
        assert.equal(h:extractErrorMessage('{"error":{"message":"boom","type":"invalid_request_error"}}'), "boom")
        assert.equal(h:extractErrorMessage('{"error":{"message":"bad","type":"invalid_request_error","code":"invalid_api_key"}}'), "bad")
        assert.equal(h:extractErrorMessage('{"error":{"message":"bad","type":"same","code":"same"}}'), "bad")
        assert.equal(h:extractErrorMessage('{"detail":{"error":{"message":"proxied"}}}'), "proxied")
    end),

    test("anthropic: error.message", function()
        local h = AnthropicHandler:new{}
        assert.equal(h:extractErrorMessage('{"error":{"message":"invalid key"}}'), "invalid key")
        assert.equal(h:extractErrorMessage('{"error":"flat bad"}'), "flat bad")
        assert.equal(h:extractErrorMessage('{"message":"bare"}'), "bare")
    end),

    test("gemini: error.message", function()
        local h = GeminiHandler:new{}
        assert.equal(h:extractErrorMessage('{"error":{"message":"API key not valid","code":400,"status":"INVALID_ARGUMENT"}}'), "API key not valid [INVALID_ARGUMENT/400]")
        assert.equal(h:extractErrorMessage('{"message":"bare"}'), "bare")
    end),

    test("responses: error.message", function()
        local h = ResponsesHandler:new{}
        assert.equal(h:extractErrorMessage('{"error":{"message":"model not found"}}'), "model not found")
        assert.equal(h:extractErrorMessage('{"error":"flat bad"}'), "flat bad")
        assert.equal(h:extractErrorMessage('{"message":"bare"}'), "bare")
    end),
}

return helper.runTests("assistant_error_message", tests)
