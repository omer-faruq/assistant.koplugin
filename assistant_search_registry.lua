-- Search Tool Registry for UI-added web search API keys stored in settings as JSON.
--
-- The registry stores UI-added search tool credentials in settings under the
-- "ui_search_tools" key as a JSON string. On startup, these are merged with
-- file-based search tool config from configuration.lua into a unified
-- CONFIGURATION.provider_settings table.
--
-- Each UI search tool record uses a fixed tool key (serpapi, tavilyapi, exaapi,
-- searxngapi) and fields: api_key or base_url (display_name is NOT stored).
--
-- File search tools are imported as-is with source="file", immutable=true
-- injected. UI search tools override file config with the same tool key.

local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonTable = require("ui/widget/buttontable")
local json = require("rapidjson")
local logger = require("logger")
local T = require("ffi/util").template
local koutil = require("util")
local _ = require("assistant_gettext")

local SearchRegistry = {}

-- Current schema version for forward compatibility
local SCHEMA_VERSION = 1

--- Fixed search tool definitions.
--- `needs` indicates the required credential field for each tool.
SearchRegistry.SEARCH_TOOLS = {
    serpapi    = { needs = "api_key",  display_name = "SerpAPI" },
    tavilyapi  = { needs = "api_key",  display_name = "Tavily" },
    exaapi     = { needs = "api_key",  display_name = "Exa.ai" },
    searxngapi = { needs = "base_url", display_name = "SearXNG" },
}

-- All fixed tool keys as an ordered list
SearchRegistry.TOOL_KEYS = { "serpapi", "tavilyapi", "exaapi", "searxngapi" }

----------------------------------------------------------------------
-- Load / Save
----------------------------------------------------------------------

--- Load UI search tools from settings.
--- Returns a table: { tools = { [tool_key] = record, ... } }
--- If no UI search tools exist or JSON is corrupt, returns a fresh empty structure.
---@param settings table LuaSettings instance
---@return table
function SearchRegistry.load(settings)
    local raw = settings:readSetting("ui_search_tools")
    if not raw then
        return { tools = {} }
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        logger.warn("SearchRegistry: ui_search_tools JSON corrupt, starting fresh")
        return { tools = {} }
    end

    if decoded.schema_version ~= SCHEMA_VERSION then
        logger.warn("SearchRegistry: schema version mismatch (got ",
            tostring(decoded.schema_version), ", expected ", SCHEMA_VERSION, "), starting fresh")
        return { tools = {} }
    end

    if type(decoded.tools) ~= "table" then
        decoded.tools = {}
    end

    return decoded
end

--- Save UI search tools to settings as a JSON string.
---@param settings table LuaSettings instance
---@param data table The UI search tools data structure (from load())
---@return boolean ok
function SearchRegistry.save(settings, data)
    local to_save = {
        schema_version = SCHEMA_VERSION,
        tools = data.tools or {},
    }

    local ok, encoded = pcall(json.encode, to_save)
    if not ok then
        logger.warn("SearchRegistry: failed to encode ui_search_tools JSON")
        return false
    end

    settings:saveSetting("ui_search_tools", encoded)
    return true
end

----------------------------------------------------------------------
-- Validate
----------------------------------------------------------------------

--- Validate a search tool record before saving.
---@param record table The search tool fields to validate
---@param tool_key string The tool key (serpapi, tavilyapi, exaapi, searxngapi)
---@return boolean ok
---@return string|nil err
function SearchRegistry.validate(record, tool_key)
    if type(record) ~= "table" then
        return false, _("Search tool record must be a table.")
    end

    local tool_def = SearchRegistry.SEARCH_TOOLS[tool_key]
    if not tool_def then
        return false, T(_("Unknown search tool: %1"), tostring(tool_key))
    end

    -- Check the required credential field
    if tool_def.needs == "api_key" then
        if not record.api_key or type(record.api_key) ~= "string"
            or record.api_key:match("^%s*$") then
            return false, T(_("API key is required for %1."), tool_def.display_name)
        end
    elseif tool_def.needs == "base_url" then
        if not record.base_url or type(record.base_url) ~= "string"
            or record.base_url:match("^%s*$") then
            return false, T(_("Base URL is required for %1."), tool_def.display_name)
        end
        if not record.base_url:match("^https?://") then
            return false, _("Base URL must start with http:// or https://")
        end
    end

    return true
