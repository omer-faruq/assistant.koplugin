-- test_provider_registry.lua
-- Tests for assistant_provider_registry.lua, focusing on the exported
-- "Add Provider" menu factory (Registry.getAddProviderMenuItem) and the
-- preset/custom provider tables that moved here from main.lua.
local helper = require("test.test_helper")
local assert = helper.assert
local Registry = require("assistant_provider_registry")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- A mock Assistant that records _showAddProviderDialog invocations.
local function mockAssistant()
    return {
        calls = {},
        _showAddProviderDialog = function(self, preset_name, handler, base_url)
            table.insert(self.calls, { preset_name = preset_name, handler = handler, base_url = base_url })
        end,
    }
end

-- Resolves the menu item's sub-menu by invoking sub_item_table_func().
local function subItems(menu_item)
    assert.notNil(menu_item.sub_item_table_func, "menu item should have sub_item_table_func")
    return menu_item.sub_item_table_func()
end

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

    -- =========================================================================
    -- getAddProviderMenuItem
    -- =========================================================================

    test("menu item is localized 'Add Provider' and keeps menu open", function()
        local item = Registry.getAddProviderMenuItem(mockAssistant())
        assert.equal(item.text, "Add Provider")
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

    test("preset callback invokes _showAddProviderDialog with preset fields", function()
        local assistant = mockAssistant()
        local items = subItems(Registry.getAddProviderMenuItem(assistant))
        for i, preset in ipairs(Registry.PRESET_PROVIDERS) do
            items[i].callback()
            local call = assistant.calls[#assistant.calls]
            assert.equal(call.preset_name, preset.name)
            assert.equal(call.handler, preset.handler)
            assert.equal(call.base_url, preset.base_url)
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

    test("Custom callback invokes _showAddProviderDialog with nil name", function()
        local assistant = mockAssistant()
        local items = subItems(Registry.getAddProviderMenuItem(assistant))
        local custom_items = items[#items].sub_item_table
        for i, custom in ipairs(Registry.CUSTOM_HANDLERS) do
            custom_items[i].callback()
            local call = assistant.calls[#assistant.calls]
            assert.equal(call.preset_name, nil)
            assert.equal(call.handler, custom.handler)
            assert.equal(call.base_url, custom.base_url)
        end
    end),
}

return helper.runTests("assistant_provider_registry", tests)
