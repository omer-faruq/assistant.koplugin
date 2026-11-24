-- Prompt Registry for UI-added custom prompts stored in settings as JSON.
--
-- UI prompts live in settings under "ui_prompts" and are merged with the
-- prompts of configuration.lua into CONFIGURATION.features.prompts, so every
-- consumer of `config:getFeature("prompts")` treats them alike.
--
-- Each UI prompt has a stable ID ("custom_<n>") and the fields:
--   text, user_prompt, use_book_context, show_on_main_popup, order
-- File prompts win on an ID collision.

local json = require("rapidjson")
local koutil = require("util")
local logger = require("logger")
local _ = require("core/gettext")

local PromptRegistry = {}

local SCHEMA_VERSION = 1

-- Built-in prompts use orders up to 110.
local BASE_ORDER = 200

local HIGHLIGHT_PLACEHOLDER = "{highlight}"

local function emptyData()
    return { prompts = {}, _next_id = 1 }
end

--- Load UI prompts from settings.
--- Returns { prompts = { [id] = record }, _next_id = n }; a missing or
--- corrupt entry yields a fresh empty structure.
---@param settings table LuaSettings instance
---@return table
function PromptRegistry.load(settings)
    local raw = settings:readSetting("ui_prompts")
    if not raw then
        return emptyData()
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        logger.warn("PromptRegistry: ui_prompts JSON corrupt, starting fresh")
        return emptyData()
    end
    if decoded.schema_version ~= SCHEMA_VERSION then
        logger.warn("PromptRegistry: schema version mismatch, starting fresh")
        return emptyData()
    end
    if type(decoded.prompts) ~= "table" then
        decoded.prompts = {}
    end
    if type(decoded._next_id) ~= "number" then
        decoded._next_id = 1
    end
    return decoded
end

--- Persist UI prompts to settings.
---@param settings table LuaSettings instance
---@param data table structure from load()
---@return boolean ok
function PromptRegistry.save(settings, data)
    local ok, encoded = pcall(json.encode, {
        schema_version = SCHEMA_VERSION,
        prompts = data.prompts or {},
        _next_id = data._next_id or 1,
    })
    if not ok then
        logger.warn("PromptRegistry: failed to encode ui_prompts JSON")
        return false
    end
    settings:saveSetting("ui_prompts", encoded)
    return true
end

--- Merge file prompts with UI prompts into the effective prompts table.
--- Returns a new table; neither input is modified.
---@param file_prompts table|nil features.prompts from configuration.lua
---@param ui_data table structure from load()
---@return table merged
function PromptRegistry.merge(file_prompts, ui_data)
    local merged = {}
    for id, record in pairs(file_prompts or {}) do
        merged[id] = record
    end
    for id, record in pairs(ui_data.prompts or {}) do
        if type(record) == "table" then
            if merged[id] then
                logger.warn("PromptRegistry: UI prompt id collision, skipping: ", id)
            else
                local copy = {}
                koutil.tableMerge(copy, record)
                copy.source = "ui"
                merged[id] = copy
            end
        end
    end
    return merged
end

--- Normalize and validate a prompt record in place. A user prompt without
--- {highlight} gets the selected text appended so it always reaches the model.
---@param record table fields to validate
---@return boolean ok
---@return string|nil err
function PromptRegistry.validate(record)
    if type(record) ~= "table" then
        return false, _("Prompt record must be a table.")
    end
    if type(record.text) == "string" then
        record.text = koutil.trim(record.text)
    end
    if type(record.text) ~= "string" or record.text == "" then
        return false, _("Prompt name is required.")
    end
    if type(record.user_prompt) == "string" then
        record.user_prompt = koutil.trim(record.user_prompt)
    end
    if type(record.user_prompt) ~= "string" or record.user_prompt == "" then
        return false, _("Prompt text is required.")
    end
    if not record.user_prompt:find(HIGHLIGHT_PLACEHOLDER, 1, true) then
        record.user_prompt = record.user_prompt .. "\n\n---\n" .. HIGHLIGHT_PLACEHOLDER
    end
    return true
