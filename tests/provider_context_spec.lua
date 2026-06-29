package.path = "./?.lua;" .. package.path
local PC = require("assistant_provider_context")

local function eq(got, want, msg)
  assert(got == want, (msg or "assert") .. " — expected [" .. tostring(want) .. "] got [" .. tostring(got) .. "]")
end

local function fakeSettings(init)
  local store = {}
  for k, v in pairs(init or {}) do store[k] = v end
  return {
    store = store,
    readSetting = function(self, k) return self.store[k] end,
    saveSetting = function(self, k, v) self.store[k] = v end,
    delSetting = function(self, k) self.store[k] = nil end,
  }
end

local function fakeAssistant(opts)
  opts = opts or {}
  local settings = opts.settings or fakeSettings(opts.init)
  local load_calls = {}
  return {
    settings = settings,
    CONFIGURATION = opts.CONFIGURATION or { provider_settings = {} },
    querier = {
      provider_name = opts.provider_name,
      provider_settings = opts.provider_settings or {},
      load_model = function(self, name) table.insert(load_calls, name); self.provider_name = name end,
    },
    load_calls = load_calls,
    updated = nil,
  }
end

-- 1. Companion: nothing selected by default.
local a = fakeAssistant()
local cc = PC.bookCompanion(a)
eq(cc:selectedProvider(), nil, "companion default provider nil")
eq(cc.is_companion, true, "is_companion true")
eq(cc.appliesToLiveQuerier, false, "companion does not touch live querier")

