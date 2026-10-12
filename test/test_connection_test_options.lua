-- test_connection_test_options.lua
-- Tests that handler:Test() folds the whitelisted additional_parameters into
-- the connection-test request body (BaseHandler:mergeSupportedOptions) and
-- keeps the extracted reasoning, so a reasoning-options probe sends and reports
-- exactly what a real exchange would.
local helper = require("test.helper")
local assert = helper.assert

local BaseHandler = require("api_handlers.base")
local OpenAIHandler = require("api_handlers.openai")
local AnthropicHandler = require("api_handlers.anthropic")
local GeminiHandler = require("api_handlers.gemini")
local ResponsesHandler = require("api_handlers.responses")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Canned API responses with both halves of an answer: reasoning plus reply.
local OPENAI_OK = {
    choices = { { message = { content = "OK", reasoning_content = "one word is enough" } } },
}
local ANTHROPIC_OK = {
    content = { { type = "thinking", thinking = "they want one word" }, { type = "text", text = "OK" } },
}
local GEMINI_OK = {
    candidates = { { content = { parts = {
        { text = "one word is enough", thought = true },
        { text = "OK" },
    } } } },
}
local RESPONSES_OK = {
    output_text = "OK",
    output = {
        { type = "reasoning", text = "one word is enough" },
        { type = "message", content = { { type = "output_text", text = "OK" } } },
    },
}

-- Run handler:Test() with testRequest stubbed to capture the outgoing request
-- body and to run the handler's own extract on a canned response. The stub
-- lives on the throwaway instance, so module singletons stay untouched.
local function captureTest(handler, response)
    local captured = {}
    handler.testRequest = function(_, url, headers, body, extract)
        captured.url = url
        captured.body = body
        captured.content, captured.reasoning = extract(response)
        return {
            url = url, body = "{}", status = 200, raw = "{}",
            content = captured.content, reasoning = captured.reasoning,
        }
    end
    handler:Test()
    return captured
end

