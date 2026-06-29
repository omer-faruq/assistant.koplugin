-- Encapsulates "which provider/model selection are we editing" so the same
-- settings + model-picker UI can drive either the global AI Provider or the
-- Book Companion provider. Operates only on the injected `assistant` (its
-- querier/settings/CONFIGURATION); requires NO KOReader modules, so it is
-- unit-testable with fake tables (see tests/provider_context_spec.lua).

local function getIn(t, ...)
  local node = t
  local keys = {...}
  for i = 1, #keys do
    if type(node) ~= "table" then return nil end
    node = node[keys[i]]
  end
  return node
end

-- Handler name = part of the provider key before the first "_".
-- "openai_o4mini" -> "openai"; "openrouter" -> "openrouter".
local function handlerNameFor(provider_name)
  if type(provider_name) ~= "string" then return nil end
  local pos = provider_name:find("_")
  if pos and pos > 1 then return provider_name:sub(1, pos - 1) end
  return provider_name
end

local ProviderContext = {}
ProviderContext.__index = ProviderContext

function ProviderContext.main(assistant)
  return setmetatable({
    assistant = assistant,
    settings = assistant.settings,
    is_companion = false,
    appliesToLiveQuerier = true,
  }, ProviderContext)
end

function ProviderContext.bookCompanion(assistant)
  return setmetatable({
    assistant = assistant,
    settings = assistant.settings,
    is_companion = true,
    appliesToLiveQuerier = false,
  }, ProviderContext)
end

function ProviderContext:selectedProvider()
  if self.is_companion then
    local p = self.settings:readSetting("book_companion_provider")
    if p == "" then return nil end
    return p
  end
  return self.assistant.querier.provider_name
end

function ProviderContext:isSelected(key)
  return key ~= nil and key == self:selectedProvider()
end

function ProviderContext:handlerNameFor(key)
  return handlerNameFor(key)
end

function ProviderContext:baseUrlFor(key)
  return getIn(self.assistant.CONFIGURATION, "provider_settings", key, "base_url")
end

-- Model to show "checked" in the picker for the selected provider.
function ProviderContext:selectedModel()
  local key = self:selectedProvider()
  if not key then return nil end
  if self.is_companion then
    local m = self.settings:readSetting("book_companion_model_" .. key)
    if m == "" then return nil end
    return m
  end
  return getIn(self.assistant.querier, "provider_settings", "model")
end

-- Model string to show in a provider's radio label (per provider key).
function ProviderContext:modelLabelFor(key)
  local tab = getIn(self.assistant.CONFIGURATION, "provider_settings", key) or {}
  if self.is_companion then
    local m = self.settings:readSetting("book_companion_model_" .. key)
    if m and m ~= "" then return m end
    return getIn(tab, "model")
  end
  -- main: mirror the historical inline logic from SettingsDialog:init.
  if key == self.assistant.querier.provider_name then
    return getIn(self.assistant.querier, "provider_settings", "model")
  elseif key:sub(1, 10) == "openrouter" then
    local m = self.settings:readSetting("openrouter_model_" .. key)
    if m == "" then
      m = getIn(self.assistant.querier, "provider_settings", "model")
    end
    return m
  end
  return getIn(tab, "model") or getIn(tab, "deployment_name")
end

function ProviderContext:onSelect(key)
  if self.is_companion then
    self.settings:saveSetting("book_companion_provider", key)
  else
    self.settings:saveSetting("provider", key)
  end
  self.assistant.updated = true
  if self.appliesToLiveQuerier then
    self.assistant.querier:load_model(key)
  end
end

-- Companion only: revert to "Not set" (companion prompts run on the main provider).
function ProviderContext:clearSelection()
  assert(self.is_companion, "clearSelection is companion-only")
  self.settings:delSetting("book_companion_provider")
  self.assistant.updated = true
end

function ProviderContext:saveModel(key, model_id)
  if self.is_companion then
    self.settings:saveSetting("book_companion_model_" .. key, model_id)
  else
    self.settings:saveSetting("openrouter_model_" .. key, model_id)
    self.assistant.querier.provider_settings.model = model_id
  end
  self.assistant.updated = true
end

function ProviderContext:resetModel(key)
  if self.is_companion then
    self.settings:delSetting("book_companion_model_" .. key)
  else
    self.settings:delSetting("openrouter_model_" .. key)
    self.assistant.querier.provider_settings.model =
      getIn(self.assistant.CONFIGURATION, "provider_settings", key, "model")
  end
  self.assistant.updated = true
end

-- Pure: (provider, model) to run a prompt on, or (nil, nil) for "no override"
-- (run on the current/main provider). Companion prompts follow the persisted
-- Book Companion selection; all others keep their own `provider` field.
function ProviderContext.resolveForPrompt(settings, prompt_config, configuration)
  if prompt_config and prompt_config.use_companion then
    local p = settings:readSetting("book_companion_provider")
    if not p or p == "" then return nil, nil end
    local m = settings:readSetting("book_companion_model_" .. p)
    if not m or m == "" then
      -- No companion model chosen: use the provider's config default so the
      -- companion stays independent of the main provider's saved OpenRouter model.
      m = getIn(configuration, "provider_settings", p, "model")
    end
    return p, m
  end
  local p = prompt_config and prompt_config.provider or nil
  return p, nil
end

return ProviderContext
