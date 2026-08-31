-- assistant_config.lua
-- Encapsulates the effective configuration table and its accessors.
-- Config owns the in-memory CONFIGURATION (built from configuration.lua
-- merged with UI registries persisted in settings). All read/write helpers
-- for providers, features, and search tools live here, keeping them out
-- of the main Assistant class.

local Config = {}
Config.__index = Config

local koutil = require("util")
local FFIUtil = require("ffi/util")

---------------------------------------------------------------------------
-- Static (module-level) helpers — no instance required
---------------------------------------------------------------------------

--- Validate a configuration file by loading and executing it.
--- Returns (true, nil) on success, (false, error_string) on failure.
--- @param filePath string Path to the Lua configuration file.
function Config.testConfigFile(filePath)
    local env = {}
    setmetatable(env, {__index = _G})
    local chunk, err = loadfile(filePath, "t", env)
    if not chunk then return false, err end
    local success, result = pcall(chunk)
    if not success then return false, result end
    return true, nil
end

--- Return the plugin directory path (e.g. "<data>/plugins/assistant.koplugin").
--- Uses DataStorage directly to avoid depending on Assistant.name.
function Config.getAssistantDir()
    local DataStorage = require("datastorage")
    return FFIUtil.joinPath(FFIUtil.joinPath(DataStorage:getDataDir(), "plugins"), "assistant.koplugin")
end

--- Return the full path to configuration.lua.
function Config.getConfigPath()
    return FFIUtil.joinPath(Config.getAssistantDir(), "configuration.lua")
end

--- Return the full path to _meta.lua.
function Config.getMetaPath()
    return FFIUtil.joinPath(Config.getAssistantDir(), "_meta.lua")
end

--- Load the raw configuration table from configuration.lua.
--- Returns (rawConfig, loadError).
---   rawConfig  – the table returned by dofile(), or nil on failure.
---   loadError  – a string describing the error, or nil on success.
--- Mimics the former main.lua top-level load: test for syntax errors first,
--- then pcall(dofile) and collect any runtime error.
function Config.loadRawConfig()
    local logger = require("logger")
    local configPath = Config.getConfigPath()

    -- 1. Syntax / compile-time check
    local ok, test_err = Config.testConfigFile(configPath)
    if not ok then
        -- 2. Still try to dofile so we get the runtime error too (original
        --    behaviour: both testConfigFile error AND dofile error are captured).
        local success, result = pcall(function() return dofile(configPath) end)
        if success then
            return result, test_err  -- loaded despite syntax warning
        else
            logger.warn(result)
            return nil, test_err  -- prefer the syntax error message
        end
    end

    -- 3. Normal load
    local success, result = pcall(function() return dofile(configPath) end)
    if success then
        return result, nil
    else
        logger.warn(result)
        return nil, result
    end
end

---------------------------------------------------------------------------
-- Instance methods
---------------------------------------------------------------------------

--- Create a new Config object.
--- @param o table { assistant = Assistant, data = CONFIGURATION, loadError = string|nil }
function Config:new(o)
    local self = setmetatable({}, Config)
    self._assistant = o.assistant
    self._data = o.data or {}
    self._loadError = o.loadError or nil
    return self
end

--- Return the load error captured during Config.loadRawConfig(), if any.
function Config:getLoadError()
    return self._loadError
end

--- Set (or clear) the load error on this instance.
function Config:setLoadError(err)
    self._loadError = err
end

--- Clear the load error on this instance.
function Config:clearLoadError()
    self._loadError = nil
end

--- Read a feature value from the effective CONFIGURATION.features table.
--- @param feature_key string Feature name (e.g. "prompts"), not an API key.
--- @param default any Fallback value when the key is absent.
function Config:getFeature(feature_key, default)
    local v = koutil.tableGetValue(self._data, "features", feature_key)
    if v == nil then return default end
    return v
end

--- Returns the provider *record table* for a given ID.
--- @param id string Provider identifier (e.g. "openai_perplexity" or "custom:1"), not the API key.
function Config:getProvider(id)
    if not id or id == "" then return nil end
    local v = koutil.tableGetValue(self._data, "provider_settings", id)
    if v == nil or v == require("rapidjson").null then return nil end
    return v
end

--- Returns the entire provider_settings table from CONFIGURATION.
function Config:getProviderSettings()
    return koutil.tableGetValue(self._data, "provider_settings") or {}
end

--- Returns the entire features table from CONFIGURATION.
function Config:getFeatures()
    return koutil.tableGetValue(self._data, "features") or {}
end

--- True when provider has model/base_url/api_key. Model may be
--- provider.model or selected_model_<id> (for file-providers that
--- omit model in configuration.lua and let the user pick via UI).
function Config:isProviderEnabled(id)
    if not id or id == "" then return false end
    local provider = self:getProvider(id)
    if not provider or type(provider) ~= "table" then return false end
    local hasModel = provider.model and provider.model ~= ""
    if not hasModel then
        local assistant = self._assistant
        if assistant and assistant.settings then
            local sel = assistant.settings:readSetting("selected_model_" .. id)
            if sel and sel ~= "" then hasModel = true end
        end
    end
    local hasBaseUrl = provider.base_url and provider.base_url ~= ""
    local hasApiKey = provider.api_key and provider.api_key ~= ""
    return hasModel and hasBaseUrl and hasApiKey
