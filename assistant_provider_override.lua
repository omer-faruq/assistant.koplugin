-- Temporarily switch the querier to another provider for one call, then restore.
-- LuaJIT-compatible (no table.pack); forwards up to two return values, which is
-- what Querier:query returns (answer, err).
local M = {}

function M.runWithProvider(querier, provider_name, model_override, run_fn)
  if not provider_name then
    return run_fn()
  end

  local saved = querier.provider_name
  local saved_model = querier.provider_settings and querier.provider_settings.model
  -- If the target provider is unconfigured, load_model may error; swallow it and
  -- run on whatever provider is currently active rather than aborting the query.
  pcall(function() querier:load_model(provider_name) end)

  -- Only apply the model override if the target provider is actually active now
  -- (load succeeded, or it was already the current provider). If load failed we
  -- stay on the current provider and must NOT graft a foreign model onto it.
  local switched = (querier.provider_name == provider_name)
  if switched and model_override and querier.provider_settings then
    querier.provider_settings.model = model_override
  end

  local ok, a, b = pcall(run_fn)

  if saved ~= nil and saved ~= querier.provider_name then
    -- Provider changed: reloading the saved provider rebuilds its own model too.
    pcall(function() querier:load_model(saved) end)
  elseif switched and model_override and querier.provider_settings then
    -- Same provider, only the model was overridden: restore it explicitly.
    querier.provider_settings.model = saved_model
  end

  if not ok then
    -- Level 0: re-raise the value exactly as pcall captured it (no extra location prefix).
    error(a, 0)
  end
  return a, b
end

return M
