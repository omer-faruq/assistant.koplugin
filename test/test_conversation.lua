-- test_conversation.lua
-- Unit tests for the new assistant_conversation module:
--   * TurnPolicy.resolve computes tool_mode from web_search_intent + global setting
--   * TurnPolicy respects explicit prompt_config.use_websearch
--   * TurnPolicy falls back to global web_search when no intent given
--   * TurnPolicy.suggestions follows Prompts.isSuggestionsEnabled
--   * QueryRequest freezes messages (deep copy, no shared mutation)
--   * Session.append + freeze_request produce a clean request snapshot
local helper = require("test.helper")
local assert = helper.assert
local Conversation = require("assistant_conversation")
local koutil = require("util")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function make_settings(web_search, suggestions)
    return {
        readSetting = function(_, key, def)
            if key == "use_websearch" then return web_search or "none" end
            if key == "auto_prompt_suggest" then return suggestions ~= false end
            if key == "use_stream_mode" then return true end
            return def
        end,
    }
end

local tests = {
    test("TurnPolicy: web_search_intent=true + global builtin -> tool_mode=builtin", function()
        local input = Conversation.TurnInput:new{
            kind = "free",
            origin = "typed",
            text = "What's new?",
            web_search_intent = true,
        }
        local policy = Conversation.TurnPolicy.resolve(input, make_settings("builtin"), "builtin")
        assert.isTrue(policy.tool_requested)
        assert.equal("builtin", policy.tool_mode)
    end),

    test("TurnPolicy: web_search_intent=false -> tool_mode=none even with global enabled", function()
        local input = Conversation.TurnInput:new{
            kind = "free",
            origin = "typed",
            text = "Hello",
            web_search_intent = false,
        }
        local policy = Conversation.TurnPolicy.resolve(input, make_settings("builtin"), "builtin")
        assert.isFalse(policy.tool_requested)
        assert.equal("none", policy.tool_mode)
    end),

    test("TurnPolicy: no intent + prompt_config.use_websearch=true -> uses global", function()
        local input = Conversation.TurnInput:new{
            kind = "preset",
            origin = "prompt_button",
            text = "Summarize",
            prompt_config = { use_websearch = true },
        }
        local policy = Conversation.TurnPolicy.resolve(input, make_settings("tavilyapi"), "tavilyapi")
        assert.isTrue(policy.tool_requested)
        assert.equal("tavilyapi", policy.tool_mode)
    end),

    test("TurnPolicy: no intent + prompt_config.use_websearch=false -> tool_mode=none", function()
        local input = Conversation.TurnInput:new{
            kind = "preset",
            origin = "prompt_button",
            text = "Summarize",
            prompt_config = { use_websearch = false },
        }
        local policy = Conversation.TurnPolicy.resolve(input, make_settings("builtin"), "builtin")
        assert.isFalse(policy.tool_requested)
        assert.equal("none", policy.tool_mode)
    end),

    test("TurnPolicy: tool_requested=true but global=none -> tool_mode=none", function()
        local input = Conversation.TurnInput:new{
            kind = "free",
            origin = "typed",
            text = "Search for X",
            web_search_intent = true,
        }
        local policy = Conversation.TurnPolicy.resolve(input, make_settings("none"), "none")
        assert.isTrue(policy.tool_requested)
        assert.equal("none", policy.tool_mode)
    end),

    test("TurnPolicy: suggestions follows global auto_prompt_suggest", function()
        local input = Conversation.TurnInput:new{
            kind = "free",
            origin = "typed",
            text = "Hello",
        }
        local policy = Conversation.TurnPolicy.resolve(input, make_settings("builtin", true), "builtin")
        assert.isTrue(policy.suggestions)
    end),

    test("TurnPolicy: suggestions disabled globally", function()
        local input = Conversation.TurnInput:new{
            kind = "free",
            origin = "typed",
            text = "Hello",
        }
        local policy = Conversation.TurnPolicy.resolve(input, make_settings("builtin", false), "builtin")
        assert.isFalse(policy.suggestions)
    end),

    test("TurnPolicy: context_mode=refresh for free questions", function()
        local input = Conversation.TurnInput:new{
            kind = "free",
            origin = "typed",
            text = "Hello",
        }
        local policy = Conversation.TurnPolicy.resolve(input, make_settings("builtin"), "builtin")
        assert.equal("refresh", policy.context_mode)
    end),

    test("TurnPolicy: context_mode=none for preset without use_book_context", function()
        local input = Conversation.TurnInput:new{
            kind = "preset",
            origin = "prompt_button",
            text = "Summarize",
            prompt_config = {},
        }
        local policy = Conversation.TurnPolicy.resolve(input, make_settings("builtin"), "builtin")
        assert.equal("none", policy.context_mode)
    end),

    test("TurnPolicy: context_mode=refresh for preset with use_book_context", function()
        local input = Conversation.TurnInput:new{
            kind = "preset",
            origin = "prompt_button",
            text = "Summarize",
            prompt_config = { use_book_context = true },
        }
        local policy = Conversation.TurnPolicy.resolve(input, make_settings("builtin"), "builtin")
        assert.equal("refresh", policy.context_mode)
    end),

    test("QueryRequest: stores messages by reference (freeze_request does the copy)", function()
        -- QueryRequest itself is a lightweight snapshot; the deep copy
        -- happens in Session:freeze_request so that callers can build
        -- requests from mutable session state safely.
        local messages = {
            { role = "system", content = "system prompt" },
            { role = "user", content = "Hello" },
        }
        local req = Conversation.QueryRequest:new{
            messages = messages,
            stream = false,
            tool_mode = "builtin",
            title = "Test",
            identity = { label = "Provider", model = "model-x" },
        }
        assert.equal(2, #req.messages)
        assert.equal("Hello", req.messages[2].content)
        assert.equal("builtin", req.tool_mode)
        assert.equal("Test", req.title)
    end),

    test("Session: freeze_request deep-copies messages", function()
        local session = Conversation.Session:new{
            assistant = { settings = make_settings("builtin") },
        }
        session:append({ role = "system", content = "system" })
        session:append({ role = "user", content = "Hello" })
        local policy = Conversation.TurnPolicy:new{
            tool_requested = false,
            tool_mode = "none",
            suggestions = false,
            context_mode = "none",
        }
        local req = session:freeze_request(policy, { label = "P", model = "M" })
        -- Mutate session after freeze; request must not change
        session.history[2].content = "Mutated"
        assert.equal("Hello", req.messages[2].content)
        assert.equal(2, #req.messages)
    end),

    test("Session: append + freeze_request produces clean snapshot", function()
        local session = Conversation.Session:new{
            assistant = { settings = make_settings("builtin") },
            title = "Test Session",
        }
        session:append({ role = "system", content = "system" })
        session:append({ role = "user", content = "Hello" })
        local policy = Conversation.TurnPolicy:new{
            tool_requested = false,
            tool_mode = "none",
            suggestions = false,
            context_mode = "none",
        }
        local identity = { label = "P", model = "M" }
        local req = session:freeze_request(policy, identity)
        assert.equal(2, #req.messages)
        assert.equal("system", req.messages[1].content)
        assert.equal("Hello", req.messages[2].content)
        assert.equal("none", req.tool_mode)
    end),
}

return helper.runTests("conversation.lua", tests)
