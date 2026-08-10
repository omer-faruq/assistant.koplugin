-- Provider Registry for UI-added providers stored in settings as JSON.
--
-- The registry stores UI-added providers in settings under the "ui_providers" key
-- as a JSON string. On startup, these are merged with file-based providers from
-- configuration.lua into a unified CONFIGURATION.provider_settings table.
--
-- Each UI provider record has a stable internal ID ("custom:<n>") and fields:
--   display_name, handler, model, base_url, api_key, additional_parameters
--
-- File providers are imported as-is with source="file", immutable=true injected.

local json = require("rapidjson")
local logger = require("logger")
local _ = require("assistant_gettext")

local Registry = {}

-- Current schema version for forward compatibility
local SCHEMA_VERSION = 1

-- Supported API handler names (must match api_handlers/ .lua files)
Registry.HANDLERS = {
    openai    = true,
    anthropic = true,
    gemini    = true,
    responses = true,
}

-- Default base URLs for each handler (used as pre-fill hint in UI)
Registry.DEFAULT_BASE_URLS = {
    openai    = "https://api.openai.com/v1",
    anthropic = "https://api.anthropic.com/v1",
    gemini    = "https://generativelanguage.googleapis.com/v1beta",
    responses = "https://api.openai.com/v1",
}

----------------------------------------------------------------------
-- Load / Save
----------------------------------------------------------------------

--- Load UI providers from settings.
--- Returns a table: { providers = { [id] = record, ... }, _next_id = n }
--- If no UI providers exist or JSON is corrupt, returns a fresh empty structure.
---@param settings table LuaSettings instance
---@return table
function Registry.load(settings)
    local raw = settings:readSetting("ui_providers")
    if not raw then
        return { providers = {}, _next_id = 1 }
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        logger.warn("Registry: ui_providers JSON corrupt, starting fresh")
        return { providers = {}, _next_id = 1 }
    end

    if decoded.schema_version ~= SCHEMA_VERSION then
        logger.warn("Registry: schema version mismatch (got ",
            tostring(decoded.schema_version), ", expected ", SCHEMA_VERSION, "), starting fresh")
        return { providers = {}, _next_id = 1 }
    end

    if type(decoded.providers) ~= "table" then
        decoded.providers = {}
    end
    if type(decoded._next_id) ~= "number" then
        decoded._next_id = 1
    end

    return decoded
end

--- Save UI providers to settings as a JSON string.
---@param settings table LuaSettings instance
---@param data table The UI provider data structure (from load())
---@return boolean ok
function Registry.save(settings, data)
    local to_save = {
        schema_version = SCHEMA_VERSION,
        providers = data.providers or {},
        _next_id = data._next_id or 1,
    }

    local ok, encoded = pcall(json.encode, to_save)
    if not ok then
        logger.warn("Registry: failed to encode ui_providers JSON")
        return false
    end

    settings:saveSetting("ui_providers", encoded)
    return true
end

----------------------------------------------------------------------
-- Merge
----------------------------------------------------------------------

--- Merge file-based providers and UI providers into a single provider_settings table.
--- File providers keep their original key; UI providers use their stable ID as key.
--- Injects source="file"/immutable=true on file records, source="ui" on UI records.
---@param file_config table|nil The CONFIGURATION table from configuration.lua (nil if load failed)
---@param ui_data table The decoded UI providers table from Registry.load()
---@return table|nil provider_settings Merged table, or nil if both sources are empty
function Registry.merge(file_config, ui_data)
    local merged = {}
    local has_any = false

    -- 1. Import file providers (shallow copy, inject metadata)
    if file_config and file_config.provider_settings then
        for key, record in pairs(file_config.provider_settings) do
            if type(record) == "table" then
                local copy = {}
                for k, v in pairs(record) do
                    copy[k] = v
                end
                copy.source = "file"
                copy.immutable = true
                merged[key] = copy
                has_any = true
            end
        end
    end

    -- 2. Import UI providers (shallow copy with collision check)
    if ui_data and ui_data.providers then
        for id, record in pairs(ui_data.providers) do
            if type(record) == "table" then
                if merged[id] then
                    logger.warn("Registry: UI provider id collision, skipping: ", id)
                else
                    local copy = {}
                    for k, v in pairs(record) do
                        copy[k] = v
                    end
                    copy.source = "ui"
                    merged[id] = copy
                    has_any = true
                end
            end
        end
    end

    if not has_any then
        return nil
    end

    return merged
