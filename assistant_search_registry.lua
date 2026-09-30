-- Search Tool Registry for UI-added web search API keys stored in settings as JSON.
--
-- The registry stores UI-added search tool credentials in settings under the
-- "ui_search_tools" key as a JSON string. On startup, these are merged with
-- file-based search tool config from configuration.lua into a unified
-- CONFIGURATION.provider_settings table.
--
-- The set of tool keys, their required credential field and their display names
-- live in assistant_search_tools (the UI-free catalog); this module only
-- persists and validates credentials for them. Each stored record holds exactly
-- the one credential field the catalog declares for its tool - never both, and
-- never an empty string.
--
-- File search tools are imported as-is with source="file", immutable=true
-- injected. UI search tools override file config with the same tool key.

local UIManager = require("ui/uimanager")
local DocUtils = require("assistant_doc_utils")
local SearchTools = require("assistant_search_tools")
local ButtonDialog = require("ui/widget/buttondialog")
local json = require("rapidjson")
local logger = require("logger")
local T = require("ffi/util").template
local koutil = require("util")
local _ = require("assistant_gettext")

local SearchRegistry = {}

-- Current schema version for forward compatibility
local SCHEMA_VERSION = 1

--- Extract the credential a tool actually uses from a record, normalizing an
--- empty string to absent. Yields an empty table when the field is missing or
--- blank, so a record can never carry a credential the tool ignores.
---@param record table A candidate record
---@param needs string The catalog field the tool declares ("api_key"/"base_url")
---@return table normalized A table holding at most `needs`
local function credentialOnly(record, needs)
    local value = record[needs]
    if type(value) ~= "string" or value == "" then
        return {}
    end
    return { [needs] = value }
end

--- Same as `credentialOnly`, plus the source tag the in-memory config needs.
---@param record table A stored UI record
---@param tool_key string The fixed tool key
---@param source string The source tag to inject ("ui")
---@return table|nil A config-ready record, or nil for an unknown tool key
local function toConfigRecord(record, tool_key, source)
    local def = SearchTools.getDefinition(tool_key)
    if not def then
        return nil
    end
    local out = credentialOnly(record, def.needs)
    out.source = source
    return out
end

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

    local tool_def = SearchTools.getDefinition(tool_key)
    if not tool_def then
        return false, T(_("Unknown search tool: %1"), tostring(tool_key))
    end

    -- Check the required credential field (shared normalization gate).
    local name = tool_def.display_name
    local ok, err
    if tool_def.needs == "api_key" then
        ok, err = DocUtils.validate_credential_field(record, "api_key", {
            required = T(_("API key is required for %1."), name),
            whitespace = T(_("API key must not contain spaces or line breaks for %1."), name),
        })
    elseif tool_def.needs == "base_url" then
        ok, err = DocUtils.validate_credential_field(record, "base_url", {
            required = T(_("Base URL is required for %1."), name),
            scheme = _("Base URL must start with http:// or https://"),
            whitespace = _("Base URL must not contain spaces."),
        })
    end
    if not ok then
        return false, err
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
        for idx, key in ipairs(SearchTools.TOOL_KEYS) do
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
            if type(record) == "table" and SearchTools.isExternalTool(key) then
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
--- Validates the record before saving, then stores only the credential field
--- the catalog declares for that tool - so a field the caller supplied but the
--- tool never uses is dropped instead of being persisted.
---@param data table The full UI data structure (from load())
---@param tool_key string The fixed tool key
---@param record table { api_key?, base_url? }
---@return boolean ok
---@return string|nil err
function SearchRegistry.upsert(data, tool_key, record)
    local tool_def = SearchTools.getDefinition(tool_key)
    if not tool_def then
        return false, T(_("Unknown search tool: %1"), tostring(tool_key))
    end

    local ok, err = SearchRegistry.validate(record, tool_key)
    if not ok then
        return false, err
    end

    data.tools[tool_key] = credentialOnly(record, tool_def.needs)

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
    assistant.config:setSearchTool(tool_key,
        toConfigRecord(assistant._ui_search_data.tools[tool_key], tool_key, "ui"))

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
    assistant.config:deleteSearchTool(tool_key)

    return true
end

----------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------

--- Build the "WebSearch API" menu item for the Settings submenu.
--- Returns a TouchMenu item with a sub-menu listing the four search tools.
---@param assistant table The Assistant instance
---@return table menu item spec
function SearchRegistry.getAddWebSearchMenuItem(assistant)
    return {
        text = _("WebSearch API"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local items = {}
            for i, tool_key in ipairs(SearchTools.TOOL_KEYS) do
                local def = SearchTools.getDefinition(tool_key)
                table.insert(items, {
                    text_func = function()
                        local merged = assistant.config:getProvider(tool_key)
                        local configured = merged and (
                            (type(merged.api_key) == "string" and #merged.api_key > 0) or
                            (type(merged.base_url) == "string" and #merged.base_url > 0)
                        )
                        return (configured and "☑ " or "☐ ") .. def.display_name
                    end,
                    keep_menu_open = true,
                    callback = function()
                        assistant:_showAddWebSearchDialog(tool_key)
                    end,
                    hold_callback = function()
                        local merged = assistant.config:getProvider(tool_key)
                        local deletable = SearchRegistry.is_deletable(merged)

                        local dialog
                        dialog = ButtonDialog:new{
                            title = T(_("%1 - choose an action"), def.display_name),
                            buttons = {{
                                {
                                    text = _("Cancel"),
                                    callback = function()
                                        UIManager:close(dialog)
                                    end,
                                },
                                {
                                    text = _("Edit"),
                                    callback = function()
                                        UIManager:close(dialog)
                                        assistant:_showAddWebSearchDialog(tool_key)
                                    end,
                                },
                                {
                                    text = _("Delete"),
                                    enabled = deletable,
                                    callback = function()
                                        SearchRegistry.deleteSearchTool(assistant, tool_key)
                                        UIManager:close(dialog)
                                    end,
                                },
                            }},
                        }

                        UIManager:show(dialog)
                    end,
                })
            end
            return items
        end,
    }
end

return SearchRegistry