end

--- Returns the *key/ID string* of the active provider (e.g. "openai_foo" or
--- "custom:1"). Resolves the selection with fallback logic: saved setting →
--- configuration.lua default → first `default=true` provider → any enabled.
--- On fallback, persists the new selection to self.settings.
function Config:getActiveProviderId()
    if type(self._data) ~= "table" then
        return nil
    end

    local provider_settings = self:getProviderSettings()
    if type(provider_settings) ~= "table" then
        return nil
    end
    local assistant = self._assistant
    local setting_provider = assistant.settings:readSetting("provider")

    local function find_setting_provider(filter_func)
        for key, tab in pairs(provider_settings) do
            if self:isProviderEnabled(key) then
                if filter_func and filter_func(key, tab) then return key end
                if not filter_func then return key end
            end
        end
        return nil
    end

    if self:isProviderEnabled(setting_provider) then
        -- If the setting provider is valid, use it
        return setting_provider
    else
        -- If the setting provider is invalid, delete this selection
        assistant.settings:delSetting("provider")

        local conf_provider = self._data.provider -- provider name from configuration.lua
        if self:isProviderEnabled(conf_provider) then
            -- if the configuration provider is valid, use it
            setting_provider = conf_provider
        else
            -- try to find the one defined with `default = true`
            setting_provider = find_setting_provider(function(key, tab)
                return koutil.tableGetValue(tab, "default") == true
            end)

            -- still invalid (none of them defined `default`)
            if not setting_provider then
                setting_provider = find_setting_provider()
                local logger = require("logger")
                logger.warn("Invalid provider setting found, using a random one: ", setting_provider)
            end
        end

        if not setting_provider then
            return nil
        end
        assistant.settings:saveSetting("provider", setting_provider)
        assistant.updated = true -- mark settings as updated
    end
    return setting_provider
end

--- Write a provider record into the effective CONFIGURATION.provider_settings,
--- then hot-reload the querier and ToolExecutor.
--- Mutates only the in-memory CONFIGURATION and marks assistant.updated;
--- configuration.lua is never written.
function Config:setProvider(id, record)
    if not id or id == "" then return nil, "invalid id" end
    self._data = self._data or {}
    self._data.provider_settings = self._data.provider_settings or {}
    self._data.provider_settings[id] = record
    local assistant = self._assistant
    if record ~= nil then
        if assistant.querier and assistant.querier.load_model then
            pcall(function() assistant.querier:load_model(id) end)
        end
    end
    require("assistant_tool_executor").SetSearchAPIConfig(assistant)
    assistant.updated = true
    return true
end

--- Remove a provider from the effective CONFIGURATION.provider_settings and
--- refresh ToolExecutor config.
--- Mutates only the in-memory CONFIGURATION; configuration.lua is never written.
function Config:deleteProvider(id)
    if not id or id == "" then return nil, "invalid id" end
    local ps = koutil.tableGetValue(self._data, "provider_settings")
    if ps then
        ps[id] = nil
        require("assistant_tool_executor").SetSearchAPIConfig(self._assistant)
        self._assistant.updated = true
    end
    return true
end

--- Thin wrapper: search tools share the provider_settings table under fixed
--- keys (serpapi, tavilyapi, …). Delegates to setProvider.
--- @param tool_key string Fixed search-tool key (e.g. "serpapi"), not an API key.
function Config:setSearchTool(tool_key, record)
    return self:setProvider(tool_key, record)
end

--- Thin wrapper: search tools share the provider_settings table under fixed
--- keys (serpapi, tavilyapi, …). Delegates to deleteProvider.
--- @param tool_key string Fixed search-tool key (e.g. "serpapi"), not an API key.
function Config:deleteSearchTool(tool_key)
    return self:deleteProvider(tool_key)
end

--- Build the effective CONFIGURATION table from the raw dofile() result of
--- configuration.lua merged with UI registries persisted in assistant.settings.
--- Updates self._data to the effective table and returns it.
--- The raw table is never mutated; provider_settings is rebuilt via
--- Registry/SearchRegistry merges. configuration.lua remains read-only.
function Config:buildEffectiveConfig(rawConfig)
    rawConfig = rawConfig or self._data
    local Registry = require("assistant_provider_registry")
    local SearchRegistry = require("assistant_search_registry")
    local assistant = self._assistant

    local ui_data = Registry.load(assistant.settings)
    local merged_ps = Registry.merge(rawConfig, ui_data)
    assistant._ui_provider_data = ui_data

    local ui_search_data = SearchRegistry.load(assistant.settings)
    local merged_search = SearchRegistry.merge(rawConfig, ui_search_data)
    assistant._ui_search_data = ui_search_data

    local effective = {}
    if rawConfig then
        for k, v in pairs(rawConfig) do
            effective[k] = v
        end
    end
    -- shallow-copy features sharing is intentional; provider_settings is rebuilt
    effective.provider_settings = merged_ps or {}
    if merged_search then
        for key, record in pairs(merged_search) do
            effective.provider_settings[key] = record
        end
    end
    self._data = effective
    return effective
end

return Config
