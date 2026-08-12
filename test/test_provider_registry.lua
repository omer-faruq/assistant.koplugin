-- test_provider_registry.lua
-- Tests for assistant_provider_registry.lua, focusing on the exported
-- "Provider API" menu factory (Registry.getAddProviderMenuItem), the
-- preset/custom provider tables that moved here from main.lua, and the
-- persistence of preset additional_parameters (Registry.add / installProvider).
local helper = require("test.test_helper")
local assert = helper.assert
local Registry = require("assistant_provider_registry")

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
-- Registry.installProvider touches.
local function mockAssistantForInstall()
    return {
        _ui_provider_data = { providers = {}, _next_id = 1 },
        settings = { saveSetting = function() end },
        CONFIGURATION = { provider_settings = {} },
        updated = false,
        querier = nil,
    }
end

-- Resolves the menu item's sub-menu by invoking sub_item_table_func().
local function subItems(menu_item)
    assert.notNil(menu_item.sub_item_table_func, "menu item should have sub_item_table_func")
    return menu_item.sub_item_table_func()
end

-- Expected default additional_parameters per preset name.
local EXPECTED_PRESET_PARAMS = {
    DeepSeek = {
        temperature = 0.7,
        max_tokens = 4096,
        thinking = { type = "disabled" },
    },
    OpenRouter = {
        temperature = 0.7,
        max_tokens = 4096,
        reasoning = { effort = "none" },
    },
    Groq = {
        temperature = 0.7,
        reasoning_effort = "none",
    },
    Mistral = {
        temperature = 0.7,
        max_tokens = 4096,
    },
    Gemini = {
        temperature = 0.7,
        thinking_budget = 0,
    },
    Anthropic = {
        anthropic_version = "2023-06-01",
        max_tokens = 4096,
    },
}

