-- test_anthropic_websearch.lua
-- Tests for AnthropicHandler builtin web_search support:
-- builtin/ext/none tool wiring across stream and non-stream paths,
-- the anthropic-version header default, and builtin non-stream parsing
-- (all text blocks concatenated, server blocks never tool calls).
local helper = require("test.helper")
local assert = helper.assert
local json = require("rapidjson")

local AnthropicHandler = require("api_handlers.anthropic")

local function test(name, fn)
    return { name = name, fn = fn }
end

local MESSAGES = {
    { role = "user", content = "What is new?" },
}

local function makeHandler(additional_parameters)
    return AnthropicHandler:new{
        model = "claude-test",
        base_url = "https://api.anthropic.com/v1",
        api_key = "test-key",
        additional_parameters = additional_parameters or {},
    }
end

-- Stub instance:makeRequest with a canned JSON body; records call args.
local function stubRequest(handler, response_table)
    local captured = {}
    handler.makeRequest = function(self, url, headers, body)
        captured.url = url
        captured.headers = headers
        captured.body = json.decode(body)
        return true, 200, json.encode(response_table)
    end
    return captured
end

-- Stub instance:backgroundRequest; records call args.
local function stubStream(handler)
    local captured = {}
    handler.backgroundRequest = function(self, url, headers, body)
        captured.url = url
        captured.headers = headers
        captured.body = json.decode(body)
        return function() end
    end
    return captured
end

local BUILTIN_RESPONSE = {
    content = {
        { type = "text", text = "First. " },
        { type = "server_tool_use", id = "srv_1", name = "web_search" },
        { type = "web_search_tool_result", tool_use_id = "srv_1",
          content = { { type = "text", text = "raw server output" } } },
        { type = "text", text = "Second.", citations = { { cited_text = "src" } } },
    },
    stop_reason = "end_turn",
}

local tests = {
    test("builtin non-stream: sends web_search tool, concatenates text", function()
        local h = makeHandler()
        local captured = stubRequest(h, BUILTIN_RESPONSE)
        local res, err = h:query(MESSAGES, { use_websearch = "builtin", use_stream_mode = false })
        assert.equal(nil, err)
        assert.equal("First. Second.", res)
        local tools = captured.body.tools
        assert.notNil(tools)
        assert.equal("web_search_20250305", tools[1].type)
        assert.equal("web_search", tools[1].name)
        assert.equal(5, tools[1].max_uses)
        assert.equal("2023-06-01", captured.headers["anthropic-version"])
    end),

    test("builtin non-stream: server-only blocks are not a tool call", function()
        local h = makeHandler()
        stubRequest(h, {
            content = {
                { type = "server_tool_use", id = "srv_1", name = "web_search" },
                { type = "web_search_tool_result", tool_use_id = "srv_1",
                  content = { { type = "text", text = "raw" } } },
            },
            stop_reason = "pause_turn",
        })
        local res, err = h:query(MESSAGES, { use_websearch = "builtin", use_stream_mode = false })
        assert.equal(nil, res)
        assert.notNil(err)
    end),

    test("ext non-stream: sends function tool, returns tool call", function()
        local h = makeHandler()
        local captured = stubRequest(h, {
            content = {
                { type = "text", text = "I will search." },
                { type = "tool_use", id = "toolu_1", name = "assistant_web_search",
                  input = { keywords = "latest news" } },
            },
            stop_reason = "tool_use",
        })
        local res, err = h:query(MESSAGES, { use_websearch = "tavilyapi", use_stream_mode = false })
        assert.equal(nil, err)
        assert.isTrue(res.__is_tool_call)
        assert.equal("assistant_web_search", res.tool_calls[1].name)
        assert.equal("assistant_web_search", captured.body.tools[1].name)
    end),

    test("none non-stream: no tools injected, plain text returned", function()
        local h = makeHandler()
        local captured = stubRequest(h, {
            content = { { type = "text", text = "plain answer" } },
            stop_reason = "end_turn",
        })
        local res, err = h:query(MESSAGES, { use_websearch = "none", use_stream_mode = false })
        assert.equal(nil, err)
        assert.equal("plain answer", res)
        assert.equal(nil, captured.body.tools)
    end),

    test("none non-stream: keeps additional_parameters.tools passthrough", function()
        local h = makeHandler({ tools = { { type = "web_search_20250305", name = "web_search" } } })
        local captured = stubRequest(h, {
            content = { { type = "text", text = "ok" } },
            stop_reason = "end_turn",
        })
        local res, err = h:query(MESSAGES, { use_websearch = "none", use_stream_mode = false })
        assert.equal(nil, err)
        assert.equal("ok", res)
        assert.equal("web_search", captured.body.tools[1].name)
    end),

    test("custom anthropic-version header is respected", function()
        local h = makeHandler({ anthropic_version = "2024-01-01" })
        local captured = stubRequest(h, {
            content = { { type = "text", text = "ok" } },
            stop_reason = "end_turn",
        })
        h:query(MESSAGES, { use_websearch = "none", use_stream_mode = false })
        assert.equal("2024-01-01", captured.headers["anthropic-version"])
    end),

    test("stream: builtin/ext/none share the tools variable", function()
        local h_builtin = makeHandler()
        local cap_builtin = stubStream(h_builtin)
        h_builtin:query(MESSAGES, { use_websearch = "builtin", use_stream_mode = true })
        assert.equal("web_search_20250305", cap_builtin.body.tools[1].type)
        assert.equal("2023-06-01", cap_builtin.headers["anthropic-version"])

        local h_ext = makeHandler()
        local cap_ext = stubStream(h_ext)
        h_ext:query(MESSAGES, { use_websearch = "tavilyapi", use_stream_mode = true })
        assert.equal("assistant_web_search", cap_ext.body.tools[1].name)

        local h_none = makeHandler()
        local cap_none = stubStream(h_none)
        h_none:query(MESSAGES, { use_websearch = "none", use_stream_mode = true })
        assert.equal(nil, cap_none.body.tools)
    end),
}

return helper.runTests("assistant_anthropic_websearch", tests)
