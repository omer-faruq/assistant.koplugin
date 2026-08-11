-- test_search_registry.lua
-- Tests for assistant_search_registry.lua: load/save, validate, merge,
-- upsert, delete, and the Add Web Search API menu factory.
local helper = require("test.test_helper")
local assert = helper.assert
local SearchRegistry = require("assistant_search_registry")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Deep equality helper.
local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    local count_a, count_b = 0, 0
    for k, v in pairs(a) do
        count_a = count_a + 1
        if not deepEqual(v, b[k]) then return false end
    end
    for key in pairs(b) do
        count_b = count_b + 1
    end
    return count_a == count_b
end

-- A mock LuaSettings that persists in memory.
local function mockSettings(initial)
    local store = initial or {}
    return {
        readSetting = function(self, key) return store[key] end,
        saveSetting = function(self, key, val) store[key] = val end,
        _store = store,
    }
end

-- A mock Assistant that has the plumbing SearchRegistry touches.
local function mockAssistant(search_data)
    return {
        _ui_search_data = search_data or { tools = {} },
        settings = mockSettings(),
        CONFIGURATION = { provider_settings = {} },
        updated = false,
    }
end

local tests = {

    -- =========================================================================
    -- SEARCH_TOOLS / TOOL_KEYS exported
    -- =========================================================================

    test("SEARCH_TOOLS defines all four tools", function()
        assert.notNil(SearchRegistry.SEARCH_TOOLS.serpapi)
        assert.notNil(SearchRegistry.SEARCH_TOOLS.tavilyapi)
        assert.notNil(SearchRegistry.SEARCH_TOOLS.exaapi)
        assert.notNil(SearchRegistry.SEARCH_TOOLS.searxngapi)
    end),

    test("TOOL_KEYS lists all four keys in order", function()
        assert.equal(#SearchRegistry.TOOL_KEYS, 4)
        assert.equal(SearchRegistry.TOOL_KEYS[1], "serpapi")
        assert.equal(SearchRegistry.TOOL_KEYS[2], "tavilyapi")
        assert.equal(SearchRegistry.TOOL_KEYS[3], "exaapi")
        assert.equal(SearchRegistry.TOOL_KEYS[4], "searxngapi")
    end),

    test("API key tools have needs=api_key", function()
        assert.equal(SearchRegistry.SEARCH_TOOLS.serpapi.needs, "api_key")
        assert.equal(SearchRegistry.SEARCH_TOOLS.tavilyapi.needs, "api_key")
        assert.equal(SearchRegistry.SEARCH_TOOLS.exaapi.needs, "api_key")
    end),

    test("SearXNG has needs=base_url", function()
        assert.equal(SearchRegistry.SEARCH_TOOLS.searxngapi.needs, "base_url")
    end),

    test("SEARCH_TOOLS retains display_name for menu labels", function()
        assert.equal(SearchRegistry.SEARCH_TOOLS.serpapi.display_name, "SerpAPI")
        assert.equal(SearchRegistry.SEARCH_TOOLS.tavilyapi.display_name, "Tavily")
        assert.equal(SearchRegistry.SEARCH_TOOLS.exaapi.display_name, "Exa.ai")
        assert.equal(SearchRegistry.SEARCH_TOOLS.searxngapi.display_name, "SearXNG")
    end),

    -- =========================================================================
    -- Load / Save
    -- =========================================================================

    test("load returns empty structure when no setting exists", function()
        local settings = mockSettings()
        local data = SearchRegistry.load(settings)
        assert.notNil(data)
        assert.equal(type(data.tools), "table")
        assert.equal(next(data.tools), nil)
    end),

    test("save and load round-trip preserves data", function()
        local settings = mockSettings()
        local data = { tools = {} }
        data.tools.serpapi = { api_key = "sk-test" }
        data.tools.searxngapi = { base_url = "https://sx.example.com" }

        local ok = SearchRegistry.save(settings, data)
        assert.isTrue(ok)

        local loaded = SearchRegistry.load(settings)
        assert.equal(loaded.tools.serpapi.api_key, "sk-test")
        assert.equal(loaded.tools.searxngapi.base_url, "https://sx.example.com")
    end),

    test("load returns fresh structure on corrupt JSON", function()
        local settings = mockSettings()
        settings:saveSetting("ui_search_tools", "{invalid json!!")
        local data = SearchRegistry.load(settings)
        assert.equal(type(data.tools), "table")
        assert.equal(next(data.tools), nil)
    end),

    test("load returns fresh structure on schema version mismatch", function()
        local settings = mockSettings()
        settings:saveSetting("ui_search_tools",
            '{"schema_version":999,"tools":{"serpapi":{"api_key":"x"}}}')
        local data = SearchRegistry.load(settings)
        assert.equal(next(data.tools), nil)
    end),

    test("load gracefully ignores old records with display_name field", function()
        local settings = mockSettings()
        settings:saveSetting("ui_search_tools",
            '{"schema_version":1,"tools":{"serpapi":{"display_name":"Old","api_key":"sk-123"}}}')
        local data = SearchRegistry.load(settings)
        assert.equal(data.tools.serpapi.api_key, "sk-123")
    end),

    -- =========================================================================
    -- Validate
    -- =========================================================================

    test("validate passes for serpapi with api_key", function()
        local ok, err = SearchRegistry.validate({
            api_key = "sk-123",
        }, "serpapi")
        assert.isTrue(ok)
    end),

    test("validate passes for serpapi without display_name", function()
        local ok, err = SearchRegistry.validate({
            api_key = "sk-123",
        }, "serpapi")
        assert.isTrue(ok)
    end),

    test("validate passes with display_name present (ignored)", function()
        local ok, err = SearchRegistry.validate({
            display_name = "SerpAPI",
            api_key = "sk-123",
        }, "serpapi")
        assert.isTrue(ok)
    end),

    test("validate fails for serpapi without api_key", function()
        local ok, err = SearchRegistry.validate({
        }, "serpapi")
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("validate fails for serpapi with blank api_key", function()
        local ok, err = SearchRegistry.validate({
            api_key = "   ",
        }, "serpapi")
        assert.isFalse(ok)
    end),

    test("validate passes for tavilyapi with api_key", function()
        local ok, err = SearchRegistry.validate({
            api_key = "tvly-123",
        }, "tavilyapi")
        assert.isTrue(ok)
    end),

    test("validate fails for tavilyapi without api_key", function()
        local ok, err = SearchRegistry.validate({
        }, "tavilyapi")
        assert.isFalse(ok)
    end),

    test("validate passes for exaapi with api_key", function()
        local ok, err = SearchRegistry.validate({
            api_key = "exa-123",
        }, "exaapi")
        assert.isTrue(ok)
    end),

    test("validate fails for exaapi without api_key", function()
        local ok, err = SearchRegistry.validate({
        }, "exaapi")
        assert.isFalse(ok)
    end),

    test("validate passes for searxngapi with base_url", function()
        local ok, err = SearchRegistry.validate({
            base_url = "https://search.example.com",
        }, "searxngapi")
        assert.isTrue(ok)
    end),

    test("validate passes for searxngapi without display_name", function()
        local ok, err = SearchRegistry.validate({
            base_url = "https://search.example.com",
        }, "searxngapi")
        assert.isTrue(ok)
    end),

    test("validate fails for searxngapi without base_url", function()
        local ok, err = SearchRegistry.validate({
        }, "searxngapi")
        assert.isFalse(ok)
    end),

    test("validate fails for searxngapi with invalid base_url", function()
        local ok, err = SearchRegistry.validate({
            base_url = "not-a-url",
        }, "searxngapi")
        assert.isFalse(ok)
    end),

    test("validate fails for unknown tool key", function()
        local ok, err = SearchRegistry.validate({
            api_key = "k",
        }, "unknown_tool")
        assert.isFalse(ok)
    end),

    test("validate fails for non-table record", function()
        local ok, err = SearchRegistry.validate("not a table", "serpapi")
        assert.isFalse(ok)
    end),

    -- =========================================================================
    -- Merge
    -- =========================================================================

    test("merge with file config only", function()
        local file_config = {
            provider_settings = {
                serpapi = { api_key = "file-key" },
                searxngapi = { base_url = "https://file-searxng.example.com" },
            },
        }
        local merged = SearchRegistry.merge(file_config, { tools = {} })
        assert.equal(merged.serpapi.api_key, "file-key")
        assert.equal(merged.serpapi.source, "file")
        assert.equal(merged.serpapi.immutable, true)
        assert.equal(merged.searxngapi.base_url, "https://file-searxng.example.com")
    end),

    test("merge with UI config only", function()
        local ui_data = { tools = {
            serpapi = { api_key = "ui-key" },
        }}
        local merged = SearchRegistry.merge(nil, ui_data)
        assert.equal(merged.serpapi.api_key, "ui-key")
        assert.equal(merged.serpapi.source, "ui")
    end),

    test("merge: UI config overrides file config with same key", function()
        local file_config = {
            provider_settings = {
                serpapi = { api_key = "file-key" },
            },
        }
        local ui_data = { tools = {
            serpapi = { api_key = "ui-key" },
        }}
        local merged = SearchRegistry.merge(file_config, ui_data)
        assert.equal(merged.serpapi.api_key, "ui-key")
        assert.equal(merged.serpapi.source, "ui")
    end),

    test("merge does not include non-search-tool keys from file config", function()
        local file_config = {
            provider_settings = {
                openai = { api_key = "ai-key", handler = "openai" },
                serpapi = { api_key = "search-key" },
            },
        }
        local merged = SearchRegistry.merge(file_config, { tools = {} })
        assert.equal(merged.openai, nil)
        assert.notNil(merged.serpapi)
    end),

    test("merge returns empty table when both sources are empty", function()
        local merged = SearchRegistry.merge(nil, { tools = {} })
        assert.equal(type(merged), "table")
        assert.equal(next(merged), nil)
    end),

    test("merge ignores invalid tool keys from UI data", function()
        local ui_data = { tools = {
            serpapi = { api_key = "k" },
            bogus = { api_key = "k" },
        }}
        local merged = SearchRegistry.merge(nil, ui_data)
        assert.notNil(merged.serpapi)
        assert.equal(merged.bogus, nil)
    end),

    -- =========================================================================
    -- Upsert
    -- =========================================================================

    test("upsert inserts a new tool record (no display_name)", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "serpapi", {
            api_key = "sk-123",
        })
        assert.isTrue(ok)
        assert.equal(data.tools.serpapi.api_key, "sk-123")
        -- display_name is NOT stored in the record
        assert.equal(data.tools.serpapi.display_name, nil)
    end),

    test("upsert ignores display_name in input record", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "serpapi", {
            display_name = "Should Not Be Saved",
            api_key = "sk-123",
        })
        assert.isTrue(ok)
        assert.equal(data.tools.serpapi.api_key, "sk-123")
        assert.equal(data.tools.serpapi.display_name, nil)
    end),

    test("upsert overwrites an existing tool record (update)", function()
        local data = { tools = {} }
        SearchRegistry.upsert(data, "serpapi", {
            api_key = "old-key",
        })
        local ok, err = SearchRegistry.upsert(data, "serpapi", {
            api_key = "new-key",
        })
        assert.isTrue(ok)
        assert.equal(data.tools.serpapi.api_key, "new-key")
        assert.equal(data.tools.serpapi.display_name, nil)
    end),

    test("upsert uses fixed tool key (no new IDs generated)", function()
        local data = { tools = {} }
        SearchRegistry.upsert(data, "serpapi", {
            api_key = "k",
        })
        SearchRegistry.upsert(data, "tavilyapi", {
            api_key = "k",
        })
        -- Keys should be exactly the fixed tool keys
        assert.notNil(data.tools.serpapi)
        assert.notNil(data.tools.tavilyapi)
        assert.equal(data.tools.exaapi, nil)
        assert.equal(data.tools.searxngapi, nil)
    end),

    test("upsert fails for unknown tool key", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "unknown", {
            api_key = "k",
        })
        assert.isFalse(ok)
    end),

    test("upsert fails validation (missing api_key)", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "serpapi", {
        })
        assert.isFalse(ok)
    end),

    test("upsert works without display_name", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "tavilyapi", {
            api_key = "tvly-456",
        })
        assert.isTrue(ok)
        assert.equal(data.tools.tavilyapi.api_key, "tvly-456")
        assert.equal(data.tools.tavilyapi.display_name, nil)
    end),

    test("upsert works for searxngapi with only base_url", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "searxngapi", {
            base_url = "https://sx.example.com",
        })
        assert.isTrue(ok)
        assert.equal(data.tools.searxngapi.base_url, "https://sx.example.com")
        assert.equal(data.tools.searxngapi.display_name, nil)
    end),

    -- =========================================================================
    -- Delete
    -- =========================================================================

    test("delete removes an existing tool", function()
        local data = { tools = {} }
        data.tools.serpapi = { api_key = "k" }
        local ok, err = SearchRegistry.delete(data, "serpapi")
        assert.isTrue(ok)
        assert.equal(data.tools.serpapi, nil)
    end),

    test("delete fails for non-existent tool", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.delete(data, "serpapi")
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("delete does not affect other tools", function()
        local data = { tools = {} }
        data.tools.serpapi = { api_key = "k" }
        data.tools.tavilyapi = { api_key = "k" }
        SearchRegistry.delete(data, "serpapi")
        assert.equal(data.tools.serpapi, nil)
        assert.notNil(data.tools.tavilyapi)
    end),

    -- =========================================================================
    -- is_deletable
    -- =========================================================================

    test("is_deletable returns true for source=ui", function()
        assert.isTrue(SearchRegistry.is_deletable({ source = "ui" }))
    end),

    test("is_deletable returns false for source=file", function()
        assert.equal(SearchRegistry.is_deletable({ source = "file", immutable = true }), false)
    end),

    test("is_deletable returns false for nil", function()
        assert.equal(SearchRegistry.is_deletable(nil), nil)
    end),

    -- =========================================================================
    -- installSearchTool
    -- =========================================================================

    test("installSearchTool validates, saves, and updates merged config (no display_name)", function()
        local assistant = mockAssistant()
        local ok, err = SearchRegistry.installSearchTool(
            assistant, "serpapi", "sk-123", nil)
        assert.isTrue(ok, err)
        assert.isTrue(assistant.updated)

        -- Verify merged config updated
        local merged = assistant.CONFIGURATION.provider_settings.serpapi
        assert.notNil(merged)
        assert.equal(merged.api_key, "sk-123")
        assert.equal(merged.source, "ui")
        -- display_name must NOT be in the stored record
        assert.equal(merged.display_name, nil)
    end),

    test("installSearchTool for searxng sets base_url (no display_name)", function()
        local assistant = mockAssistant()
        local ok, err = SearchRegistry.installSearchTool(
            assistant, "searxngapi", nil, "https://sx.example.com")
        assert.isTrue(ok, err)
        local merged = assistant.CONFIGURATION.provider_settings.searxngapi
        assert.notNil(merged)
        assert.equal(merged.base_url, "https://sx.example.com")
        assert.equal(merged.source, "ui")
        assert.equal(merged.display_name, nil)
    end),

    test("installSearchTool fails without initialized data", function()
        local assistant = { _ui_search_data = nil }
        local ok, err = SearchRegistry.installSearchTool(
            assistant, "serpapi", "k", nil)
        assert.isFalse(ok)
    end),

    test("installSearchTool stores api_key only, no display_name in ui_search_tools", function()
        local assistant = mockAssistant()
        SearchRegistry.installSearchTool(assistant, "tavilyapi", "tvly-789", nil)
        local stored = assistant._ui_search_data.tools.tavilyapi
        assert.notNil(stored)
        assert.equal(stored.api_key, "tvly-789")
        assert.equal(stored.display_name, nil)
    end),

    -- =========================================================================
    -- getAddWebSearchMenuItem
    -- =========================================================================

    test("menu item text is localized", function()
        local assistant = mockAssistant()
        local item = SearchRegistry.getAddWebSearchMenuItem(assistant)
        assert.equal(item.text, "Add Web Search API")
        assert.equal(item.keep_menu_open, true)
        assert.notNil(item.sub_item_table_func)
    end),

    test("sub-menu lists all four search tools", function()
        local assistant = mockAssistant()
        local item = SearchRegistry.getAddWebSearchMenuItem(assistant)
        local sub_items = item.sub_item_table_func()
        assert.equal(#sub_items, 4)
    end),

    test("sub-menu items have correct display names from SEARCH_TOOLS", function()
        local assistant = mockAssistant()
        local item = SearchRegistry.getAddWebSearchMenuItem(assistant)
        local sub_items = item.sub_item_table_func()
        assert.equal(sub_items[1].text, "SerpAPI")
        assert.equal(sub_items[2].text, "Tavily")
        assert.equal(sub_items[3].text, "Exa.ai")
        assert.equal(sub_items[4].text, "SearXNG")
    end),

    test("sub-menu items have callbacks", function()
        local assistant = mockAssistant()
        local item = SearchRegistry.getAddWebSearchMenuItem(assistant)
        local sub_items = item.sub_item_table_func()
        for i, sub_item in ipairs(sub_items) do
            assert.notNil(sub_item.callback, "sub_item " .. i .. " should have callback")
        end
    end),

    test("sub-menu items keep menu open", function()
        local assistant = mockAssistant()
        local item = SearchRegistry.getAddWebSearchMenuItem(assistant)
        local sub_items = item.sub_item_table_func()
        for _, sub_item in ipairs(sub_items) do
            assert.equal(sub_item.keep_menu_open, true)
        end
    end),

    test("sub-menu items have a hold_callback for long-press actions", function()
        local assistant = mockAssistant()
        local item = SearchRegistry.getAddWebSearchMenuItem(assistant)
        local sub_items = item.sub_item_table_func()
        for i, sub_item in ipairs(sub_items) do
            assert.notNil(sub_item.hold_callback, "sub_item " .. i .. " should have hold_callback")
        end
    end),
}

return helper.runTests("assistant_search_registry", tests)
