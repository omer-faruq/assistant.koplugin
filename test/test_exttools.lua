-- test_exttools.lua
-- Tests for assistant_exttools.lua: SerpAPI, Tavily, SearXNG, Exa.ai, and SearchToolBase.
local helper = require("test.helper")
local assert = helper.assert
local extools = helper.extools

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {

    -- =========================================================================
    -- SearchToolBase (none, builtin)
    -- =========================================================================

    test("SearchToolBase: SearchKeywords returns empty string", function()
        local ok, result = extools.none:SearchKeywords("test query")
        assert.equal(ok, true, "SearchKeywords should return ok=true")
        assert.equal(result, "", "SearchKeywords should return empty string")
    end),

    test("SearchToolBase: AccoutInfo returns name and base_url", function()
        local ok, result = extools.none:AccoutInfo()
        assert.equal(ok, true)
        assert.notNil(result)
    end),

    test("SearchToolBase: builtin instance exists", function()
        assert.isTrue(extools.builtin ~= nil)
        assert.equal(extools.builtin.name, "Model Built-In")
    end),

    -- =========================================================================
    -- SerpAPI: SearchKeywords
    -- =========================================================================

    test("SerpAPI: successful search with reconstructed_markdown", function()
        helper.mockFetchJSON({
            { parsed = {
                reconstructed_markdown = "AI summary text",
                references = {},
            }, err = nil },
        })
        local ok, result = extools.serpapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Google AI Summary")
        assert.matches(result, "AI summary text")
    end),

    test("SerpAPI: successful search with references", function()
        helper.mockFetchJSON({
            { parsed = {
                reconstructed_markdown = nil,
                references = {
                    { index = 1, title = "Source One", source = "Web" },
                    { index = 2, title = "Source Two", source = "Blog" },
                },
            }, err = nil },
        })
        local ok, result = extools.serpapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Verified Sources")
        assert.matches(result, "Source One")
        assert.matches(result, "Source Two")
    end),

    test("SerpAPI: no results returns error", function()
        helper.mockFetchJSON({
            { parsed = {}, err = nil },
        })
        local ok, err = extools.serpapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.matches(err, "No relevant search")
    end),

    test("SerpAPI: network error", function()
        helper.mockFetchJSON({
            { parsed = nil, err = "NETWORK_ERROR" },
        })
        local ok, err = extools.serpapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "NETWORK_ERROR")
    end),

    test("SerpAPI: cancelled by user", function()
        local CODE_CANCELLED = helper.ASUtils.HANDLERCODE.CODE_CANCELLED
        helper.mockFetchJSON({
            { parsed = nil, err = CODE_CANCELLED },
        })
        local ok, err = extools.serpapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, CODE_CANCELLED)
    end),

    -- =========================================================================
    -- Tavily: SearchKeywords
    -- =========================================================================

    test("Tavily: successful search with answer and results", function()
        helper.mockFetchJSON({
            { parsed = {
                answer = "Tavily summary text",
                results = {
                    { title = "Result 1", content = "Content 1" },
                    { title = "Result 2", content = "Content 2" },
                },
            }, err = nil },
        })
        local ok, result = extools.tavilyapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Summary")
        assert.matches(result, "Tavily summary text")
        assert.matches(result, "Source 1")
        assert.matches(result, "Result 1")
        assert.matches(result, "Source 2")
    end),

    test("Tavily: search without answer still succeeds", function()
        helper.mockFetchJSON({
            { parsed = {
                results = {
                    { title = "Only Result", content = "Content" },
                },
            }, err = nil },
        })
        local ok, result = extools.tavilyapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.notMatches(result, "## Summary") -- AI-answer section should be absent
        assert.matches(result, "verified search results")
    end),

    test("Tavily: missing results field returns error", function()
        helper.mockFetchJSON({
            { parsed = {}, err = nil },
        })
        local ok, err = extools.tavilyapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "fail to parse tavily return")
    end),

    test("Tavily: network error", function()
        helper.mockFetchJSON({
            { parsed = nil, err = "NETWORK_ERROR" },
        })
        local ok, err = extools.tavilyapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "NETWORK_ERROR")
    end),

    test("Tavily: cancelled by user", function()
        local CODE_CANCELLED = helper.ASUtils.HANDLERCODE.CODE_CANCELLED
        helper.mockFetchJSON({
            { parsed = nil, err = CODE_CANCELLED },
        })
        local ok, err = extools.tavilyapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, CODE_CANCELLED)
    end),

    -- =========================================================================
    -- SearXNG: SearchKeywords
    -- =========================================================================

    test("SearXNG: successful search with results", function()
        helper.mockFetchJSON({
            { parsed = {
                results = {
                    { title = "Page 1", url = "https://example.com/1", content = "Content 1" },
                    { title = "Page 2", url = "https://example.com/2", content = "Content 2" },
                },
            }, err = nil },
        })
        local ok, result = extools.searxngapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Web Search Results")
        assert.matches(result, "Page 1")
        assert.matches(result, "https://example.com/1")
        assert.matches(result, "Page 2")
    end),

    test("SearXNG: missing results field returns error", function()
        helper.mockFetchJSON({
            { parsed = {}, err = nil },
        })
        local ok, err = extools.searxngapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "fail to parse searxng return")
    end),

    test("SearXNG: network error", function()
        helper.mockFetchJSON({
            { parsed = nil, err = "NETWORK_ERROR" },
        })
        local ok, err = extools.searxngapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "NETWORK_ERROR")
    end),

    -- =========================================================================
    -- Exa.ai: SearchKeywords
    -- =========================================================================

    test("Exa.ai: successful search with summary and highlights", function()
        helper.mockFetchJSON({
            { parsed = {
                results = {
                    {
                        title = "Doc 1",
                        summary = "Summary of doc 1",
                        highlights = { "highlight 1a", "highlight 1b" },
                    },
                },
            }, err = nil },
        })
        local ok, result = extools.exaapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Exa.ai Search Results")
        assert.matches(result, "Doc 1")
        assert.matches(result, "Summary of doc 1")
        assert.matches(result, "highlight 1a")
        assert.matches(result, "highlight 1b")
    end),

    test("Exa.ai: search with subpages", function()
        helper.mockFetchJSON({
            { parsed = {
                results = {
                    {
                        title = "Main Doc",
                        summary = "Main summary",
                        subpages = {
                            {
                                title = "Subpage 1",
                                summary = "Sub summary",
                                highlights = { "sub highlight" },
                            },
                        },
                    },
                },
            }, err = nil },
        })
        local ok, result = extools.exaapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Subpage 1")
        assert.matches(result, "Sub summary")
        assert.matches(result, "sub highlight")
    end),

    test("Exa.ai: missing results field returns error", function()
        helper.mockFetchJSON({
            { parsed = {}, err = nil },
        })
        local ok, err = extools.exaapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "fail to parse exa.ai return")
    end),

    test("Exa.ai: network error", function()
        helper.mockFetchJSON({
            { parsed = nil, err = "NETWORK_ERROR" },
        })
        local ok, err = extools.exaapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "NETWORK_ERROR")
    end),

    test("Exa.ai: cancelled by user", function()
        local CODE_CANCELLED = helper.ASUtils.HANDLERCODE.CODE_CANCELLED
        helper.mockFetchJSON({
            { parsed = nil, err = CODE_CANCELLED },
        })
        local ok, err = extools.exaapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, CODE_CANCELLED)
    end),

    -- =========================================================================
    -- Module return table shape
    -- =========================================================================

    test("module exports all tools", function()
        assert.notNil(extools.none)
        assert.notNil(extools.builtin)
        assert.notNil(extools.serpapi)
        assert.notNil(extools.tavilyapi)
        assert.notNil(extools.searxngapi)
        assert.notNil(extools.exaapi)
    end),

    test("all tools have expected properties", function()
        local tools = { "serpapi", "tavilyapi", "searxngapi", "exaapi" }
        for _, key in ipairs(tools) do
            local tool = extools[key]
            assert.notNil(tool, key .. " should exist")
            assert.notNil(tool.name, key .. " should have name")
            assert.notNil(tool.base_url, key .. " should have base_url")
            assert.isTrue(tool.is_external, key .. " should be external")
        end
    end),
}

return helper.runTests("assistant_exttools.lua", tests)