local tests = {

    test("openai test request carries the whitelisted options", function()
        local handler = OpenAIHandler:new{
            model = "test-model", api_key = "sk-test",
            base_url = "https://api.test.com/v1",
            additional_parameters = {
                reasoning_effort = "low",
                temperature = 0.2,
                sneaky = "not whitelisted",
            },
        }
        local captured = captureTest(handler, OPENAI_OK)
        assert.equal("low", captured.body.reasoning_effort)
        assert.equal(0.2, captured.body.temperature)
        assert.equal(nil, captured.body.sneaky,
            "keys outside SupportedOptions must stay out of the request")
        assert.equal("test-model", captured.body.model)
    end),

    test("bare connection test stays minimal", function()
        local handler = OpenAIHandler:new{
            model = "test-model", api_key = "sk-test",
            base_url = "https://api.test.com/v1",
        }
        local captured = captureTest(handler, OPENAI_OK)
        assert.equal(nil, captured.body.reasoning_effort)
        assert.equal(nil, captured.body.temperature)
        assert.equal("test-model", captured.body.model)
    end),

    test("openai test extract keeps the reasoning next to the reply", function()
        local handler = OpenAIHandler:new{
            model = "test-model", api_key = "sk-test",
            base_url = "https://api.test.com/v1",
        }
        local captured = captureTest(handler, OPENAI_OK)
        assert.equal("OK", captured.content)
        assert.equal("one word is enough", captured.reasoning)
    end),

    test("anthropic test request lets configured max_tokens win over the test budget", function()
        local handler = AnthropicHandler:new{
            model = "test-model", api_key = "sk-test",
            base_url = "https://api.test.com/v1",
            additional_parameters = {
                thinking = { type = "enabled", budget_tokens = 1024 },
                max_tokens = 8192,
            },
        }
        local captured = captureTest(handler, ANTHROPIC_OK)
        assert.equal(8192, captured.body.max_tokens,
            "a thinking budget must be tested against the configured max_tokens")
        assert.equal(1024, captured.body.thinking.budget_tokens)
        assert.equal("OK", captured.content)
        assert.equal("they want one word", captured.reasoning)
    end),

    test("anthropic test request falls back to the test budget without max_tokens", function()
        local handler = AnthropicHandler:new{
            model = "test-model", api_key = "sk-test",
            base_url = "https://api.test.com/v1",
            additional_parameters = { thinking = { type = "disabled" } },
        }
        local captured = captureTest(handler, ANTHROPIC_OK)
        assert.equal(AnthropicHandler.TEST_MAX_OUTPUT_TOKENS, captured.body.max_tokens)
        assert.equal("disabled", captured.body.thinking.type)
    end),

    test("gemini test request builds the generation config like a query", function()
        local handler = GeminiHandler:new{
            model = "test-model", api_key = "sk-test",
            base_url = "https://generativelanguage.googleapis.com/v1beta/models",
            additional_parameters = { thinkingConfig = { thinkingLevel = "low" } },
        }
        local captured = captureTest(handler, GEMINI_OK)
        assert.equal("low", captured.body.generationConfig.thinkingConfig.thinkingLevel)
        assert.equal(GeminiHandler.TEST_MAX_OUTPUT_TOKENS,
            captured.body.generationConfig.maxOutputTokens)
        assert.equal("OK", captured.content)
        assert.equal("one word is enough", captured.reasoning)
    end),

    test("gemini test request maps thinking_budget like a query", function()
        local function generationConfigFor(additional_parameters)
            local handler = GeminiHandler:new{
                model = "test-model", api_key = "sk-test",
                base_url = "https://generativelanguage.googleapis.com/v1beta/models",
                additional_parameters = additional_parameters,
            }
            return captureTest(handler, GEMINI_OK).body.generationConfig
        end

        local budgeted = generationConfigFor({ thinking_budget = 1024, maxOutputTokens = 4096 })
        assert.equal(1024, budgeted.thinkingConfig.thinkingBudget)
        assert.equal(4096, budgeted.maxOutputTokens,
            "a configured token budget must win over the test default")

        -- budget 0 means "no thinkingConfig at all", same as the query path.
        local off = generationConfigFor({ thinking_budget = 0 })
        assert.equal(nil, off.thinkingConfig)
    end),

    test("responses test request carries options and keeps the reasoning text", function()
        local handler = ResponsesHandler:new{
            model = "test-model", api_key = "sk-test",
            base_url = "https://api.test.com/v1",
            additional_parameters = { reasoning = { effort = "low" } },
        }
        local captured = captureTest(handler, RESPONSES_OK)
        assert.equal("low", captured.body.reasoning.effort)
        assert.equal("OK", captured.content)
        assert.equal("one word is enough", captured.reasoning,
            "an output_text answer must not swallow the reasoning items")
    end),

    test("a synced reasoning overlay reaches the test request", function()
        -- The exact chain the Reasoning Options dialog relies on: a throwaway
        -- handler synced with a not-yet-saved overlay, then tested.
        local handler = OpenAIHandler:new{}
        handler:SyncOptions({
            provider_name = "custom:1",
            handler_name = "openai",
            provider_setting = {
                handler = "openai",
                model = "test-model",
                base_url = "https://api.test.com/v1",
                api_key = "sk-test",
                additional_parameters = { temperature = 0.7 },
            },
            settings = { readSetting = function() return nil end },
        }, { reasoning_effort = "low", not_in_catalog = true })
        local captured = captureTest(handler, OPENAI_OK)
        assert.equal("low", captured.body.reasoning_effort,
            "the overlay under test must be on the wire")
        assert.equal(0.7, captured.body.temperature,
            "the provider's own parameters must stay in place")
        assert.equal(nil, captured.body.not_in_catalog,
            "the overlay is filtered by the same catalog whitelist as a query")
    end),

    test("mergeSupportedOptions leaves a body without options untouched", function()
        local handler = BaseHandler:new{ additional_parameters = "garbage" }
        local body = { model = "m" }
        handler:mergeSupportedOptions(body)
        assert.equal("m", body.model)
        assert.equal(nil, body.reasoning_effort)
    end),
}

return helper.runTests("test_connection_test_options", tests)