end

--- Add a UI prompt with a generated stable ID.
---@param data table structure from load()
---@param fields table { text, user_prompt, use_book_context? }
---@return string|nil id
---@return string|nil err
function PromptRegistry.add(data, fields)
    local ok, err = PromptRegistry.validate(fields)
    if not ok then
        return nil, err
    end

    local n = data._next_id
    local id = "custom_" .. tostring(n)
    data._next_id = n + 1
    data.prompts[id] = {
        text = fields.text,
        user_prompt = fields.user_prompt,
        use_book_context = fields.use_book_context ~= false,
        show_on_main_popup = true,
        order = BASE_ORDER + n,
    }
    return id
end

--- Replace the editable fields of a stored prompt. The stored record is
--- untouched when validation fails.
---@param data table structure from load()
---@param id string prompt ID
---@param fields table { text, user_prompt, use_book_context? }
---@return boolean ok
---@return string|nil err
function PromptRegistry.update(data, id, fields)
    local record = data.prompts[id]
    if not record then
        return false, _("Prompt not found.")
    end
    local candidate = {
        text = fields.text,
        user_prompt = fields.user_prompt,
    }
    local ok, err = PromptRegistry.validate(candidate)
    if not ok then
        return false, err
    end
    record.text = candidate.text
    record.user_prompt = candidate.user_prompt
    if fields.use_book_context ~= nil then
        record.use_book_context = fields.use_book_context and true or false
    end
    return true
end

--- Delete a UI prompt.
---@param data table structure from load()
---@param id string prompt ID
---@return boolean ok
---@return string|nil err
function PromptRegistry.delete(data, id)
    if not data.prompts[id] then
        return false, _("Prompt not found.")
    end
    data.prompts[id] = nil
    return true
end

--- Whether a merged prompt record can be edited or deleted from the UI.
---@param prompt table|nil merged features.prompts entry
---@return boolean
function PromptRegistry.is_editable(prompt)
    return prompt ~= nil and prompt.source == "ui"
end

--- Stored prompt IDs, oldest first.
---@param data table structure from load()
---@return string[]
function PromptRegistry.sortedIds(data)
    local ids = {}
    for id in pairs(data.prompts) do
        ids[#ids + 1] = id
    end
    table.sort(ids, function(a, b)
        return (tonumber(a:match("(%d+)$")) or 0) < (tonumber(b:match("(%d+)$")) or 0)
    end)
    return ids
end

--- Add a prompt, persist it and refresh the effective config.
---@param assistant table The Assistant instance
---@param name string button title
---@param user_prompt string prompt text
---@return string|nil id
---@return string|nil err
function PromptRegistry.installPrompt(assistant, name, user_prompt)
    local data = assistant._ui_prompt_data
    local id, err = PromptRegistry.add(data, { text = name, user_prompt = user_prompt })
    if not id then
        return nil, err
    end
    PromptRegistry.save(assistant.settings, data)
    assistant.config:setPrompt(id, data.prompts[id])
    return id
end

--- Edit a prompt, persist it and refresh the effective config.
---@param assistant table The Assistant instance
---@param id string prompt ID
---@param fields table { text, user_prompt, use_book_context? }
---@return boolean ok
---@return string|nil err
function PromptRegistry.updatePrompt(assistant, id, fields)
    local data = assistant._ui_prompt_data
    local ok, err = PromptRegistry.update(data, id, fields)
    if not ok then
        return false, err
    end
    PromptRegistry.save(assistant.settings, data)
    assistant.config:setPrompt(id, data.prompts[id])
    return true
end

--- Delete a prompt, persist it and refresh the effective config.
---@param assistant table The Assistant instance
---@param id string prompt ID
---@return boolean ok
---@return string|nil err
function PromptRegistry.deletePrompt(assistant, id)
    local data = assistant._ui_prompt_data
    local ok, err = PromptRegistry.delete(data, id)
    if not ok then
        return false, err
    end
    PromptRegistry.save(assistant.settings, data)
    assistant.config:deletePrompt(id)
    return true
end

return PromptRegistry