local tests = {

    -- =========================================================================
    -- Exported tables
    -- =========================================================================

    test("PRESET_PROVIDERS exported with name/handler/base_url", function()
        local presets = Registry.PRESET_PROVIDERS
        assert.notNil(presets)
        assert.equal(#presets, 6)
        for i, preset in ipairs(presets) do
            assert.notNil(preset.name)
            assert.notNil(preset.handler)
            assert.matches(preset.base_url, "^https?://")
        end
    end),

    test("CUSTOM_HANDLERS exported with name/handler/base_url", function()
        local customs = Registry.CUSTOM_HANDLERS
        assert.notNil(customs)
        assert.equal(#customs, 4)
        for i, custom in ipairs(customs) do
            assert.notNil(custom.name)
            assert.notNil(custom.handler)
            assert.matches(custom.base_url, "^https?://")
        end
    end),

    test("preset and custom handlers are all known to the registry", function()
        for i, preset in ipairs(Registry.PRESET_PROVIDERS) do
            assert.isTrue(Registry.HANDLERS[preset.handler],
                "unknown handler: " .. tostring(preset.handler))
        end
        for i, custom in ipairs(Registry.CUSTOM_HANDLERS) do
            assert.isTrue(Registry.HANDLERS[custom.handler],
                "unknown handler: " .. tostring(custom.handler))
        end
    end),

    test("presets carry provider-specific additional_parameters defaults", function()
        local presets = Registry.PRESET_PROVIDERS
        assert.equal(#presets, 6)
        for i, preset in ipairs(presets) do
            local want = EXPECTED_PRESET_PARAMS[preset.name]
            assert.notNil(want, "no expected defaults defined for preset " .. tostring(preset.name))
            assert.notNil(preset.additional_parameters,
                preset.name .. " preset should define additional_parameters")
            assert.isTrue(deepEqual(preset.additional_parameters, want),
                preset.name .. " additional_parameters mismatch")
        end
    end),

    test("custom wire formats carry no additional_parameters", function()
        for i, custom in ipairs(Registry.CUSTOM_HANDLERS) do
            assert.equal(custom.additional_parameters, nil,
                "custom handler " .. tostring(custom.name) .. " must not add defaults")
        end
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

    test("sub-menu lists all presets followed by a Custom sub-menu", function()
        local items = subItems(Registry.getAddProviderMenuItem(mockAssistant()))
        assert.equal(#items, #Registry.PRESET_PROVIDERS + 1)
        for i, preset in ipairs(Registry.PRESET_PROVIDERS) do
            local item = items[i]
            assert.equal(item.text, preset.name)
            assert.equal(item.keep_menu_open, true)
            assert.notNil(item.callback)
        end
        local custom_item = items[#items]
        assert.equal(custom_item.text, "Custom")
        assert.notNil(custom_item.sub_item_table)
    end),

    test("preset callback invokes _showAddProviderDialog with preset fields and additional_parameters", function()
        local assistant = mockAssistant()
        local items = subItems(Registry.getAddProviderMenuItem(assistant))
        for i, preset in ipairs(Registry.PRESET_PROVIDERS) do
            items[i].callback()
            local call = assistant.calls[#assistant.calls]
            assert.equal(call.preset_name, preset.name)
            assert.equal(call.handler, preset.handler)
            assert.equal(call.base_url, preset.base_url)
            assert.equal(call.additional_parameters, preset.additional_parameters,
                "preset additional_parameters should be forwarded to the dialog")
        end
    end),

    test("Custom sub-menu lists compatible wire formats", function()
        local items = subItems(Registry.getAddProviderMenuItem(mockAssistant()))
        local custom_items = items[#items].sub_item_table
        assert.equal(#custom_items, #Registry.CUSTOM_HANDLERS)
        for i, custom in ipairs(Registry.CUSTOM_HANDLERS) do
            local item = custom_items[i]
            assert.equal(item.text, custom.name .. " (Compatible)")
            assert.equal(item.keep_menu_open, true)
            assert.notNil(item.callback)
        end
    end),

    test("Custom callback invokes _showAddProviderDialog with nil name and no additional_parameters", function()
        local assistant = mockAssistant()
        local items = subItems(Registry.getAddProviderMenuItem(assistant))
        local custom_items = items[#items].sub_item_table
        for i, custom in ipairs(Registry.CUSTOM_HANDLERS) do
            custom_items[i].callback()
            local call = assistant.calls[#assistant.calls]
            assert.equal(call.preset_name, nil)
            assert.equal(call.handler, custom.handler)
            assert.equal(call.base_url, custom.base_url)
            assert.equal(call.additional_parameters, nil,
                "custom callback should not pass additional_parameters")
        end
    end),

    -- =========================================================================
    -- Registry.add persistence
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
        local merged = assistant.CONFIGURATION.provider_settings[id]
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
        local merged = assistant.CONFIGURATION.provider_settings[id]
        assert.notNil(merged)
        assert.equal(type(merged.additional_parameters), "table")
        assert.equal(next(merged.additional_parameters), nil)
        assert.equal(type(assistant._ui_provider_data.providers[id].additional_parameters), "table")
        assert.equal(next(assistant._ui_provider_data.providers[id].additional_parameters), nil)
    end),

    test("installProvider does not share preset additional_parameters tables", function()
        local assistant = mockAssistantForInstall()
        local preset = Registry.PRESET_PROVIDERS[1] -- DeepSeek
        local id, err = Registry.installProvider(assistant, preset.handler, preset.base_url,
            preset.name .. " UI", "key", "auto", preset.additional_parameters)
        assert.notNil(id, err)
        local merged = assistant.CONFIGURATION.provider_settings[id]
        assert.notNil(merged)
        -- Mutating the merged config must not corrupt the shared preset table.
        merged.additional_parameters.thinking.type = "enabled"
        merged.additional_parameters.temperature = 0.9
        assert.equal(preset.additional_parameters.thinking.type, "disabled")
        assert.equal(preset.additional_parameters.temperature, 0.7)
        assert.isTrue(deepEqual(preset.additional_parameters, EXPECTED_PRESET_PARAMS.DeepSeek))
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

    test("Registry.edit returns false for non-existent provider", function()
        local data = { providers = {}, _next_id = 1 }
        local ok, err = Registry.edit(data, "custom:999", {})
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("Registry.edit returns true for existing provider", function()
        local data = { providers = {}, _next_id = 1 }
        local id = Registry.add(data, {
            display_name = "Test",
            handler = "openai",
            model = "auto",
            base_url = "https://api.test.com/v1",
            api_key = "key",
        })
        assert.notNil(id)
        local ok, err = Registry.edit(data, id, {})
        assert.isTrue(ok)
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
        local merged = assistant.CONFIGURATION.provider_settings[id]
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

        local merged = assistant.CONFIGURATION.provider_settings[id]
        assert.equal(merged.handler, "openai", "merged handler must be preserved")
        assert.isTrue(deepEqual(merged.additional_parameters, params),
            "merged additional_parameters must be preserved")
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
        Registry.updateProvider(assistant, id, "Test2", "https://api2.test.com/v1", "key2", "gpt-4")
        assert.isTrue(assistant.updated, "updated flag must be set")
        assert.isTrue(save_called, "settings must be saved")
    end),

    -- =========================================================================
    -- Delete regression
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

    test("is_deletable unchanged by edit additions", function()
        -- Same semantics: UI = deletable (truthy), file = not (false)
        assert.isTrue(Registry.is_deletable({ source = "ui" }))
        assert.equal(Registry.is_deletable({ source = "ui", immutable = true }), false)
        assert.equal(Registry.is_deletable({ source = "file" }), false)
        assert.equal(Registry.is_deletable(nil), nil)
    end),
}

return helper.runTests("assistant_provider_registry", tests)
