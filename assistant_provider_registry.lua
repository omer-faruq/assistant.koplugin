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
local koutil = require("util")
local _ = require("assistant_gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Trapper = require("ui/trapper")
local ASUtils = require("assistant_utils")
local T = require("ffi/util").template

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

-- Default base URLs for each handler (used as pre-fill hint in UI).
-- Gemini: the native API path format is /v1beta/models/{model}:generateContent
-- and models.list is /v1beta/models, so base_url must include the /models
-- segment (see configuration.sample.lua and api_handlers/gemini.lua).
Registry.DEFAULT_BASE_URLS = {
    openai    = "https://api.openai.com/v1",
    anthropic = "https://api.anthropic.com/v1",
    gemini    = "https://generativelanguage.googleapis.com/v1beta/models",
    responses = "https://api.openai.com/v1",
}

-- Per-handler guidance shown as the Base URL field description in the
-- add/edit provider dialog (falls back to a generic hint for other handlers).
local BASE_URL_DESCRIPTIONS = {
    openai    = _("OpenAI-compatible chat/completions endpoint, e.g. https://api.openai.com/v1"),
    responses = _("OpenAI Responses API — Include built-in web search"),
    gemini    = _("Gemini API. must include the /models segment, e.g. …/v1beta/models"),
    anthropic = _("Anthropic Messages API"),
}

-- Preset platforms offered in the "Provider API" sub-menu.
-- Selecting one only asks for the API key (name/base_url come from here).
-- Each preset carries provider-specific additional_parameters that default to
-- reducing/disabling the reasoning/thinking chain (see configuration.sample.lua).
local PRESET_PROVIDERS = {
    { name = "OpenAI", handler = "openai", base_url = "https://api.openai.com/v1" },
    { name = "OpenAI - Responses", handler = "responses", base_url = "https://api.openai.com/v1" },
    { name = "Gemini",     handler = "gemini",   base_url = "https://generativelanguage.googleapis.com/v1beta/models",
      additional_parameters = {
          temperature = 0.7,
          thinking_budget = 0,
      } },
    { name = "Anthropic",  handler = "anthropic", base_url = "https://api.anthropic.com/v1",
      additional_parameters = {
          anthropic_version = "2023-06-01",
          max_tokens = 4096,
      } },
    { name = "DeepSeek",   handler = "openai",   base_url = "https://api.deepseek.com/v1",
      additional_parameters = {
          temperature = 0.7,
          max_tokens = 4096,
          thinking = { type = "disabled" },
      } },
    { name = "OpenRouter", handler = "openai",   base_url = "https://openrouter.ai/api/v1",
      additional_parameters = {
          temperature = 0.7,
          max_tokens = 4096,
          reasoning = { effort = "none" },
      } },
}
Registry.PRESET_PROVIDERS = PRESET_PROVIDERS

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
                koutil.tableMerge(copy, record)
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
                    koutil.tableMerge(copy, record)
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
        -- Deep copy so the stored record never shares nested tables with the
        -- caller's table (e.g. a shared preset definition).
        additional_parameters = koutil.tableDeepCopy(fields.additional_parameters) or {},
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

--- Edit an existing UI provider in place.  Only mutable fields are updated;
--- the handler, additional_parameters, and stable ID are preserved.
---@param data table The full UI data structure (from load())
---@param id string The provider's stable ID
---@param fields table { display_name, base_url, api_key, model }
---@return boolean ok
---@return string|nil err
function Registry.edit(data, id)
    local existing = data.providers[id]
    if not existing then
        return false, _("Provider not found.")
    end
    return true
end

--- Convenience: check whether a merged provider record is editable (or deletable).
--- Same condition: source="ui" and not immutable.
---@param provider table A merged provider_settings entry
---@return boolean
function Registry.is_editable(provider)
    return Registry.is_deletable(provider)
end

--- Convenience: check whether a merged provider record is deletable.
---@param provider table A merged provider_settings entry
---@return boolean
function Registry.is_deletable(provider)
    return provider
        and provider.source == "ui"
        and not provider.immutable
end

--- Update an existing UI provider: update record, save, refresh merged config.
--- The provider ID and handler are preserved; additional_parameters from the
--- existing record are kept (the edit dialog does not expose them).
---@param assistant table The Assistant instance
---@param id string The provider's stable ID (e.g. "custom:1")
---@param display_name string
---@param base_url string
---@param api_key string
---@param model string
---@return string|nil id
---@return string|nil err
function Registry.updateProvider(assistant, id, display_name, base_url, api_key, model)
    if not assistant._ui_provider_data then
        return nil, _("Provider data not initialized.")
    end

    local existing = assistant._ui_provider_data.providers[id]
    if not existing then
        return nil, _("Provider not found.")
    end

    -- Update mutable fields in place; handler and additional_parameters are kept.
    existing.display_name = display_name
    existing.base_url = base_url
    existing.api_key = api_key
    existing.model = model ~= "" and model or "auto"

    Registry.save(assistant.settings, assistant._ui_provider_data)

    -- Refresh merged config.
    local newRecord = {
        display_name = existing.display_name,
        handler = existing.handler,
        model = existing.model,
        base_url = existing.base_url,
        api_key = existing.api_key,
        additional_parameters = existing.additional_parameters or {},
        source = "ui",
    }
    assistant.config:setProvider(id, newRecord)

    return id
end

--- Install a newly added UI provider: save, update in-memory config, load into querier.
---@param assistant table The Assistant instance
---@param handler string
---@param base_url string
---@param display_name string
---@param api_key string
---@param model string
---@param additional_parameters table|nil Provider-specific additional_parameters
---        (preset defaults; nil is stored as {} for backward compatibility)
---@return string|nil id
---@return string|nil err
function Registry.installProvider(assistant, handler, base_url, display_name, api_key, model, additional_parameters)
    if not assistant._ui_provider_data then
        return nil, _("Provider data not initialized.")
    end

    local record = {
        display_name = display_name,
        handler = handler,
        base_url = base_url,
        api_key = api_key,
        model = model ~= "" and model or "auto",
        additional_parameters = additional_parameters,
    }
    local id, err = Registry.add(assistant._ui_provider_data, record)
    if not id then
        return nil, err
    end
    Registry.save(assistant.settings, assistant._ui_provider_data)

    -- Update merged config.
    local stored = assistant._ui_provider_data.providers[id]
    local newRecord = {
        display_name = record.display_name,
        handler = record.handler,
        model = record.model,
        base_url = record.base_url,
        api_key = record.api_key,
        additional_parameters = stored and stored.additional_parameters or {},
        source = "ui",
    }
    assistant.config:setProvider(id, newRecord)

    return id
end

----------------------------------------------------------------------
-- Add/Edit provider dialog
----------------------------------------------------------------------

--- Show a unified dialog for adding or editing a provider (Name, Base URL, API Key, Model).
--- For preset providers: Name + Base URL are pre-filled from the preset.
--- For Edit (edit_id ~= nil): all fields are pre-filled from the existing record.
--- In add mode a Clear button empties the preset pre-fill (Name, Base URL, Model)
--- while leaving the user-typed API Key untouched.
---@param assistant table The Assistant instance
---@param preset_name string|nil Preset display name
---@param handler string API handler name (e.g. "openai")
---@param base_url string Pre-filled base URL
---@param additional_parameters table|nil Provider-specific additional_parameters
---        (preset defaults; Custom passes nil which is stored as {})
---@param edit_id string|nil When non-nil, edit the existing provider with this ID
function Registry.showProviderDialog(assistant, preset_name, handler, base_url, additional_parameters, edit_id)
    local is_edit = edit_id ~= nil
    local dialog_title
    local default_name
    local default_api_key = ""
    local default_model = ""

    if is_edit then
        -- Pre-fill from the existing provider record
        local ps = assistant.config:getProvider(edit_id)
        dialog_title = T(_("Edit %1"), koutil.tableGetValue(ps, "display_name") or edit_id)
        default_name = koutil.tableGetValue(ps, "display_name") or ""
        base_url = koutil.tableGetValue(ps, "base_url") or base_url or ""
        default_api_key = koutil.tableGetValue(ps, "api_key") or ""
        default_model = koutil.tableGetValue(ps, "model") or ""
        -- Preserve the existing additional_parameters (not exposed in dialog)
        additional_parameters = koutil.tableGetValue(ps, "additional_parameters") or {}
        -- Handler comes from the existing record, not the parameter
        handler = koutil.tableGetValue(ps, "handler") or handler
    else
        dialog_title = preset_name and T(_("Add %1"), preset_name) or T(_("Add %1 Provider"), handler)
        default_name = preset_name or ""
    end

    -- Handler-aware guidance for the Base URL field (handler is resolved from
    -- the record in edit mode, so compute it after the branch above).
    local base_url_desc = BASE_URL_DESCRIPTIONS[handler]
        or _("Base URL of the API endpoint, e.g. https://example.com/v1")

    local dialog_ref = {}  -- forward ref for enabled_func closure in buttons
    local dialog
    local dialog_buttons = {{
        {
            id = "cancel",
            text = _("Cancel"),
            callback = function() UIManager:close(dialog) end,
        },
        {
            id = "browse_models",
            text = _("Browse Models"),
            enabled_func = function()
                local d = dialog_ref[1]
                if not d then return false end
                return d:getFields()[3] ~= ""  -- enabled when API key is filled
            end,
            callback = function()
                local fields = dialog:getFields()
                local api_key = fields[3]
                local url = fields[2]
                if api_key == "" or url == "" then return end
                -- Fetch models through the provider handler's own
                -- FetchModels (api_handlers), then reuse model_picker's
                -- showPickerDialog. Each handler builds its endpoint,
                -- auth headers and post-processing itself, and runs the
                -- request behind a dismissable InfoMessage so a stalled
                -- network can be cancelled by tapping.
                ASUtils.runWhenOnlineFast(function()
                    Trapper:wrap(function()
                        local mp = require("assistant_model_picker")
                        local model_list, err = mp.fetchModels(handler, url, api_key)
                        if err == ASUtils.HANDLERCODE.CODE_CANCELLED then
                            return  -- user dismissed the InfoMessage
                        end
                        if err or not model_list or #model_list == 0 then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = err or _("No models available."),
                            })
                            return
                        end
                        mp.showPickerDialog(assistant, model_list, nil, "", 1,
                            function(model_id)
                                if dialog.input_fields[4] then
                                    dialog.input_fields[4]:setText(model_id)
                                    dialog.input_fields[4]:moveCursorToCharPos(#model_id + 1)
                                end
                            end
                        )
                    end)
                end)
            end,
        },
        {
            id = "save",
            text = _("Save"),
            is_enter_default = true,
            callback = function()
                local fields = dialog:getFields()
                local name = fields[1]
                local url = fields[2]
                local api_key = fields[3]
                local model = fields[4]
                if name == "" then name = handler end
                if url == "" then
                    UIManager:show(InfoMessage:new{ text = _("Base URL is required.") })
                    return
                end
                if api_key == "" then
                    UIManager:show(InfoMessage:new{ text = _("API key is required.") })
                    return
                end
                if is_edit then
                    Registry.updateProvider(assistant, edit_id, name, url, api_key, model)
                else
                    Registry.installProvider(assistant, handler, url, name, api_key, model, additional_parameters)
                end
                UIManager:close(dialog)
                -- Close any stale settings dialog, then open a fresh
                -- Provider Settings window so the added/edited provider
                -- is immediately visible and selectable.
                if assistant._settings_dialog then
                    UIManager:close(assistant._settings_dialog)
                    assistant._settings_dialog = nil
                end
                UIManager:scheduleIn(0.15, function() assistant:showSettings() end)
            end,
        },
    }}
    if not is_edit then
        -- Clear the fields pre-filled from the preset (Name, Base URL, Model);
        -- leaves the user-typed API Key untouched.
        table.insert(dialog_buttons[1], 2, {
            id = "clear",
            text = _("Clear"),
            callback = function()
                local fields = dialog.input_fields
                for i, index in ipairs({1, 2, 4}) do
                    if fields[index] then
                        fields[index]:setText("")
                        fields[index]:moveCursorToCharPos(1)
                    end
                end
            end,
        })
    end
    dialog = MultiInputDialog:new{
        title = dialog_title,
        fields = {
            { description = _("Provider Name — shown in menus; leave empty to use the API protocol name (e.g. \"openai\")"),
              hint = _("Display name"), text = default_name },
            { description = base_url_desc,
              hint = _("https://..."),   text = base_url },
            { description = _("API Key — enter your key, then tap Browse Models to list available models"),
              hint = _("Your API key"),  text = default_api_key },
            { description = _("Model — tap Browse Models to pick an available model"),
              hint = _("Pick one via Browse Models"), text = default_model },
        },
        buttons = dialog_buttons,
    }
    dialog_ref[1] = dialog
    UIManager:show(dialog)
end

----------------------------------------------------------------------
-- Provider menu
----------------------------------------------------------------------

--- Build the "Provider API" menu item used by the Settings dialog.
--- Returns a TouchMenu item with a sub-menu listing the preset providers.
--- Selecting an entry opens the add-provider dialog through
--- assistant:_showAddProviderDialog; the fields remain editable so users
--- can point a preset at a custom base URL.
---@param assistant table The Assistant instance
---@return table menu item spec
function Registry.getAddProviderMenuItem(assistant)
    return {
        text = _("Provider API"),
        -- Marker used by main.lua's showAddProviderMenu to locate this item
        -- in the live TouchMenu (see AGENTS.md "Provider menu paths").
        assistant_item_id = "assistant_add_provider",
        keep_menu_open = true,
        sub_item_table_func = function()
            local items = {}
            for i, preset in ipairs(PRESET_PROVIDERS) do
                table.insert(items, {
                    text = preset.name,
                    keep_menu_open = true,
                    callback = function()
                        assistant:_showAddProviderDialog(preset.name, preset.handler, preset.base_url,
                            preset.additional_parameters)
                    end,
                })
            end
            return items
        end,
    }
end

return Registry
