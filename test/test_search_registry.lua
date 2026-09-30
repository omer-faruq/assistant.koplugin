-- test_search_registry.lua
-- Tests for assistant_search_registry.lua: load/save, validate, merge, upsert,
-- delete/deleteSearchTool, installSearchTool and the WebSearch API menu factory.
-- The tool catalog itself (tool keys, `needs`, display names) lives in
-- assistant_search_tools.lua and is asserted through the registry consumers.
local helper = require("test.helper")
local assert = helper.assert
local SearchRegistry = require("assistant_search_registry")
local SearchTools = require("assistant_search_tools")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- A mock LuaSettings that persists in memory.
local function mockSettings()
    local store = {}
    return {
        readSetting = function(_, key) return store[key] end,
        saveSetting = function(_, key, val) store[key] = val end,
        delSetting = function(_, key) store[key] = nil end,
        _store = store,
    }
end

-- A mock Assistant exposing only what SearchRegistry touches: the UI tool
-- data, a settings store and the search-tool half of assistant.config's API
-- (getProvider / setSearchTool / deleteSearchTool).
local function mockAssistant(search_data)
    local settings = mockSettings()
    local provider_settings = {}
    return {
        _ui_search_data = search_data or { tools = {} },
        settings = settings,
        -- Records the delete requests the menu fires.
        deleted = {},
        config = {
            _data = { provider_settings = provider_settings },
            getProvider = function(_, key) return provider_settings[key] end,
            setSearchTool = function(_, key, record)
                provider_settings[key] = record
                return true
            end,
            deleteSearchTool = function(_, key)
                provider_settings[key] = nil
                return true
            end,
        },
    }
end

-- Captures the options table passed to ButtonDialog:new while fn runs
-- (the helper stub returns that table verbatim from new()).
local function captureButtonDialog(fn)
    local BD = require("ui/widget/buttondialog")
    local captured
    local orig_new = BD.new
    BD.new = function(_, o) captured = o; return o end
    local ok, err = pcall(fn)
    BD.new = orig_new
    if not ok then error(err) end
    return captured
end

-- Splits a sub-menu label into its leading selection marker and the rest
-- (the tool display name). Avoids pinning a specific glyph codepoint.
local function splitLabel(label)
    local marker, rest = label:match("^(%S+)%s+(.+)$")
    assert.notNil(marker, "sub-menu label should be '<marker> <name>', got: " .. tostring(label))
    return marker, rest
end

-- Finds a button in a hand-built dialog by its translated text.
local function buttonByText(dialog, text)
    for i, row in ipairs(dialog.buttons) do
        for j, button in ipairs(row) do
            if button.text == text then return button end
        end
    end
    return nil
end

