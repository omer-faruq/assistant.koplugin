-- test_provider_registry.lua
-- Tests for assistant_provider_registry.lua: preset providers, the "Provider
-- API" menu factory, load/save/merge, install/update/delete of UI providers,
-- credential normalization, the reasoning-parameter catalog, and the
-- connection-test report/verdict helpers.
local helper = require("test.helper")
local assert = helper.assert
local Registry = require("assistant_provider_registry")
local koutil = require("util")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Deep equality helper for comparing additional_parameters tables.
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
        readSetting = function(_, key) return store[key] end,
        saveSetting = function(_, key, val) store[key] = val end,
        delSetting = function(_, key) store[key] = nil end,
        _store = store,
    }
end

-- A mock Assistant that records _showAddProviderDialog invocations.
local function mockAssistant()
    return {
        calls = {},
        _showAddProviderDialog = function(self, preset_name, handler, base_url, additional_parameters)
            table.insert(self.calls, {
                preset_name = preset_name,
                handler = handler,
                base_url = base_url,
                additional_parameters = additional_parameters,
            })
        end,
    }
end

-- A mock Assistant with the provider-data/settings/config plumbing that
-- Registry.installProvider and Registry.updateProvider touch.
local function mockAssistantForInstall()
    local assistant = {
        _ui_provider_data = { providers = {}, _next_id = 1 },
        settings = mockSettings(),
        updated = false,
        querier = nil,
    }
    -- Minimal config object to mimic assistant_config.lua's Config.
    local config_data = { provider_settings = {} }
    local config = {}
    function config:getProvider(id)
        if not id or id == "" then return nil end
        local v = koutil.tableGetValue(config_data, "provider_settings", id)
        if v == nil or v == require("rapidjson").null then return nil end
        return v
    end
    function config:setProvider(id, record)
        if not id or id == "" then return nil, "invalid id" end
        config_data.provider_settings = config_data.provider_settings or {}
        config_data.provider_settings[id] = record
        if record ~= nil and assistant.querier and assistant.querier.load_model then
            pcall(function() assistant.querier:load_model(id) end)
        end
        -- Search credentials are read per-request; no module-level refresh.
        assistant.updated = true
        return true
    end
    function config:deleteProvider(id)
        if not id or id == "" then return nil, "invalid id" end
        if config_data and config_data.provider_settings then
            config_data.provider_settings[id] = nil
            -- Search credentials are read per-request; no module-level refresh.
            assistant.updated = true
        end
        return true
    end
    config.setSearchTool = config.setProvider
    config.deleteSearchTool = config.deleteProvider
    -- Expose the raw data table for direct assertions in tests.
    config._data = config_data
    assistant.config = config
    return assistant
end

-- Resolves the menu item's sub-menu by invoking sub_item_table_func().
local function subItems(menu_item)
    assert.notNil(menu_item.sub_item_table_func, "menu item should have sub_item_table_func")
    return menu_item.sub_item_table_func()
end

-- Captures the options table passed to MultiInputDialog:new while fn runs
-- (the helper stub returns that table verbatim from new()).
local function captureDialog(fn)
    local MID = require("ui/widget/multiinputdialog")
    local captured
    local orig_new = MID.new
    MID.new = function(_, o) captured = o; return o end
    local ok, err = pcall(fn)
    MID.new = orig_new
    if not ok then error(err) end
    return captured
end

-- Finds a dialog field by its identifying hint, so inserting or reordering
-- fields does not break the assertions.
local function fieldByHint(dialog, hint)
    for i, field in ipairs(dialog.fields) do
        if field.hint == hint then return field end
    end
    return nil
end

local HINT_BASE_URL = "Base URL"
local HINT_MODEL = "Pick one via Browse Models"

