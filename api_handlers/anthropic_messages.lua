-- Pure transform from the plugin's message_history into Anthropic's
-- { messages, system } request shape. LuaJIT-compatible, no external deps.
--
-- Back-compat: when no system message carries `cache = true`, `system` is the
-- newline-joined string the handler has always sent. When any system message is
-- flagged, `system` becomes an array of text blocks and flagged blocks receive
-- cache_control = { type = "ephemeral" } for Anthropic prompt caching.
local M = {}

function M.prepare(message_history)
  local system_msgs = {}
  local messages = {}
  local has_cache = false

  for _, msg in ipairs(message_history) do
    if msg.role == "system" then
      table.insert(system_msgs, { text = msg.content, cache = msg.cache == true })
      if msg.cache == true then
        has_cache = true
      end
    else
      table.insert(messages, { role = msg.role, content = msg.content })
    end
  end

  local system
  if has_cache then
    system = {}
    for _, sm in ipairs(system_msgs) do
      local block = { type = "text", text = sm.text }
      if sm.cache then
        block.cache_control = { type = "ephemeral" }
      end
      table.insert(system, block)
    end
  else
    local parts = {}
    for _, sm in ipairs(system_msgs) do
      table.insert(parts, sm.text)
    end
    system = table.concat(parts, "\n\n")
  end

  return { messages = messages, system = system }
end

return M
