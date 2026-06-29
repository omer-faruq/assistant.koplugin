package.path = "./?.lua;" .. package.path
local PO = require("assistant_provider_override")

local function eq(got, want, msg)
  assert(got == want, (msg or "assert") .. " — expected [" .. tostring(want) .. "] got [" .. tostring(got) .. "]")
end

-- Switch during run, restore after (different provider).
local calls = {}
local q = { provider_name = "haiku", provider_settings = { model = "haiku-model" } }
function q:load_model(name)
  table.insert(calls, name); self.provider_name = name
  self.provider_settings = { model = name .. "-model" }  -- real load_model rebuilds settings
  return true
end
local ans, err = PO.runWithProvider(q, "sonnet", nil, function()
  eq(q.provider_name, "sonnet", "switched during run")
  return "ANS", nil
end)
eq(ans, "ANS", "forwarded answer"); eq(err, nil, "forwarded nil err")
eq(q.provider_name, "haiku", "restored after run")

-- Model override applied during run, then restored (different provider).
local q2 = { provider_name = "haiku", provider_settings = { model = "haiku-model" } }
function q2:load_model(name)
  self.provider_name = name; self.provider_settings = { model = name .. "-model" }; return true
end
PO.runWithProvider(q2, "sonnet", "claude-sonnet-4-6", function()
  eq(q2.provider_name, "sonnet", "switched")
  eq(q2.provider_settings.model, "claude-sonnet-4-6", "model overridden during run")
  return "x"
end)
eq(q2.provider_name, "haiku", "provider restored")
eq(q2.provider_settings.model, "haiku-model", "model restored after different-provider override")

-- Model override on the SAME provider must not leak (load_model early-returns).
local q3 = { provider_name = "openrouter", provider_settings = { model = "default-model" } }
function q3:load_model(name)
  -- same provider already active: early return, does NOT reset model.
  if name == self.provider_name then return true end
  self.provider_name = name; self.provider_settings = { model = name .. "-model" }; return true
end
PO.runWithProvider(q3, "openrouter", "free/model:free", function()
  eq(q3.provider_settings.model, "free/model:free", "same-provider model overridden during run")
  return "x"
end)
eq(q3.provider_name, "openrouter", "provider unchanged")
eq(q3.provider_settings.model, "default-model", "same-provider model restored (no leak)")

-- Nil provider: pass-through, no load_model.
local q4calls = {}
local q4 = { provider_name = "x", provider_settings = {} }
function q4:load_model(n) table.insert(q4calls, n) end
local a, b = PO.runWithProvider(q4, nil, nil, function() return 1, 2 end)
eq(a, 1, "passthrough a"); eq(b, 2, "passthrough b"); eq(#q4calls, 0, "no load on nil provider")

-- Error inside run_fn is re-raised; provider still restored.
local q5 = { provider_name = "haiku", provider_settings = { model = "m" } }
function q5:load_model(name) self.provider_name = name; self.provider_settings = { model = "m2" } end
local ok = pcall(function()
  PO.runWithProvider(q5, "sonnet", "z", function() error("boom") end)
end)
eq(ok, false, "error propagated")
eq(q5.provider_name, "haiku", "provider restored after error")

-- Unconfigured override (load_model leaves provider unchanged): no override applied, run on current.
local q6 = { provider_name = "haiku", provider_settings = { model = "keep" } }
function q6:load_model(name) error("unconfigured") end  -- swallowed by pcall in runWithProvider
local ans6 = PO.runWithProvider(q6, "broken", "should-not-apply", function()
  eq(q6.provider_name, "haiku", "stayed on current provider")
  eq(q6.provider_settings.model, "keep", "model not overridden when load failed")
  return "OK6"
end)
eq(ans6, "OK6", "ran on current provider")
eq(q6.provider_settings.model, "keep", "model untouched after unconfigured override")

print("provider_override_spec: OK")
