-- test_menu_paths.lua
-- Guards the marker-based menu-path computation used by main.lua's
-- showAddProviderMenu to jump to the "Provider API" menu item (see
-- AGENTS.md "Provider menu paths").
--
-- main.lua cannot be loaded headless (it pulls in the full KOReader UI
-- widget stack), so per project testing policy the relevant helpers are
-- inlined here as snippets and tested directly. If the marker names or the
-- path computation in main.lua change, these tests must be updated together.
local helper = require("test.test_helper")
local assert = helper.assert

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Inlined copies of the helpers from main.lua (marker-based path lookup).

-- 1-based index of the item carrying the marker in item_table, or nil.
local function findItemIndexByMarker(item_table, marker)
    if not item_table then return nil end
    for i, item in ipairs(item_table) do
        if type(item) == "table" and item.assistant_item_id == marker then
            return i
        end
    end
    return nil
end

-- Computes the TouchMenu path (e.g. "4.1.7.1") to the "Provider API" item by
-- walking tab_item_table: tab -> AI Assistant -> Settings -> Provider API.
local function computeAddProviderMenuPath(tab_item_table)
    if not tab_item_table then return nil end
    for tab_nb, tab_items in ipairs(tab_item_table) do
        local ai_idx = findItemIndexByMarker(tab_items, "assistant_ai_menu")
        if ai_idx then
            local ai_item = tab_items[ai_idx]
            local ai_sub = ai_item.sub_item_table_func and ai_item.sub_item_table_func()
                or ai_item.sub_item_table
            local settings_idx = findItemIndexByMarker(ai_sub, "assistant_settings")
            if settings_idx then
                local settings_item = ai_sub[settings_idx]
                local settings_sub = settings_item.sub_item_table_func
                    and settings_item.sub_item_table_func() or settings_item.sub_item_table
                local provider_idx = findItemIndexByMarker(settings_sub, "assistant_add_provider")
                if provider_idx then
                    return string.format("%d.%d.%d.%d", tab_nb, ai_idx, settings_idx, provider_idx)
                end
            end
        end
    end
    return nil
end

-- Mock menu pieces, mirroring the real item tables. In the live TouchMenu a
-- tab descriptor doubles as its item array (numeric indices hold the items),
-- and separator entries/items without markers must be skipped.
local separator_entry = { id = "----------------------------", text = "KOMenu:separator" }

local function providerItem()
    return { text = "Provider API", assistant_item_id = "assistant_add_provider" }
end

local function settingsItem(provider_item)
    return {
        text = "Settings",
        assistant_item_id = "assistant_settings",
        sub_item_table = { provider_item },
    }
end

local function aiItem(settings_item)
    return {
        text = "AI Assistant",
        assistant_item_id = "assistant_ai_menu",
        sub_item_table = {
            { text = "Ask the AI a question" },
            { text = "Book Insights", sub_item_table = {} },
            settings_item,
        },
    }
end

-- Reader-like layout: AI Assistant first in the tools tab (4th tab).
local function readerTabs(ai_item)
    return {
        { text = "navigation" },
        { text = "typeset" },
        { text = "settings" },
        { ai_item },
    }
end

local tests = {
    test("finds reader path tab -> AI Assistant -> Settings -> Provider API", function()
        local provider_item = providerItem()
        local tabs = readerTabs(aiItem(settingsItem(provider_item)))
        assert.equal(computeAddProviderMenuPath(tabs), "4.1.3.1")
    end),

    test("path tracks layout changes, no fixed indices", function()
        -- Custom Prompts hidden (no book_level_prompts) shifts Settings left.
        local provider_item = providerItem()
        local ai_item = aiItem(settingsItem(provider_item))
        table.remove(ai_item.sub_item_table, 2) -- drop Book Insights
        local tabs = readerTabs(ai_item)
        assert.equal(computeAddProviderMenuPath(tabs), "4.1.2.1")

        -- An extra item before Settings shifts it right again.
        table.insert(ai_item.sub_item_table, 2, { text = "Web Search" })
        assert.equal(computeAddProviderMenuPath(tabs), "4.1.3.1")
    end),

    test("resolves sub_item_table_func for dynamic submenus", function()
        local provider_item = providerItem()
        local settings_item = {
            text = "Settings",
            assistant_item_id = "assistant_settings",
            sub_item_table_func = function()
                return { { text = "WebSearch API" }, provider_item }
            end,
        }
        local tabs = readerTabs(aiItem(settings_item))
        assert.equal(computeAddProviderMenuPath(tabs), "4.1.3.2")
    end),

    test("finds AI Assistant in any tab and skips non-marker entries", function()
        local provider_item = providerItem()
        local tabs = {
            { text = "navigation" },
            { separator_entry, aiItem(settingsItem(provider_item)), separator_entry },
        }
        assert.equal(computeAddProviderMenuPath(tabs), "2.2.3.1")
    end),

    test("filemanager-like layout without book items", function()
        local provider_item = providerItem()
        local ai_item = aiItem(settingsItem(provider_item))
        -- FileManager AI Assistant submenu has no book-level items.
        ai_item.sub_item_table = { { text = "Ask the AI a question" }, ai_item.sub_item_table[3] }
        local tabs = { { text = "filemanager" }, { text = "settings" }, { ai_item } }
        assert.equal(computeAddProviderMenuPath(tabs), "3.1.2.1")
    end),

    test("returns nil when Provider API marker is missing", function()
        local settings_item = settingsItem({ text = "Provider API" }) -- no marker
        assert.equal(computeAddProviderMenuPath(readerTabs(aiItem(settings_item))), nil)
    end),

    test("returns nil when Settings marker is missing", function()
        local provider_item = providerItem()
        local settings_item = settingsItem(provider_item)
        settings_item.assistant_item_id = nil
        assert.equal(computeAddProviderMenuPath(readerTabs(aiItem(settings_item))), nil)
    end),

    test("returns nil when AI Assistant item is absent", function()
        assert.equal(computeAddProviderMenuPath(readerTabs(nil)), nil)
        assert.equal(computeAddProviderMenuPath({
            { text = "navigation" },
            { text = "tools" },
        }), nil)
        assert.equal(computeAddProviderMenuPath(nil), nil)
    end),
}

return helper.runTests("assistant_menu_paths", tests)