end

----------------------------------------------------------------------
-- Validate
----------------------------------------------------------------------

--- Validate a provider record before saving.
--- Auto-fills model to "auto" if empty.
---@param record table The provider fields to validate
---@return boolean ok
---@return string|nil err
function Registry.validate(record)
    if type(record) ~= "table" then
        return false, _("Provider record must be a table.")
    end

    -- display_name
    if not record.display_name or type(record.display_name) ~= "string"
        or record.display_name:match("^%s*$") then
        return false, _("Provider name is required.")
    end

    -- handler
    if not record.handler or not Registry.HANDLERS[record.handler] then
        return false, _("Unsupported API protocol.")
    end

    -- model: default to "auto" if empty
    if not record.model or type(record.model) ~= "string"
        or record.model:match("^%s*$") then
        record.model = "auto"
    end

    -- base_url
    if not record.base_url or type(record.base_url) ~= "string" then
        return false, _("Base URL is required.")
    end
    if not record.base_url:match("^https?://") then
        return false, _("Base URL must start with http:// or https://")
    end

    -- api_key
    if not record.api_key or type(record.api_key) ~= "string"
        or record.api_key:match("^%s*$") then
        return false, _("API key is required.")
    end

    -- additional_parameters (default empty)
    if not record.additional_parameters or type(record.additional_parameters) ~= "table" then
        record.additional_parameters = {}
    end

    return true
end

----------------------------------------------------------------------
-- Mutations
----------------------------------------------------------------------

--- Add a new UI provider. Generates a stable ID, validates fields, inserts into data.
---@param data table The full UI data structure (from load())
---@param fields table { display_name, handler, base_url, api_key, model, additional_parameters? }
---@return string|nil id The new provider ID
---@return string|nil err
function Registry.add(data, fields)
    local ok, err = Registry.validate(fields)
    if not ok then
        return nil, err
    end

    local id = "custom:" .. tostring(data._next_id)
    data._next_id = data._next_id + 1

    local record = {
        display_name = fields.display_name,
        handler = fields.handler,
        model = fields.model,
        base_url = fields.base_url,
        api_key = fields.api_key,
        additional_parameters = fields.additional_parameters or {},
    }
    data.providers[id] = record

    return id
end

--- Delete a UI provider by its stable ID.
---@param data table The full UI data structure (from load())
---@param id string The provider's stable ID
---@return boolean ok
---@return string|nil err
function Registry.delete(data, id)
    if not data.providers[id] then
        return false, _("Provider not found.")
    end
    data.providers[id] = nil
    return true
end

--- Convenience: check whether a merged provider record is deletable.
---@param provider table A merged provider_settings entry
---@return boolean
function Registry.is_deletable(provider)
    return provider
        and provider.source == "ui"
        and not provider.immutable
end

--- Install a newly added UI provider: save, update in-memory config, load into querier.
---@param assistant table The Assistant instance
---@param handler string
---@param base_url string
---@param display_name string
---@param api_key string
---@param model string
---@return string|nil id
---@return string|nil err
function Registry.installProvider(assistant, handler, base_url, display_name, api_key, model)
    if not assistant._ui_provider_data then
        return nil, _("Provider data not initialized.")
    end

    local record = {
        display_name = display_name,
        handler = handler,
        base_url = base_url,
        api_key = api_key,
        model = model ~= "" and model or "auto",
    }
    local id, err = Registry.add(assistant._ui_provider_data, record)
    if not id then
        return nil, err
    end
    Registry.save(assistant.settings, assistant._ui_provider_data)
    assistant.updated = true

    -- Update in-memory merged config
    local merged_ps = assistant.CONFIGURATION.provider_settings or {}
    merged_ps[id] = {
        display_name = record.display_name,
        handler = record.handler,
        model = record.model,
        base_url = record.base_url,
        api_key = record.api_key,
        additional_parameters = {},
        source = "ui",
    }
    assistant.CONFIGURATION.provider_settings = merged_ps

    -- Load the new provider (only if querier exists; first provider needs restart)
    if assistant.querier then
        assistant.querier:load_model(id)
    end

    return id
end

return Registry