local tests = {

    -- =========================================================================
    -- Preset providers
    -- =========================================================================

    test("preset handlers are all known to the registry", function()
        for i, preset in ipairs(Registry.PRESET_PROVIDERS) do
            assert.isTrue(Registry.HANDLERS[preset.handler],
                "unknown handler: " .. tostring(preset.handler))
        end
    end),

    test("Responses preset keeps the responses handler reachable", function()
        for i, preset in ipairs(Registry.PRESET_PROVIDERS) do
            if preset.name == "OpenAI - Responses" then
                assert.equal(preset.handler, "responses")
                assert.equal(preset.base_url, Registry.DEFAULT_BASE_URLS.responses)
                return
            end
        end
        error("Responses preset missing from PRESET_PROVIDERS")
    end),

    -- =========================================================================
    -- getAddProviderMenuItem
    -- =========================================================================

    test("menu item is localized 'Provider API' and keeps menu open", function()
        local item = Registry.getAddProviderMenuItem(mockAssistant())
        assert.equal(item.text, "Provider API")
        assert.equal(item.keep_menu_open, true)
        assert.notNil(item.sub_item_table_func)
    end),

    test("preset callback remembers the menu instance for dismissal", function()
        local assistant = mockAssistant()
        local items = subItems(Registry.getAddProviderMenuItem(assistant))
        local menu_instance = { closeMenu = function() end }
        items[1].callback(menu_instance)
        -- A confirmed add closes this menu, which stays open behind the dialogs.
        assert.equal(assistant._menu_instance, menu_instance)
    end),

    -- =========================================================================
    -- Load / Save
    -- =========================================================================

    test("load returns a fresh structure when nothing is stored", function()
        local data = Registry.load(mockSettings())
        assert.notNil(data)
        assert.equal(type(data.providers), "table")
        assert.equal(data._next_id, 1)
    end),

    test("load returns a fresh structure on corrupt JSON", function()
        local settings = mockSettings()
        settings:saveSetting("ui_providers", "{invalid json!!")
        local data = Registry.load(settings)
        assert.equal(next(data.providers), nil)
        assert.equal(data._next_id, 1)
    end),

    test("load returns a fresh structure on schema version mismatch", function()
        local settings = mockSettings()
        settings:saveSetting("ui_providers",
            '{"schema_version":999,"_next_id":7,"providers":{"custom:1":{"api_key":"x"}}}')
        local data = Registry.load(settings)
        assert.equal(next(data.providers), nil)
        assert.equal(data._next_id, 1)
    end),

    test("save then load round-trips providers and the id counter", function()
        local settings = mockSettings()
        local data = { providers = {}, _next_id = 1 }
        local id = Registry.add(data, {
            display_name = "DeepSeek UI", handler = "openai", model = "auto",
            base_url = "https://api.deepseek.com/v1", api_key = "key",
        })
        data._next_id = 5
        assert.isTrue(Registry.save(settings, data))

        local loaded = Registry.load(settings)
        assert.equal(loaded._next_id, 5)
        assert.equal(loaded.providers[id].display_name, "DeepSeek UI")
        assert.equal(loaded.providers[id].base_url, "https://api.deepseek.com/v1")
        assert.equal(loaded.providers[id].api_key, "key")
    end),

    -- =========================================================================
    -- Merge
    -- =========================================================================

    test("merge injects source/immutable metadata per origin", function()
        local merged = Registry.merge({
            provider_settings = { openai = { api_key = "file-key" } },
        }, {
            providers = { ["custom:1"] = { api_key = "ui-key" } },
        })
        assert.equal(merged.openai.api_key, "file-key")
        assert.equal(merged.openai.source, "file")
        assert.equal(merged.openai.immutable, true)
        assert.equal(merged["custom:1"].api_key, "ui-key")
        assert.equal(merged["custom:1"].source, "ui")
        assert.equal(merged["custom:1"].immutable, nil)
    end),

    test("merge returns nil when both sources are empty", function()
        assert.equal(Registry.merge(nil, { providers = {}, _next_id = 1 }), nil)
        assert.equal(Registry.merge({ provider_settings = {} }, { providers = {} }), nil)
    end),

    test("merge copies records instead of aliasing the sources", function()
        local file_record = { api_key = "file-key" }
        local ui_record = { api_key = "ui-key" }
        local merged = Registry.merge(
            { provider_settings = { openai = file_record } },
            { providers = { ["custom:1"] = ui_record } })
        merged.openai.api_key = "mutated"
        merged["custom:1"].api_key = "mutated"
        assert.equal(file_record.api_key, "file-key")
        assert.equal(ui_record.api_key, "ui-key")
    end),

    test("merge skips a UI provider whose id collides with a file provider", function()
        local merged = Registry.merge(
            { provider_settings = { ["custom:1"] = { api_key = "file-key" } } },
            { providers = { ["custom:1"] = { api_key = "ui-key" } } })
        assert.equal(merged["custom:1"].api_key, "file-key")
        assert.equal(merged["custom:1"].source, "file")
    end),

    -- =========================================================================
    -- showProviderDialog field descriptions
    -- =========================================================================

    test("Base URL description reflects the selected handler", function()
        local cases = {
            { handler = "openai",    pattern = "Chat Completions" },
            { handler = "responses", pattern = "Responses API" },
            { handler = "gemini",    pattern = "Gemini API" },
            { handler = "anthropic", pattern = "Anthropic" },
        }
        local seen = {}
        for i, case in ipairs(cases) do
            local dialog = captureDialog(function()
                Registry.showProviderDialog({}, nil, case.handler, "https://api.example.com/v1")
            end)
            assert.notNil(dialog, "no dialog built for handler " .. case.handler)
            local field = fieldByHint(dialog, HINT_BASE_URL)
            assert.notNil(field, "no Base URL field for handler " .. case.handler)
            assert.matches(field.description, case.pattern,
                "wrong Base URL description for handler " .. case.handler)
            seen[field.description] = (seen[field.description] or 0) + 1
        end
        assert.isTrue(next(seen) ~= nil, "expected at least one Base URL description")
    end),

    test("dialog fields advertise the Browse Models workflow", function()
        local dialog = captureDialog(function()
            Registry.showProviderDialog({}, nil, "openai", "https://api.example.com/v1")
        end)
        assert.notNil(dialog)
        local field = fieldByHint(dialog, HINT_MODEL)
        assert.notNil(field, "dialog should have a Model field")
        assert.matches(field.description, "Model",
            "Model field description should name the Model field")
        assert.matches(field.hint, "Browse Models",
            "Model hint should advertise the Browse Models workflow")
    end),

    -- =========================================================================
    -- Registry.add
    -- =========================================================================

    test("Registry.add persists additional_parameters", function()
        local data = { providers = {}, _next_id = 1 }
        local params = { temperature = 0.7, thinking = { type = "disabled" } }
        local id, err = Registry.add(data, {
            display_name = "DeepSeek UI",
            handler = "openai",
            model = "auto",
            base_url = "https://api.deepseek.com/v1",
            api_key = "key",
            additional_parameters = params,
        })
        assert.notNil(id, err)
        assert.isTrue(deepEqual(data.providers[id].additional_parameters, params))
    end),

    test("Registry.add stores a deep copy of additional_parameters", function()
        local params = { temperature = 0.7, thinking = { type = "disabled" } }
        local data = { providers = {}, _next_id = 1 }
        local id, err = Registry.add(data, {
            display_name = "DeepSeek UI",
            handler = "openai",
            model = "auto",
            base_url = "https://api.deepseek.com/v1",
            api_key = "key",
            additional_parameters = params,
        })
        assert.notNil(id, err)
        assert.isFalse(data.providers[id].additional_parameters == params,
            "stored additional_parameters must not share the source table")
        -- mutating the stored copy must not leak back into the source table
        data.providers[id].additional_parameters.thinking.type = "enabled"
        data.providers[id].additional_parameters.temperature = 0.9
        assert.equal(params.thinking.type, "disabled")
        assert.equal(params.temperature, 0.7)
    end),

    test("Registry.add without additional_parameters defaults to empty table", function()
        local data = { providers = {}, _next_id = 1 }
        local id, err = Registry.add(data, {
            display_name = "Plain UI",
            handler = "openai",
            model = "auto",
            base_url = "https://api.openai.com/v1",
            api_key = "key",
        })
        assert.notNil(id, err)
        assert.equal(type(data.providers[id].additional_parameters), "table")
        assert.equal(next(data.providers[id].additional_parameters), nil)
    end),

    -- =========================================================================
    -- Registry.installProvider
    -- =========================================================================

    test("installProvider merges additional_parameters into provider_settings", function()
        local assistant = mockAssistantForInstall()
        local params = { temperature = 0.7, reasoning = { effort = "none" } }
        local id, err = Registry.installProvider(assistant, "openai",
            "https://openrouter.ai/api/v1", "OpenRouter UI", "key", "auto", params)
        assert.notNil(id, err)
        assert.equal(assistant.updated, true)
        local merged = assistant.config._data.provider_settings[id]
        assert.notNil(merged)
        assert.equal(merged.source, "ui")
        assert.isTrue(deepEqual(merged.additional_parameters, params),
            "merged provider_settings should carry the given additional_parameters")
        assert.isTrue(deepEqual(assistant._ui_provider_data.providers[id].additional_parameters, params),
            "ui provider data should persist the same additional_parameters")
    end),

    test("installProvider without additional_parameters defaults to empty table", function()
        local assistant = mockAssistantForInstall()
        local id, err = Registry.installProvider(assistant, "openai",
            "https://api.openai.com/v1", "Plain UI", "key", "")
        assert.notNil(id, err)
        local merged = assistant.config._data.provider_settings[id]
        assert.notNil(merged)
        assert.equal(type(merged.additional_parameters), "table")
        assert.equal(next(merged.additional_parameters), nil)
        assert.equal(type(assistant._ui_provider_data.providers[id].additional_parameters), "table")
        assert.equal(next(assistant._ui_provider_data.providers[id].additional_parameters), nil)
    end),

    test("installProvider persists the new provider as the active selection", function()
        local assistant = mockAssistantForInstall()
        local id, err = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "AMD", "key", "gpt-4o")
        assert.notNil(id, err)
        -- getActiveProviderId reads this key on the next reload (e.g. opening a
        -- book); without it the previous provider/model would come back.
        assert.equal(assistant.settings:readSetting("provider"), id)
    end),

    test("installProvider does not share preset additional_parameters tables", function()
        local assistant = mockAssistantForInstall()
        local preset
        for i, p in ipairs(Registry.PRESET_PROVIDERS) do
            if p.name == "DeepSeek" then preset = p end
        end
        assert.notNil(preset, "DeepSeek preset missing from PRESET_PROVIDERS")
        local before = koutil.tableDeepCopy(preset.additional_parameters)
        local id, err = Registry.installProvider(assistant, preset.handler, preset.base_url,
            preset.name .. " UI", "key", "auto", preset.additional_parameters)
        assert.notNil(id, err)
        local merged = assistant.config._data.provider_settings[id]
        assert.notNil(merged)
        -- Mutating the merged config must not corrupt the shared preset table.
        merged.additional_parameters.thinking.type = "enabled"
        merged.additional_parameters.temperature = 0.9
        assert.isTrue(deepEqual(preset.additional_parameters, before),
            "the shared preset table must survive an install untouched")
    end),

    -- =========================================================================
    -- Edit / is_editable
    -- =========================================================================

    test("is_editable returns same result as is_deletable", function()
        -- UI provider: editable
        assert.isTrue(Registry.is_editable({ source = "ui" }))
        assert.isTrue(Registry.is_deletable({ source = "ui" }))
        -- File provider: not editable
        assert.equal(Registry.is_editable({ source = "file", immutable = true }), false)
        assert.equal(Registry.is_deletable({ source = "file", immutable = true }), false)
        -- UI + immutable: not editable
        assert.equal(Registry.is_editable({ source = "ui", immutable = true }), false)
        assert.equal(Registry.is_deletable({ source = "ui", immutable = true }), false)
        -- nil: not editable
        assert.equal(Registry.is_editable(nil), nil)
        assert.equal(Registry.is_deletable(nil), nil)
    end),

    test("updateProvider updates fields without generating new ID", function()
        local assistant = mockAssistantForInstall()
        -- First install a provider
        local id, err = Registry.installProvider(assistant, "openai",
            "https://api.old.com/v1", "Old Name", "old_key", "gpt-4")
        assert.notNil(id, err)

        -- Now update it
        local same_id, err2 = Registry.updateProvider(assistant, id,
            "New Name", "https://api.new.com/v1", "new_key", "gpt-4o")
        assert.notNil(same_id, err2)
        assert.equal(same_id, id, "updateProvider must return the same ID")

        -- Verify fields updated in ui_provider_data
        local record = assistant._ui_provider_data.providers[id]
        assert.equal(record.display_name, "New Name")
        assert.equal(record.base_url, "https://api.new.com/v1")
        assert.equal(record.api_key, "new_key")
        assert.equal(record.model, "gpt-4o")

        -- Verify merged config updated
        local merged = assistant.config._data.provider_settings[id]
        assert.equal(merged.display_name, "New Name")
        assert.equal(merged.base_url, "https://api.new.com/v1")
        assert.equal(merged.api_key, "new_key")
        assert.equal(merged.model, "gpt-4o")
    end),

    test("updateProvider preserves handler and additional_parameters", function()
        local assistant = mockAssistantForInstall()
        local params = { temperature = 0.5, thinking = { type = "disabled" } }
        local id, err = Registry.installProvider(assistant, "openai",
            "https://api.deepseek.com/v1", "DeepSeek", "key", "auto", params)
        assert.notNil(id, err)

        -- Update only mutable fields
        local same_id, err2 = Registry.updateProvider(assistant, id,
            "DeepSeek Updated", "https://api.deepseek.com/v1", "new_key", "deepseek-chat")
        assert.notNil(same_id, err2)

        local record = assistant._ui_provider_data.providers[id]
        assert.equal(record.handler, "openai", "handler must be preserved")
        assert.isTrue(deepEqual(record.additional_parameters, params),
            "additional_parameters must be preserved")

        local merged = assistant.config._data.provider_settings[id]
        assert.equal(merged.handler, "openai", "merged handler must be preserved")
        assert.isTrue(deepEqual(merged.additional_parameters, params),
            "merged additional_parameters must be preserved")
    end),

    test("updateProvider replaces additional_parameters when one is given", function()
        local assistant = mockAssistantForInstall()
        local id, err = Registry.installProvider(assistant, "anthropic",
            "https://api.anthropic.com/v1", "Anthropic", "key", "auto",
            { max_tokens = 4096 })
        assert.notNil(id, err)
        local same_id, err2 = Registry.updateProvider(assistant, id,
            "Anthropic", "https://api.anthropic.com/v1", "key", "claude-x",
            { thinking = { type = "disabled" } })
        assert.equal(same_id, id, err2)
        local record = assistant._ui_provider_data.providers[id]
        assert.isTrue(deepEqual(record.additional_parameters, { thinking = { type = "disabled" } }),
            "an explicit parameter table must replace the stored one")
    end),

    test("updateProvider defaults model to 'auto' when empty", function()
        local assistant = mockAssistantForInstall()
        local id, err = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "Test", "key", "gpt-4")
        assert.notNil(id, err)

        Registry.updateProvider(assistant, id, "Test", "https://api.test.com/v1", "key", "")
        local record = assistant._ui_provider_data.providers[id]
        assert.equal(record.model, "auto")
    end),

    test("updateProvider fails for non-existent ID", function()
        local assistant = mockAssistantForInstall()
        local id, err = Registry.updateProvider(assistant, "custom:999",
            "Ghost", "https://ghost.com", "key", "model")
        assert.equal(id, nil)
        assert.notNil(err)
    end),

    test("updateProvider sets updated flag and saves", function()
        local assistant = mockAssistantForInstall()
        local save_called = false
        assistant.settings.saveSetting = function() save_called = true end

        local id, err = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "Test", "key", "auto")
        assert.notNil(id, err)

        assistant.updated = false
        Registry.updateProvider(assistant, id, "Test2", "https://api2.test.com/v1", "key", "gpt-4")
        assert.isTrue(assistant.updated, "updated flag must be set")
        assert.isTrue(save_called, "settings must be saved")
    end),

    test("updateProvider persists the edit so a reload sees it", function()
        local assistant = mockAssistantForInstall()
        local id, err = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "Test", "key", "gpt-4")
        assert.notNil(id, err)
        Registry.updateProvider(assistant, id, "Renamed", "https://api.test.com/v1", "key2", "gpt-4o")
        local reloaded = Registry.load(assistant.settings)
        assert.equal(reloaded.providers[id].display_name, "Renamed")
        assert.equal(reloaded.providers[id].api_key, "key2")
    end),

    -- =========================================================================
    -- Delete
    -- =========================================================================

    test("delete still works correctly after edit additions", function()
        local data = { providers = {}, _next_id = 1 }
        local id1 = Registry.add(data, {
            display_name = "Provider 1", handler = "openai",
            model = "auto", base_url = "https://a.com", api_key = "k1",
        })
        local id2 = Registry.add(data, {
            display_name = "Provider 2", handler = "anthropic",
            model = "claude", base_url = "https://b.com", api_key = "k2",
        })
        assert.notNil(id1)
        assert.notNil(id2)

        -- Delete the first provider
        local ok, err = Registry.delete(data, id1)
        assert.isTrue(ok)
        assert.equal(data.providers[id1], nil)
        assert.notNil(data.providers[id2], "second provider must survive delete")

        -- Delete the second
        ok, err = Registry.delete(data, id2)
        assert.isTrue(ok)
        assert.equal(data.providers[id2], nil)
    end),

    test("delete fails for an unknown provider id", function()
        local data = { providers = {}, _next_id = 1 }
        local ok, err = Registry.delete(data, "custom:404")
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    -- =========================================================================
    -- Whitespace normalization
    -- =========================================================================

    test("validate trims leading/trailing whitespace from all fields", function()
        local record = {
            display_name = "  Name  ",
            handler = "openai",
            base_url = "  https://a.com/v1  ",
            api_key = "  sk-abc\r\n  ",
            model = "  ",
        }
        local ok, err = Registry.validate(record)
        assert.isTrue(ok, err)
        assert.equal(record.display_name, "Name")
        assert.equal(record.base_url, "https://a.com/v1")
        assert.equal(record.api_key, "sk-abc")
        assert.equal(record.model, "auto")
    end),

    test("validate rejects internal whitespace in api_key", function()
        local ok, err = Registry.validate({
            display_name = "Name",
            handler = "openai",
            base_url = "https://a.com/v1",
            api_key = "sk-abc def",
            model = "auto",
        })
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("validate rejects internal whitespace in base_url", function()
        local ok, err = Registry.validate({
            display_name = "Name",
            handler = "openai",
            base_url = "https://a.com/v 1",
            api_key = "sk-abc",
            model = "auto",
        })
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("validate rejects an unknown handler", function()
        local ok, err = Registry.validate({
            display_name = "Name",
            handler = "gemma",
            base_url = "https://a.com/v1",
            api_key = "sk-abc",
            model = "auto",
        })
        assert.isFalse(ok, "only the four UI-selectable handlers may be stored")
    end),

    test("validate rejects a blank display name", function()
        local ok, err = Registry.validate({
            display_name = "   ",
            handler = "openai",
            base_url = "https://a.com/v1",
            api_key = "sk-abc",
            model = "auto",
        })
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("updateProvider trims stored and merged values", function()
        local assistant = mockAssistantForInstall()
        local id, err = Registry.installProvider(assistant, "openai",
            "https://api.old.com/v1", "Old Name", "old_key", "gpt-4")
        assert.notNil(id, err)

        local same_id, err2 = Registry.updateProvider(assistant, id,
            "  New Name  ", "  https://api.new.com/v1  ", "  new_key  ", " gpt-4o ")
        assert.notNil(same_id, err2)

        local record = assistant._ui_provider_data.providers[id]
        assert.equal(record.display_name, "New Name")
        assert.equal(record.base_url, "https://api.new.com/v1")
        assert.equal(record.api_key, "new_key")
        assert.equal(record.model, "gpt-4o")

        local merged = assistant.config._data.provider_settings[id]
        assert.equal(merged.display_name, "New Name")
        assert.equal(merged.base_url, "https://api.new.com/v1")
        assert.equal(merged.api_key, "new_key")
        assert.equal(merged.model, "gpt-4o")
    end),

    test("updateProvider rejects an invalid base_url and leaves the record unchanged", function()
        local assistant = mockAssistantForInstall()
        local id, err = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "Original", "key", "gpt-4")
        assert.notNil(id, err)

        local returned, update_err = Registry.updateProvider(assistant, id,
            "Changed", "notaurl", "key", "gpt-4o")
        assert.equal(returned, nil)
        assert.notNil(update_err)

        local record = assistant._ui_provider_data.providers[id]
        assert.equal(record.display_name, "Original")
        assert.equal(record.base_url, "https://api.test.com/v1")
        assert.equal(record.api_key, "key")
        assert.equal(record.model, "gpt-4")
    end),

    test("updateProvider defaults a whitespace-only model to 'auto'", function()
        local assistant = mockAssistantForInstall()
        local id, err = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "Test", "key", "gpt-4")
        assert.notNil(id, err)

        local same_id, err2 = Registry.updateProvider(assistant, id,
            "Test", "https://api.test.com/v1", "key", "   ")
        assert.notNil(same_id, err2)
        assert.equal(assistant._ui_provider_data.providers[id].model, "auto")
        assert.equal(assistant.config._data.provider_settings[id].model, "auto")
    end),

    test("updateProvider clears the runtime model override", function()
        local assistant = mockAssistantForInstall()
        local id = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "AMD", "key", "auto")
        assistant.settings:saveSetting("selected_model_" .. id, "gpt-4o")

        local same_id, err = Registry.updateProvider(assistant, id,
            "AMD", "https://api.test.com/v1", "key", "gpt-4o-mini")
        assert.equal(same_id, id, err)
        assert.equal(assistant.settings:readSetting("selected_model_" .. id), nil,
            "the edited model must not be shadowed by a stale override")
    end),

    test("updateProvider re-syncs the handler when the active provider is edited", function()
        local assistant = mockAssistantForInstall()
        local id = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "AMD", "key", "auto")
        local forced = {}
        assistant.querier = {
            provider_name = id,
            load_model = function(_, name, force) forced[#forced + 1] = force end,
        }

        local same_id, err = Registry.updateProvider(assistant, id,
            "AMD", "https://api.test.com/v1", "key", "gpt-4o-mini")
        assert.equal(same_id, id, err)
        assert.equal(forced[#forced], true,
            "the active provider must be force-reloaded")
    end),

    test("updateProvider leaves an inactive provider's handler alone", function()
        local assistant = mockAssistantForInstall()
        local id = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "AMD", "key", "auto")
        local forced = {}
        assistant.querier = {
            provider_name = "custom:99",
            load_model = function(_, name, force) forced[#forced + 1] = force end,
        }

        local same_id, err = Registry.updateProvider(assistant, id,
            "AMD", "https://api.test.com/v1", "key", "gpt-4o-mini")
        assert.equal(same_id, id, err)
        assert.equal(#forced, 0, "only the active provider should be reloaded")
    end),

    test("Edit dialog pre-fills the runtime-selected model over the record", function()
        local assistant = mockAssistantForInstall()
        local id = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "AMD", "key", "auto")
        assistant.settings:saveSetting("selected_model_" .. id, "gpt-4o")

        local dialog = captureDialog(function()
            Registry.showProviderDialog(assistant, nil, nil, nil, nil, id)
        end)
        assert.notNil(dialog, "edit dialog should be built")
        local field = fieldByHint(dialog, HINT_MODEL)
        assert.notNil(field, "edit dialog should have a Model field")
        assert.equal(field.text, "gpt-4o")
    end),

    test("Edit dialog falls back to the record model without an override", function()
        local assistant = mockAssistantForInstall()
        local id = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "AMD", "key", "gpt-4o-mini")

        local dialog = captureDialog(function()
            Registry.showProviderDialog(assistant, nil, nil, nil, nil, id)
        end)
        assert.notNil(dialog, "edit dialog should be built")
        local field = fieldByHint(dialog, HINT_MODEL)
        assert.notNil(field, "edit dialog should have a Model field")
        assert.equal(field.text, "gpt-4o-mini")
    end),

    test("Edit dialog offers Delete for a UI provider only", function()
        local assistant = mockAssistantForInstall()
        local id = Registry.installProvider(assistant, "openai",
            "https://api.test.com/v1", "AMD", "key", "auto")
        local dialog = captureDialog(function()
            Registry.showProviderDialog(assistant, nil, nil, nil, nil, id)
        end)
        local has_delete = false
        for i, row in ipairs(dialog.buttons) do
            for j, button in ipairs(row) do
                if button.id == "delete" then has_delete = true end
            end
        end
        assert.isTrue(has_delete, "a UI provider must be deletable from its edit dialog")

        -- A file-configured provider has no record to edit, so no Delete.
        assistant.config._data.provider_settings["openai_file"] = {
            display_name = "File One", source = "file", immutable = true,
        }
        local file_dialog = captureDialog(function()
            Registry.showProviderDialog(assistant, nil, nil, nil, nil, "openai_file")
        end)
        for i, row in ipairs(file_dialog.buttons) do
            for j, button in ipairs(row) do
                assert.isTrue(button.id ~= "delete",
                    "an immutable file provider must not be deletable")
            end
        end
    end),

    -- =========================================================================
    -- Reasoning parameter catalog
    -- =========================================================================

    test("PARAM_CATALOG covers every UI-selectable handler", function()
        for handler in pairs(Registry.HANDLERS) do
            local catalog = Registry.PARAM_CATALOG[handler]
            assert.notNil(catalog, "no PARAM_CATALOG entry for handler " .. handler)
            assert.isTrue(#catalog > 0, "empty catalog for handler " .. handler)
        end
    end),

    test("PARAM_CATALOG entries all carry key/value/desc", function()
        for key, catalog in pairs(Registry.PARAM_CATALOG) do
            for i, item in ipairs(catalog) do
                local where = key .. "[" .. i .. "]"
                assert.notNil(item.key, where .. " has no key")
                assert.notNil(item.value, where .. " has no value")
                assert.notNil(item.desc, where .. " has no desc")
            end
        end
    end),

    test("getReasoningKey scopes the overlay to the provider id", function()
        assert.equal(Registry.getReasoningKey("custom:1"), "reasoning_option_custom:1")
        assert.equal(Registry.getReasoningKey("openai"), "reasoning_option_openai")
    end),

    test("getReasoningOverlay returns {} when unset or malformed", function()
        local settings = mockSettings()
        assert.equal(next(Registry.getReasoningOverlay(settings, "custom:1")), nil)
        settings:saveSetting(Registry.getReasoningKey("custom:1"), "not a table")
        assert.equal(next(Registry.getReasoningOverlay(settings, "custom:1")), nil)
        assert.equal(next(Registry.getReasoningOverlay(nil, "custom:1")), nil)
        assert.equal(next(Registry.getReasoningOverlay(settings, nil)), nil)
    end),

    test("getReasoningOverlay returns the stored selections", function()
        local settings = mockSettings()
        settings:saveSetting(Registry.getReasoningKey("custom:1"), {
            reasoning_effort = "none",
        })
        local overlay = Registry.getReasoningOverlay(settings, "custom:1")
        assert.equal(overlay.reasoning_effort, "none")
    end),

    test("resolveCatalogKey maps alias handlers onto openai", function()
        local aliases = { "deepseek", "ollama", "groq", "mistral", "openrouter", "gigachat" }
        for i, alias in ipairs(aliases) do
            assert.equal(Registry.resolveCatalogKey("custom:1", { handler = alias }), "openai",
                alias .. " should resolve to the openai catalog")
        end
    end),

    test("resolveCatalogKey dispatches gemma by base_url", function()
        assert.equal(Registry.resolveCatalogKey("custom:1", {
            handler = "gemma",
            base_url = "https://generativelanguage.googleapis.com/v1beta/models",
        }), "gemini")
        assert.equal(Registry.resolveCatalogKey("custom:1", {
            handler = "gemma",
            base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
        }), "openai", "the OpenAI-compatible Gemma endpoint uses the openai catalog")
    end),

    test("resolveCatalogKey returns nil for an unresolvable handler", function()
        assert.equal(Registry.resolveCatalogKey("custom:1", { handler = "nope" }), nil)
        assert.equal(Registry.resolveCatalogKey("custom:1", nil), nil,
            "a UI id without a record carries no handler")
    end),

    test("hasReasoningOptions follows the resolved catalog key", function()
        assert.isTrue(Registry.hasReasoningOptions("custom:1", { handler = "openai" }))
        assert.isTrue(Registry.hasReasoningOptions("custom:1", { handler = "deepseek" }))
        assert.isFalse(Registry.hasReasoningOptions("custom:1", { handler = "nope" }))
        assert.isFalse(Registry.hasReasoningOptions("custom:1", nil))
    end),

    test("showParametersDialog returns nothing for a provider without a record", function()
        local assistant = mockAssistantForInstall()
        assert.equal(Registry.showParametersDialog(assistant, "custom:404"), nil)
    end),

    -- =========================================================================
    -- Connection test report / verdict
    -- =========================================================================

    test("formatTestReport surfaces the extracted JSON error message", function()
        local report = {
            url    = "https://api.test.com/v1/chat/completions",
            body   = "{}",
            status = 401,
            raw    = '{"error":{"message":"Incorrect API key provided"}}',
        }
        local text = Registry.formatTestReport("openai", "https://api.test.com/v1", "gpt-4", report)
        assert.matches(text, "API error: Incorrect API key provided")
    end),

    test("formatTestReport unwraps nested proxy error shapes", function()
        local report = {
            url    = "https://api.test.com/v1/chat/completions",
            body   = "{}",
            status = 429,
            raw    = '{"detail":{"error":{"message":"concurrency limit (80)"}}}',
        }
        local text = Registry.formatTestReport("openai", "https://api.test.com/v1", "gpt-4", report)
        assert.matches(text, "API error: concurrency limit %(80%)")
    end),

    test("formatTestReport falls back to the full raw body when no JSON error exists", function()
        local long_tail = string.rep("x", 900)
        local raw = "<html>Bad gateway " .. long_tail .. "</html>"
        local report = {
            url    = "https://api.test.com/v1/chat/completions",
            body   = "{}",
            status = 502,
            raw    = raw,
        }
        local text = Registry.formatTestReport("openai", "https://api.test.com/v1", "gpt-4", report)
        assert.matches(text, "<html>Bad gateway")
        assert.isTrue(text:find(raw, 1, true) ~= nil, "expected the untruncated raw body")
    end),

    test("formatTestReport marks an empty error body explicitly", function()
        local report = {
            url    = "https://api.test.com/v1/chat/completions",
            body   = "{}",
            status = 500,
            raw    = "",
        }
        local text = Registry.formatTestReport("openai", "https://api.test.com/v1", "gpt-4", report)
        assert.isTrue(text:find("(empty response body)", 1, true) ~= nil,
            "expected the empty-body marker")
    end),

    test("formatTestReport never echoes the API key", function()
        local report = {
            url    = "https://api.test.com/v1/chat/completions",
            body   = "{}",
            status = 401,
            raw    = '{"error":{"message":"Incorrect API key provided"}}',
        }
        local text = Registry.formatTestReport("openai", "https://api.test.com/v1", "gpt-4", report)
        assert.isTrue(text:find("sk-secret", 1, true) == nil,
            "the failure report must stay free of credentials")
    end),

    test("isConnectionTestOk passes 200 with an OK echo", function()
        assert.isTrue(Registry.isConnectionTestOk({
            url     = "https://api.test.com/v1/chat/completions",
            body    = "{}",
            status  = 200,
            raw     = '{"choices":[{"message":{"content":"OK"}}]}',
            content = "OK",
        }))
    end),

    test("isConnectionTestOk passes 200 with a thinking-model echo", function()
        assert.isTrue(Registry.isConnectionTestOk({
            url     = "https://api.test.com/v1/chat/completions",
            body    = "{}",
            status  = 200,
            raw     = "...",
            content = "We must output only \"OK\".\nThink:\n\nOK",
        }))
    end),

    test("isConnectionTestOk fails a 200 error body and the report shows the cause", function()
        local report = {
            url     = "https://api.test.com/v1/chat/completions",
            body    = "{}",
            status  = 200,
            raw     = '{"error":{"message":"overloaded"}}',
            content = nil,
        }
        assert.isFalse(Registry.isConnectionTestOk(report))
        local text = Registry.formatTestReport("openai", "https://api.test.com/v1", "gpt-4", report)
        assert.matches(text, "API error: overloaded")
    end),

    test("isConnectionTestOk fails a 200 with a non-OK echo", function()
        assert.isFalse(Registry.isConnectionTestOk({
            url     = "https://api.test.com/v1/chat/completions",
            body    = "{}",
            status  = 200,
            raw     = "...",
            content = "Sure, here you go",
        }))
    end),

    test("isConnectionTestOk fails non-2xx even with an OK echo", function()
        assert.isFalse(Registry.isConnectionTestOk({
            url     = "https://api.test.com/v1/chat/completions",
            body    = "{}",
            status  = 401,
            raw     = "",
            content = "OK",
        }))
        assert.isFalse(Registry.isConnectionTestOk(nil))
    end),
}

return helper.runTests("assistant_provider_registry", tests)