end

----------------------------------------------------------------------
-- Merge
----------------------------------------------------------------------

--- Merge file-based search tools and UI search tools into a single
--- provider_settings sub-table. File search tools keep their original key;
--- UI search tools use their fixed tool key. UI records override file
--- records with the same key.
---@param file_config table|nil The CONFIGURATION table from configuration.lua
---@param ui_data table The decoded UI search tools table from SearchRegistry.load()
---@return table merged Merged table keyed by tool key
function SearchRegistry.merge(file_config, ui_data)
    local merged = {}

    -- 1. Import file search tools (shallow copy, inject metadata)
    if file_config and file_config.provider_settings then
        for _, key in ipairs(SearchRegistry.TOOL_KEYS) do
            local record = file_config.provider_settings[key]
            if type(record) == "table" then
                local copy = {}
                koutil.tableMerge(copy, record)
                copy.source = "file"
                copy.immutable = true
                merged[key] = copy
            end
        end
    end

    -- 2. Import UI search tools (shallow copy, override file records)
    if ui_data and ui_data.tools then
        for key, record in pairs(ui_data.tools) do
            if type(record) == "table" and SearchRegistry.SEARCH_TOOLS[key] then
                local copy = {}
                koutil.tableMerge(copy, record)
                copy.source = "ui"
                merged[key] = copy
            end
        end
    end

    return merged
end

----------------------------------------------------------------------
-- Mutations
----------------------------------------------------------------------

--- Upsert a UI search tool: insert or update the record for a fixed tool key.
--- Validates the record before saving.
---@param data table The full UI data structure (from load())
---@param tool_key string The fixed tool key
---@param record table { api_key?, base_url? }
---@return boolean ok
---@return string|nil err
function SearchRegistry.upsert(data, tool_key, record)
    local tool_def = SearchRegistry.SEARCH_TOOLS[tool_key]
    if not tool_def then
        return false, T(_("Unknown search tool: %1"), tostring(tool_key))
    end

    local ok, err = SearchRegistry.validate(record, tool_key)
    if not ok then
        return false, err
    end

    data.tools[tool_key] = {
        api_key = record.api_key,
        base_url = record.base_url,
    }

    return true
end

--- Delete a UI search tool by its fixed tool key.
---@param data table The full UI data structure (from load())
---@param tool_key string The tool key
---@return boolean ok
---@return string|nil err
function SearchRegistry.delete(data, tool_key)
    if not data.tools[tool_key] then
        return false, _("Search tool not found.")
    end
    data.tools[tool_key] = nil
    return true
end

--- Convenience: check whether a merged search tool record is deletable.
---@param record table A merged provider_settings entry for a search tool
---@return boolean
function SearchRegistry.is_deletable(record)
    return record
        and record.source == "ui"
        and not record.immutable
end

----------------------------------------------------------------------
-- Install / Update (convenience wrappers for assistant integration)
----------------------------------------------------------------------

--- Install or update a UI search tool: validate, save, merge into memory,
--- and call ToolExecutor.SetSearchAPIConfig.
---@param assistant table The Assistant instance
---@param tool_key string The fixed tool key
---@param api_key string|nil
---@param base_url string|nil
---@return boolean ok
---@return string|nil err
function SearchRegistry.installSearchTool(assistant, tool_key, api_key, base_url)
    if not assistant._ui_search_data then
        return false, _("Search tool data not initialized.")
    end

    local record = {
        api_key = api_key ~= "" and api_key or nil,
        base_url = base_url ~= "" and base_url or nil,
    }
    local ok, err = SearchRegistry.upsert(assistant._ui_search_data, tool_key, record)
    if not ok then
        return false, err
    end

    SearchRegistry.save(assistant.settings, assistant._ui_search_data)
    assistant.updated = true

    -- Update in-memory merged config: UI record overrides file config
    local merged_ps = assistant.CONFIGURATION.provider_settings or {}
    merged_ps[tool_key] = {
        api_key = record.api_key,
        base_url = record.base_url,
        source = "ui",
    }
    assistant.CONFIGURATION.provider_settings = merged_ps

    -- Push config into the extools module so searches work immediately
    local ToolExecutor = require("assistant_tool_executor")
    ToolExecutor.SetSearchAPIConfig(assistant.CONFIGURATION)

    return true