local tests = {

    -- =========================================================================
    -- Search tool catalog (assistant_search_tools)
    -- =========================================================================

    test("TOOL_KEYS lists the four fixed tool keys in order", function()
        assert.equal(#SearchTools.TOOL_KEYS, 4)
        assert.equal(SearchTools.TOOL_KEYS[1], "serpapi")
        assert.equal(SearchTools.TOOL_KEYS[2], "tavilyapi")
        assert.equal(SearchTools.TOOL_KEYS[3], "exaapi")
        assert.equal(SearchTools.TOOL_KEYS[4], "searxngapi")
    end),

    test("every TOOL_KEYS entry has a definition with display_name", function()
        for i, key in ipairs(SearchTools.TOOL_KEYS) do
            local def = SearchTools.getDefinition(key)
            assert.notNil(def, "no definition for " .. key)
            assert.notNil(def.needs, key .. " has no needs field")
            assert.notNil(def.display_name, key .. " has no display_name")
        end
    end),

    test("tools are declared with the credential they need", function()
        assert.equal(SearchTools.getDefinition("serpapi").needs, "api_key")
        assert.equal(SearchTools.getDefinition("tavilyapi").needs, "api_key")
        assert.equal(SearchTools.getDefinition("exaapi").needs, "api_key")
        assert.equal(SearchTools.getDefinition("searxngapi").needs, "base_url")
    end),

    test("MENU_ORDER is none, builtin then the tool keys", function()
        assert.equal(#SearchTools.MENU_ORDER, #SearchTools.TOOL_KEYS + 2)
        assert.equal(SearchTools.MENU_ORDER[1], SearchTools.NONE)
        assert.equal(SearchTools.MENU_ORDER[2], SearchTools.BUILTIN)
        for i, tool_key in ipairs(SearchTools.TOOL_KEYS) do
            assert.equal(SearchTools.MENU_ORDER[i + 2], tool_key)
        end
    end),

    test("isEnabledMode accepts only builtin and known tool keys", function()
        assert.isTrue(SearchTools.isEnabledMode(SearchTools.BUILTIN))
        for i, tool_key in ipairs(SearchTools.TOOL_KEYS) do
            assert.isTrue(SearchTools.isEnabledMode(tool_key))
        end
        for idx, bad in ipairs({ "none", "", "tavily", "serpapi ", "Builtin", "typo" }) do
            assert.isFalse(SearchTools.isEnabledMode(bad), tostring(bad) .. " must fail closed")
        end
        assert.isFalse(SearchTools.isEnabledMode(nil))
        assert.isFalse(SearchTools.isEnabledMode(false))
    end),

    -- =========================================================================
    -- Load / Save
    -- =========================================================================

    test("load returns empty structure when no setting exists", function()
        local data = SearchRegistry.load(mockSettings())
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

    test("load tolerates records carrying a legacy display_name", function()
        local settings = mockSettings()
        settings:saveSetting("ui_search_tools",
            '{"schema_version":1,"tools":{"serpapi":{"display_name":"Old","api_key":"sk-123"}}}')
        local data = SearchRegistry.load(settings)
        assert.equal(data.tools.serpapi.api_key, "sk-123")
    end),

    -- =========================================================================
    -- Validate
    -- =========================================================================

    test("validate accepts an api_key tool with a key", function()
        local ok, err = SearchRegistry.validate({
            api_key = "sk-123",
        }, "serpapi")
        assert.isTrue(ok, err)
    end),

    test("validate ignores a display_name in the record", function()
        local ok, err = SearchRegistry.validate({
            display_name = "SerpAPI",
            api_key = "sk-123",
        }, "serpapi")
        assert.isTrue(ok, err)
    end),

    test("validate fails for an api_key tool without api_key", function()
        local ok, err = SearchRegistry.validate({
        }, "serpapi")
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("validate fails for an api_key tool with a blank api_key", function()
        local ok, err = SearchRegistry.validate({
            api_key = "   ",
        }, "serpapi")
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("validate accepts the base_url tool with an https URL", function()
        local ok, err = SearchRegistry.validate({
            base_url = "https://search.example.com",
        }, "searxngapi")
        assert.isTrue(ok, err)
    end),

    test("validate fails for the base_url tool without base_url", function()
        local ok, err = SearchRegistry.validate({
        }, "searxngapi")
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("validate fails for the base_url tool with a scheme-less URL", function()
        local ok, err = SearchRegistry.validate({
            base_url = "not-a-url",
        }, "searxngapi")
        assert.isFalse(ok)
        assert.notNil(err)
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

    test("merge copies records instead of aliasing the sources", function()
        local file_record = { api_key = "file-key" }
        local ui_record = { api_key = "ui-key" }
        local merged = SearchRegistry.merge(
            { provider_settings = { serpapi = file_record } },
            { tools = { tavilyapi = ui_record } })
        merged.serpapi.api_key = "mutated"
        merged.tavilyapi.api_key = "mutated"
        assert.equal(file_record.api_key, "file-key")
        assert.equal(ui_record.api_key, "ui-key")
    end),

    -- =========================================================================
    -- Upsert
    -- =========================================================================

    test("upsert inserts a new tool record", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "serpapi", {
            api_key = "sk-123",
        })
        assert.isTrue(ok, err)
        assert.equal(data.tools.serpapi.api_key, "sk-123")
    end),

    test("upsert ignores display_name in input record", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "serpapi", {
            display_name = "Should Not Be Saved",
            api_key = "sk-123",
        })
        assert.isTrue(ok, err)
        assert.equal(data.tools.serpapi.display_name, nil,
            "display_name must never be stored in the record")
    end),

    test("upsert overwrites an existing tool record (update)", function()
        local data = { tools = {} }
        SearchRegistry.upsert(data, "serpapi", { api_key = "old-key" })
        local ok, err = SearchRegistry.upsert(data, "serpapi", { api_key = "new-key" })
        assert.isTrue(ok, err)
        assert.equal(data.tools.serpapi.api_key, "new-key")
    end),

    test("upsert overwrites the whole record, clearing the other credential", function()
        local data = { tools = {} }
        SearchRegistry.upsert(data, "searxngapi", { base_url = "https://old.example.com" })
        data.tools.searxngapi.api_key = "stale-key"
        local ok, err = SearchRegistry.upsert(data, "searxngapi", {
            base_url = "https://new.example.com",
        })
        assert.isTrue(ok, err)
        assert.equal(data.tools.searxngapi.base_url, "https://new.example.com")
        assert.equal(data.tools.searxngapi.api_key, nil,
            "an update must not leave a stale credential of the other kind behind")
    end),

    test("upsert drops the credential the tool never uses", function()
        local data = { tools = {} }
        -- serpapi needs only api_key; a base_url supplied by the caller must not
        -- be persisted.
        local ok, err = SearchRegistry.upsert(data, "serpapi", {
            api_key = "sk-123",
            base_url = "https://stale.example.com",
        })
        assert.isTrue(ok, err)
        assert.equal(data.tools.serpapi.api_key, "sk-123")
        assert.equal(data.tools.serpapi.base_url, nil,
            "serpapi never reads base_url, so it must not be stored")

        -- ...and symmetrically for a base_url-only tool.
        local ok2, err2 = SearchRegistry.upsert(data, "searxngapi", {
            base_url = "https://sx.example.com",
            api_key = "unused-key",
        })
        assert.isTrue(ok2, err2)
        assert.equal(data.tools.searxngapi.base_url, "https://sx.example.com")
        assert.equal(data.tools.searxngapi.api_key, nil,
            "searxngapi never reads api_key, so it must not be stored")
    end),

    test("installSearchTool pushes only the tool's own credential to the config", function()
        local data = { tools = {} }
        local assistant = mockAssistant(data)
        local ok, err = SearchRegistry.installSearchTool(assistant, "serpapi",
            "sk-live", "https://stale.example.com")
        assert.isTrue(ok, err)
        assert.equal(assistant.config:getProvider("serpapi").api_key, "sk-live")
        assert.equal(assistant.config:getProvider("serpapi").base_url, nil)
        assert.equal(assistant.config:getProvider("serpapi").source, "ui")
    end),

    test("upsert fails for unknown tool key", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "unknown", { api_key = "k" })
        assert.isFalse(ok)
    end),

    test("upsert fails validation (missing api_key)", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "serpapi", {})
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("upsert works for searxngapi with only base_url", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "searxngapi", {
            base_url = "https://sx.example.com",
        })
        assert.isTrue(ok, err)
        assert.equal(data.tools.searxngapi.base_url, "https://sx.example.com")
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
    -- installSearchTool / deleteSearchTool
    -- =========================================================================

    test("installSearchTool validates, saves, and updates merged config", function()
        local assistant = mockAssistant()
        local ok, err = SearchRegistry.installSearchTool(assistant, "serpapi", "sk-123", nil)
        assert.isTrue(ok, err)
        local merged = assistant.config._data.provider_settings.serpapi
        assert.notNil(merged)
        assert.equal(merged.api_key, "sk-123")
        assert.equal(merged.source, "ui")
        -- the credential must survive a restart, not just live in memory
        local reloaded = SearchRegistry.load(assistant.settings)
        assert.equal(reloaded.tools.serpapi.api_key, "sk-123")
    end),

    test("installSearchTool for searxng sets base_url", function()
        local assistant = mockAssistant()
        local ok, err = SearchRegistry.installSearchTool(
            assistant, "searxngapi", nil, "https://sx.example.com")
        assert.isTrue(ok, err)
        local merged = assistant.config._data.provider_settings.searxngapi
        assert.notNil(merged)
        assert.equal(merged.base_url, "https://sx.example.com")
        assert.equal(merged.source, "ui")
    end),

    test("installSearchTool fails without initialized data", function()
        local assistant = { _ui_search_data = nil }
        local ok, err = SearchRegistry.installSearchTool(assistant, "serpapi", "k", nil)
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("installSearchTool rejects a bad credential without persisting it", function()
        local assistant = mockAssistant()
        local ok, err = SearchRegistry.installSearchTool(assistant, "serpapi", "  ", nil)
        assert.isFalse(ok)
        assert.equal(assistant._ui_search_data.tools.serpapi, nil)
        assert.equal(assistant.settings:readSetting("ui_search_tools"), nil)
    end),

    test("deleteSearchTool clears the record, the settings and the merged config", function()
        local assistant = mockAssistant()
        assert.isTrue(SearchRegistry.installSearchTool(assistant, "serpapi", "sk-123", nil))

        local ok, err = SearchRegistry.deleteSearchTool(assistant, "serpapi")
        assert.isTrue(ok, err)
        assert.equal(assistant._ui_search_data.tools.serpapi, nil)
        assert.equal(assistant.config._data.provider_settings.serpapi, nil)
        local reloaded = SearchRegistry.load(assistant.settings)
        assert.equal(reloaded.tools.serpapi, nil)
    end),

    test("deleteSearchTool fails for an unconfigured tool", function()
        local assistant = mockAssistant()
        local ok, err = SearchRegistry.deleteSearchTool(assistant, "tavilyapi")
        assert.isFalse(ok)
        assert.notNil(err)
        assert.equal(assistant.settings:readSetting("ui_search_tools"), nil,
            "a failed delete must not rewrite the settings")
    end),

    test("deleteSearchTool fails without initialized data", function()
        local assistant = { _ui_search_data = nil, config = {} }
        local ok, err = SearchRegistry.deleteSearchTool(assistant, "serpapi")
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    -- =========================================================================
    -- getAddWebSearchMenuItem
    -- =========================================================================

    test("menu item text is localized", function()
        local item = SearchRegistry.getAddWebSearchMenuItem(mockAssistant())
        assert.equal(item.text, "WebSearch API")
        assert.equal(item.keep_menu_open, true)
        assert.notNil(item.sub_item_table_func)
    end),

    test("sub-menu lists one entry per tool key, labelled with its display name", function()
        local sub_items = SearchRegistry.getAddWebSearchMenuItem(mockAssistant()).sub_item_table_func()
        assert.equal(#sub_items, #SearchTools.TOOL_KEYS)
        for i, key in ipairs(SearchTools.TOOL_KEYS) do
            local marker, name = splitLabel(sub_items[i].text_func())
            assert.notNil(marker)
            assert.equal(name, SearchTools.getDefinition(key).display_name,
                "sub-menu entry " .. i .. " should be labelled with the tool's display name")
        end
    end),

    test("unconfigured tools all share the same (unselected) marker", function()
        local sub_items = SearchRegistry.getAddWebSearchMenuItem(mockAssistant()).sub_item_table_func()
        local first = splitLabel(sub_items[1].text_func())
        for i = 2, #sub_items do
            local marker = splitLabel(sub_items[i].text_func())
            assert.equal(marker, first,
                "sub-menu entry " .. i .. " should use the same unselected marker")
        end
    end),

    test("sub-menu marks a tool configured via api_key as selected", function()
        local assistant = mockAssistant()
        assistant.config._data.provider_settings.serpapi = { api_key = "sk-test" }
        local sub_items = SearchRegistry.getAddWebSearchMenuItem(assistant).sub_item_table_func()
        local selected = splitLabel(sub_items[1].text_func())
        local unselected = splitLabel(sub_items[2].text_func())
        assert.isFalse(selected == unselected,
            "a tool with an api_key must not use the unselected marker")
    end),

    test("sub-menu marks a tool configured via base_url as selected", function()
        local assistant = mockAssistant()
        assistant.config._data.provider_settings.searxngapi = { base_url = "https://search.example.com" }
        local sub_items = SearchRegistry.getAddWebSearchMenuItem(assistant).sub_item_table_func()
        local selected = splitLabel(sub_items[4].text_func())
        local unselected = splitLabel(sub_items[3].text_func())
        assert.isFalse(selected == unselected,
            "a tool with a base_url must not use the unselected marker")
    end),

    test("sub-menu leaves a configured-but-empty credential unselected", function()
        local assistant = mockAssistant()
        assistant.config._data.provider_settings.serpapi = { api_key = "" }
        local sub_items = SearchRegistry.getAddWebSearchMenuItem(assistant).sub_item_table_func()
        local marker = splitLabel(sub_items[1].text_func())
        local unselected = splitLabel(sub_items[2].text_func())
        assert.equal(marker, unselected, "an empty api_key counts as unconfigured")
    end),

    test("sub-menu entry opens the web-search dialog for its own tool", function()
        local assistant = mockAssistant()
        assistant.calls = {}
        assistant._showAddWebSearchDialog = function(self, tool_key)
            self.calls[#self.calls + 1] = tool_key
        end
        local sub_items = SearchRegistry.getAddWebSearchMenuItem(assistant).sub_item_table_func()
        for i, sub_item in ipairs(sub_items) do
            assert.notNil(sub_item.callback, "sub_item " .. i .. " should have a callback")
            assert.isTrue(sub_item.keep_menu_open, "sub_item " .. i .. " should keep the menu open")
            sub_item.callback()
        end
        assert.equal(#assistant.calls, #SearchTools.TOOL_KEYS)
        for i, key in ipairs(SearchTools.TOOL_KEYS) do
            assert.equal(assistant.calls[i], key,
                "sub_item " .. i .. " must open the dialog for " .. key)
        end
    end),

    test("long-press offers Edit/Delete and only enables Delete for a UI tool", function()
        local assistant = mockAssistant()
        assistant.config._data.provider_settings.serpapi = { api_key = "sk-test", source = "ui" }
        assistant.config._data.provider_settings.exaapi = { api_key = "file-key", source = "file", immutable = true }
        local sub_items = SearchRegistry.getAddWebSearchMenuItem(assistant).sub_item_table_func()
        for i, sub_item in ipairs(sub_items) do
            assert.notNil(sub_item.hold_callback, "sub_item " .. i .. " should have a hold_callback")
        end

        local dialog = captureButtonDialog(function()
            sub_items[1].hold_callback()
        end)
        assert.notNil(buttonByText(dialog, "Edit"), "long press must offer Edit")
        assert.equal(buttonByText(dialog, "Delete").enabled, true,
            "a UI tool must be deletable")

        local file_dialog = captureButtonDialog(function()
            sub_items[3].hold_callback()
        end)
        assert.equal(buttonByText(file_dialog, "Delete").enabled, false,
            "a file-configured tool must not be deletable")
    end),

    test("long-press Delete removes the tool through the menu path", function()
        local assistant = mockAssistant()
        assert.isTrue(SearchRegistry.installSearchTool(assistant, "serpapi", "sk-123", nil))
        local sub_items = SearchRegistry.getAddWebSearchMenuItem(assistant).sub_item_table_func()
        local dialog = captureButtonDialog(function()
            sub_items[1].hold_callback()
        end)
        buttonByText(dialog, "Delete").callback()
        assert.equal(assistant._ui_search_data.tools.serpapi, nil)
        assert.equal(assistant.config._data.provider_settings.serpapi, nil)
    end),

    -- =========================================================================
    -- Whitespace normalization
    -- =========================================================================

    test("validate trims surrounding whitespace in api_key", function()
        local record = { api_key = "  sk-123\r\n  " }
        local ok, err = SearchRegistry.validate(record, "serpapi")
        assert.isTrue(ok, err)
        assert.equal(record.api_key, "sk-123")
    end),

    test("upsert stores the trimmed api_key", function()
        local data = { tools = {} }
        local ok, err = SearchRegistry.upsert(data, "serpapi", {
            api_key = "  sk-123\r\n  ",
        })
        assert.isTrue(ok, err)
        assert.equal(data.tools.serpapi.api_key, "sk-123")
    end),

    test("validate rejects internal whitespace in api_key", function()
        local ok, err = SearchRegistry.validate({
            api_key = "sk-123 xyz",
        }, "serpapi")
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("validate trims surrounding whitespace in searxng base_url", function()
        local record = { base_url = "  https://searx.example.com/  " }
        local ok, err = SearchRegistry.validate(record, "searxngapi")
        assert.isTrue(ok, err)
        assert.equal(record.base_url, "https://searx.example.com/")
    end),

    test("validate rejects internal whitespace in searxng base_url", function()
        local ok, err = SearchRegistry.validate({
            base_url = "https://searx.exa mple.com",
        }, "searxngapi")
        assert.isFalse(ok)
        assert.notNil(err)
    end),
}

return helper.runTests("assistant_search_registry", tests)