-- 2. Companion onSelect persists, does NOT call load_model.
cc:onSelect("openrouter")
eq(a.settings.store["book_companion_provider"], "openrouter", "companion provider persisted")
eq(#a.load_calls, 0, "companion onSelect must not load_model")
eq(a.updated, true, "updated flag set")
eq(cc:selectedProvider(), "openrouter", "selectedProvider reflects persisted")

-- 3. Companion saveModel uses per-provider key; switching providers has no stale carry-over.
cc:saveModel("openrouter", "x-ai/grok:free")
eq(a.settings.store["book_companion_model_openrouter"], "x-ai/grok:free", "model persisted per provider")
eq(cc:selectedModel(), "x-ai/grok:free", "selectedModel for current provider")
cc:onSelect("anthropic_sonnet")
eq(cc:selectedModel(), nil, "no stale model after switching providers")

-- 4. clearSelection reverts to nil.
cc:clearSelection()
eq(a.settings.store["book_companion_provider"], nil, "selection cleared")
eq(cc:selectedProvider(), nil, "selectedProvider nil after clear")

-- 5. resolveForPrompt.
local s = fakeSettings({ book_companion_provider = "openrouter", book_companion_model_openrouter = "m1" })
local p, m = PC.resolveForPrompt(s, { use_companion = true })
eq(p, "openrouter", "resolve companion provider"); eq(m, "m1", "resolve companion model")
local s2 = fakeSettings({})
p, m = PC.resolveForPrompt(s2, { use_companion = true })
eq(p, nil, "resolve nil when unset"); eq(m, nil, "resolve nil model when unset")
p, m = PC.resolveForPrompt(s2, { provider = "openai_gpt" })
eq(p, "openai_gpt", "non-companion keeps own provider"); eq(m, nil, "non-companion no model")

-- 6. Main onSelect writes `provider` and loads the model live.
local a2 = fakeAssistant({ provider_name = "haiku" })
local mc = PC.main(a2)
eq(mc.is_companion, false, "main not companion")
eq(mc:selectedProvider(), "haiku", "main selectedProvider from querier")
mc:onSelect("openrouter")
eq(a2.settings.store["provider"], "openrouter", "main provider persisted")
eq(a2.load_calls[1], "openrouter", "main onSelect loads model live")

-- 7. Main saveModel writes openrouter_model_<key> and updates live model.
mc:saveModel("openrouter", "modelZ")
eq(a2.settings.store["openrouter_model_openrouter"], "modelZ", "main model key")
eq(a2.querier.provider_settings.model, "modelZ", "main live model updated")

-- 8. handlerNameFor derives prefix.
eq(mc:handlerNameFor("openai_gpt4"), "openai", "handler prefix")
eq(mc:handlerNameFor("openrouter"), "openrouter", "handler no underscore")

-- 9. clearSelection is companion-only.
local mc_err = PC.main(fakeAssistant({ provider_name = "haiku" }))
local guard_ok = pcall(function() mc_err:clearSelection() end)
eq(guard_ok, false, "main clearSelection must error")

-- 10. resetModel companion path deletes book_companion_model_<provider>.
local ra = fakeAssistant({ init = { book_companion_provider = "openrouter", book_companion_model_openrouter = "m" } })
local rc = PC.bookCompanion(ra)
rc:resetModel("openrouter")
eq(ra.settings.store["book_companion_model_openrouter"], nil, "companion resetModel deletes per-provider key")

-- 11. resetModel main path deletes openrouter_model_<provider> and reverts live model to config default.
local ra2 = fakeAssistant({
  provider_name = "openrouter",
  provider_settings = { model = "override" },
  init = { openrouter_model_openrouter = "override" },
  CONFIGURATION = { provider_settings = { openrouter = { model = "config-default" } } },
})
local rc2 = PC.main(ra2)
rc2:resetModel("openrouter")
eq(ra2.settings.store["openrouter_model_openrouter"], nil, "main resetModel deletes model key")
eq(ra2.querier.provider_settings.model, "config-default", "main resetModel reverts live model to config")

-- 12. isSelected, baseUrlFor, and modelLabelFor basic checks.
local la = fakeAssistant({
  provider_name = "openrouter",
  provider_settings = { model = "live-model" },
  CONFIGURATION = { provider_settings = { openrouter = { base_url = "https://x/chat/completions", model = "cfg" } } },
})
local lc = PC.main(la)
eq(lc:isSelected("openrouter"), true, "isSelected true for current")
eq(lc:isSelected("other"), false, "isSelected false for other")
eq(lc:baseUrlFor("openrouter"), "https://x/chat/completions", "baseUrlFor from CONFIGURATION")
eq(lc:modelLabelFor("openrouter"), "live-model", "modelLabelFor current provider uses live model")

-- 13. resolveForPrompt with nil prompt.
do
  local rp, rm = PC.resolveForPrompt(fakeSettings({}), nil)
  eq(rp, nil, "resolveForPrompt nil prompt -> nil provider")
  eq(rm, nil, "resolveForPrompt nil prompt -> nil model")
end

-- 14. resolveForPrompt: companion provider set, NO companion model -> falls back to CONFIGURATION default.
do
  local s = fakeSettings({ book_companion_provider = "openrouter" })
  local cfg = { provider_settings = { openrouter = { model = "cfg-default" } } }
  local rp, rm = PC.resolveForPrompt(s, { use_companion = true }, cfg)
  eq(rp, "openrouter", "fallback: provider returned")
  eq(rm, "cfg-default", "fallback: config-default model used when no companion model")
end
-- resolveForPrompt: companion model set -> wins over CONFIGURATION default.
do
  local s = fakeSettings({ book_companion_provider = "openrouter", book_companion_model_openrouter = "chosen" })
  local cfg = { provider_settings = { openrouter = { model = "cfg-default" } } }
  local rp, rm = PC.resolveForPrompt(s, { use_companion = true }, cfg)
  eq(rm, "chosen", "explicit companion model wins over config default")
end
-- resolveForPrompt: companion provider set, no model, no config default -> nil model.
do
  local s = fakeSettings({ book_companion_provider = "anthropic_sonnet" })
  local rp, rm = PC.resolveForPrompt(s, { use_companion = true }, { provider_settings = {} })
  eq(rp, "anthropic_sonnet", "provider returned")
  eq(rm, nil, "nil model when neither companion model nor config default present")
end

-- 15. modelLabelFor: a non-selected openrouter provider with no saved model -> nil (blank label), not the live model.
do
  local la = fakeAssistant({
    provider_name = "openrouter_a",
    provider_settings = { model = "live-a" },
    CONFIGURATION = { provider_settings = { openrouter_b = { model = "cfg-b" } } },
  })
  local lc = PC.main(la)
  -- openrouter_b is NOT the current provider and has no openrouter_model_openrouter_b saved.
  eq(lc:modelLabelFor("openrouter_b"), nil, "unset openrouter model label is blank, not live model")
end

print("provider_context_spec: OK")
