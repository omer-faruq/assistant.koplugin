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

    test("only openai overrides extractErrorMessage", function()
        -- The other wire formats must keep inheriting the canonical base
        -- implementation; an own copy could silently diverge from it. The
        -- handler classes inherit through __index, so check the class table
        -- itself with rawget.
        assert.equal(rawget(AnthropicHandler, "extractErrorMessage"), nil)
        assert.equal(rawget(GeminiHandler, "extractErrorMessage"), nil)
        assert.equal(rawget(ResponsesHandler, "extractErrorMessage"), nil)
        assert.notNil(rawget(OpenAIHandler, "extractErrorMessage"))
        assert.notNil(rawget(BaseHandler, "extractErrorMessage"))
    end),

    test("base default: detail table without error/message/code/status returns nil", function()
        local h = BaseHandler:new{}
        assert.equal(h:extractErrorMessage('{"detail":{"foo":"bar"}}'), nil)
        assert.equal(h:extractErrorMessage('{"detail":{}}'), nil)
        assert.equal(NetUtils.extractErrorMessage({ detail = { foo = "bar" } }), nil)
    end),

    test("prefixHttpCode: numeric code, non-numeric code, and no code", function()
        -- A 100..599 integer gets its own prefix; anything else (socket
        -- reason strings, nil, empty) falls back to [0] so the reason stays
        -- visible instead of vanishing.
        assert.equal(BaseHandler.prefixHttpCode(400, "Bad Request"), "[400] Bad Request")
        assert.equal(BaseHandler.prefixHttpCode("429", "slow"), "[429] slow")
        assert.equal(BaseHandler.prefixHttpCode("wantread", "wantread"), "[0] wantread")
        assert.equal(BaseHandler.prefixHttpCode(nil, "timeout"), "[0] timeout")
        assert.equal(BaseHandler.prefixHttpCode("", "timeout"), "[0] timeout")
    end),

    test("prefixHttpCode: base text appends the endpoint only when it differs", function()
        -- Mirrors the err_header base composition in assistant_querier.lua:
        -- the endpoint is appended after the reason, and only when the base
        -- is not the endpoint itself (no "url (url)" duplication).
        local function base_text(reason, endpoint)
            local base = reason ~= "" and reason or endpoint
            if endpoint ~= "" and base ~= endpoint then
                base = base .. " (" .. endpoint .. ")"
            end
            return base
        end
        assert.equal(BaseHandler.prefixHttpCode(400, base_text("Bad Request", "https://host/api")),
            "[400] Bad Request (https://host/api)")
        assert.equal(BaseHandler.prefixHttpCode(nil, base_text("", "https://host/api")),
            "[0] https://host/api")
    end),
}

return helper.runTests("assistant_error_message", tests)
