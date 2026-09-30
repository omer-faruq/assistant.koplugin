-- test_tool_executor.lua
-- Tests for ToolExecutor.parseToolCallsResponse, "responses" (OpenAI
-- Responses API) branch. Covers the reasoning item shapes seen in the wild
-- (summary as string/array, root text, reasoning_text/summary_text content
-- blocks) and the message content block types.
local helper = require("test.helper")
local assert = helper.assert
local ToolExecutor = require("assistant_tool_executor")

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("responses: reasoning content block populates reasoning", function()
        local result = ToolExecutor.parseToolCallsResponse({
            output = {
                {
                    id = "rs_1",
                    type = "reasoning",
                    status = "completed",
                    content = { { type = "reasoning_text", text = "step by step" } },
                    summary = {},
                },
            },
        }, "responses")
        assert.equal(result.content, nil)
        assert.equal(result.reasoning, "step by step")
    end),

    test("responses: array summary entries are collected", function()
        local result = ToolExecutor.parseToolCallsResponse({
            output = {
                {
                    type = "reasoning",
                    summary = {
                        "plain entry",
                        { type = "summary_text", text = "table entry" },
                    },
                },
            },
        }, "responses")
        assert.equal(result.reasoning, "plain entry\ntable entry")
    end),

    test("responses: legacy string summary and root text still work", function()
        local from_summary = ToolExecutor.parseToolCallsResponse({
            output = { { type = "reasoning", summary = "summary text" } },
        }, "responses")
        assert.equal(from_summary.reasoning, "summary text")

        local from_text = ToolExecutor.parseToolCallsResponse({
            output = { { type = "reasoning", text = "body text" } },
        }, "responses")
        assert.equal(from_text.reasoning, "body text")
    end),

    test("responses: summary entries precede body text", function()
        local result = ToolExecutor.parseToolCallsResponse({
            output = {
                {
                    type = "reasoning",
                    summary = { "snapshot" },
                    text = "body",
                    content = { { type = "reasoning_text", text = "block body" } },
                },
            },
        }, "responses")
        assert.equal(result.reasoning, "snapshot\nbody\nblock body")
    end),

    test("responses: message content accepts output_text and text blocks", function()
        local output_text = ToolExecutor.parseToolCallsResponse({
            output = { { type = "message", content = {
                { type = "output_text", text = "hello" },
            } } },
        }, "responses")
        assert.equal(output_text.content, "hello")

        local text = ToolExecutor.parseToolCallsResponse({
            output = { { type = "message", content = {
                { type = "text", text = "hi" },
            } } },
        }, "responses")
        assert.equal(text.content, "hi")

        local legacy_string = ToolExecutor.parseToolCallsResponse({
            output = { { type = "message", content = "plain" } },
        }, "responses")
        assert.equal(legacy_string.content, "plain")
    end),

    test("responses: mixed reasoning and message returns both fields", function()
        local result = ToolExecutor.parseToolCallsResponse({
            output = {
                { type = "reasoning", content = { { type = "reasoning_text", text = "think" } } },
                { type = "message", content = { { type = "output_text", text = "answer" } } },
            },
        }, "responses")
        assert.equal(result.content, "answer")
        assert.equal(result.reasoning, "think")
        assert.equal(result.tool_calls, nil)
    end),

    test("responses: reasoning-only response has nil content", function()
        local result = ToolExecutor.parseToolCallsResponse({
            output = {
                { type = "reasoning", summary = { { type = "summary_text", text = "only thought" } } },
            },
        }, "responses")
        assert.equal(result.content, nil)
        assert.equal(result.reasoning, "only thought")
    end),

    test("responses: tool call response keeps raw_assistant shape", function()
        local result = ToolExecutor.parseToolCallsResponse({
            output = {
                { type = "reasoning", summary = "why" },
                { type = "function_call", call_id = "call_1", name = "web_search", arguments = '{"q":"x"}' },
            },
        }, "responses")
        assert.notNil(result.tool_calls)
        assert.equal(result.tool_calls[1].tool_call_id, "call_1")
        assert.equal(result.tool_calls[1].name, "web_search")
        assert.equal(result.reasoning, "why")
        assert.notNil(result.raw_assistant)
        assert.equal(result.raw_assistant.role, "assistant")
    end),
}

return helper.runTests("assistant_tool_executor", tests)
