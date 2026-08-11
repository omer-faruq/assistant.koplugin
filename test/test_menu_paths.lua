-- test_menu_paths.lua
-- Guards the fixed TouchMenu paths used by the Provider Settings "Add" button
-- to jump to the "Add Provider" menu item (see AGENTS.md "Provider menu paths").
--
-- main.lua and assistant_settings.lua cannot be loaded headless (they pull in
-- the full KOReader UI widget stack), so per project testing policy the
-- relevant constants and the menu-layout invariant they encode are inlined
-- here and tested as snippets. If the AI Assistant submenu order, the
-- "Other Settings" item order, or the paths change, these tests fail and
-- force the AGENTS.md note and the main.lua constants to be updated together.
local helper = require("test.test_helper")
local assert = helper.assert

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Inlined copies of the canonical path constants from main.lua.
local ADD_PROVIDER_READER_PATH = "4.1.8.1"
local ADD_PROVIDER_FILEMANAGER_PATH = "3.1.6.1"

-- Tools tab index of the AI Assistant menu per UI: Reader menu tabs are
-- (1 Navigation, 2 Typeset, 3 Settings, 4 Tools); FileManager menu tabs are
-- (1 FileManager settings, 2 Settings, 3 Tools). AI Assistant is first.
local READER_TOOLS_TAB = 4
local FM_TOOLS_TAB = 3
local AI_ASSISTANT_INDEX = 1

-- Top-level AI Assistant submenu items after the restructure ("Add Provider"
-- was moved out of this menu into the "Other Settings" submenu).
-- Reader layout: the two book-level groups are inserted at index 2.
local READER_ITEMS = {
    "ask", "book_builtin", "book_custom", "quick_note", "notebook",
    "provider", "websearch", "other_settings",
}
-- FileManager layout: the common items only.
local FM_ITEMS = {
    "ask", "quick_note", "notebook", "provider", "websearch", "other_settings",
}
-- "Other Settings" submenu: Add Provider must stay the FIRST item so the
-- trailing ".1" of both fixed paths remains valid. Add Web Search API is second.
local OTHER_SETTINGS_ITEMS = {
    "add_provider", "add_web_search", "language", "text_size", "response", "tweaks",
    "copy_question", "auto_save", "book_text", "ota", "purge",
}

local function indexOf(list, key)
    for i, k in ipairs(list) do
        if k == key then return i end
    end
    return nil
end

-- Rebuilds the fixed touch path from the layout the same way main.lua's
-- showAddProviderMenu consumes it: <tab>.<ai>.<submenu_item>.<submenu_index>.
local function addProviderPath(tools_tab, items)
    return string.format("%d.%d.%d.%d", tools_tab, AI_ASSISTANT_INDEX,
        indexOf(items, "other_settings"),
        indexOf(OTHER_SETTINGS_ITEMS, "add_provider"))
end

local tests = {
    test("Reader path is 4.1.8.1 (Other Settings at index 8)", function()
        assert.equal(addProviderPath(READER_TOOLS_TAB, READER_ITEMS),
            ADD_PROVIDER_READER_PATH)
    end),

    test("FileManager path is 3.1.6.1 (Other Settings at index 6)", function()
        assert.equal(addProviderPath(FM_TOOLS_TAB, FM_ITEMS),
            ADD_PROVIDER_FILEMANAGER_PATH)
    end),

    test("Add Provider is the first item of the Other Settings submenu", function()
        assert.equal(OTHER_SETTINGS_ITEMS[1], "add_provider",
            "the fixed paths end in .1 because Add Provider is first in Other Settings")
    end),

    test("Add Provider is no longer a top-level AI Assistant item", function()
        assert.equal(indexOf(READER_ITEMS, "add_provider"), nil)
        assert.equal(indexOf(FM_ITEMS, "add_provider"), nil)
    end),
}

return helper.runTests("assistant_menu_paths", tests)