end

--- Delete a UI search tool and refresh in-memory config.
---@param assistant table The Assistant instance
---@param tool_key string The tool key
---@return boolean ok
---@return string|nil err
function SearchRegistry.deleteSearchTool(assistant, tool_key)
    if not assistant._ui_search_data then
        return false, _("Search tool data not initialized.")
    end

    local ok, err = SearchRegistry.delete(assistant._ui_search_data, tool_key)
    if not ok then
        return false, err
    end

    SearchRegistry.save(assistant.settings, assistant._ui_search_data)
    assistant.updated = true

    -- Remove from merged config or fall back to file config
    local merged_ps = assistant.CONFIGURATION.provider_settings or {}
    -- Check if file config has this key
    local has_file = false
    if CONFIGURATION and CONFIGURATION.provider_settings and CONFIGURATION.provider_settings[tool_key] then
        local file_copy = {}
        koutil.tableMerge(file_copy, CONFIGURATION.provider_settings[tool_key])
        file_copy.source = "file"
        file_copy.immutable = true
        merged_ps[tool_key] = file_copy
        has_file = true
    end
    if not has_file then
        merged_ps[tool_key] = nil
    end
    assistant.CONFIGURATION.provider_settings = merged_ps

    local ToolExecutor = require("assistant_tool_executor")
    ToolExecutor.SetSearchAPIConfig(assistant.CONFIGURATION)

    return true
end

----------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------

--- Build the "Add Web Search API" menu item for the Settings Other Settings submenu.
--- Returns a TouchMenu item with a sub-menu listing the four search tools.
---@param assistant table The Assistant instance
---@return table menu item spec
function SearchRegistry.getAddWebSearchMenuItem(assistant)
    return {
        text = _("Add Web Search API"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local items = {}
            for i, tool_key in ipairs(SearchRegistry.TOOL_KEYS) do
                local def = SearchRegistry.SEARCH_TOOLS[tool_key]
                table.insert(items, {
                    text = def.display_name,
                    keep_menu_open = true,
                    callback = function()
                        assistant:_showAddWebSearchDialog(tool_key)
                    end,
                    hold_callback = function()
                        local merged = koutil.tableGetValue(
                            assistant.CONFIGURATION, "provider_settings", tool_key)
                        local deletable = SearchRegistry.is_deletable(merged)

                        local confirm = ConfirmBox:new{
                            text = T(_("%1 — choose an action"), def.display_name),
                            no_ok_button = true,
                            cancel_text = "",
                        }

                        -- Replace internal button_table with single-row layout:
                        -- Widget tree: confirm.movable[1] → FrameContainer → [1] → VerticalGroup → [3] → ButtonTable
                        local vgroup = confirm.movable[1][1]
                        local bt_width = vgroup[3].width
                        vgroup[3] = ButtonTable:new{
                            width = bt_width,
                            buttons = {{
                                {
                                    text = _("Cancel"),
                                    callback = function()
                                        UIManager:close(confirm)
                                    end,
                                },
                                {
                                    text = _("Edit"),
                                    callback = function()
                                        UIManager:close(confirm)
                                        assistant:_showAddWebSearchDialog(tool_key)
                                    end,
                                },
                                {
                                    text = _("Delete"),
                                    enabled = deletable,
                                    callback = function()
                                        SearchRegistry.deleteSearchTool(assistant, tool_key)
                                        UIManager:close(confirm)
                                    end,
                                },
                            }},
                            zero_sep = true,
                            show_parent = confirm,
                        }

                        -- Invalidate cached sizes so the frame re-layouts on paint
                        vgroup._size = nil
                        vgroup._offsets = nil
                        confirm.movable[1]._size = nil
                        confirm.movable._size = nil
                        confirm.movable.dimen = nil

                        UIManager:show(confirm)
                    end,
                })
            end
            return items
        end,
    }
end

return SearchRegistry
