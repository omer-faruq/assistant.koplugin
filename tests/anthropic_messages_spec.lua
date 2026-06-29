package.path = "./?.lua;" .. package.path
local AM = require("api_handlers.anthropic_messages")

local function eq(got, want, msg)
  assert(got == want, (msg or "assert") .. " — expected [" .. tostring(want) .. "] got [" .. tostring(got) .. "]")
end

-- No cache flag: system is a concatenated string (back-compat), user messages preserved.
local r1 = AM.prepare({
  { role = "system", content = "A" },
  { role = "system", content = "B" },
  { role = "user",   content = "hi" },
})
eq(r1.system, "A\n\nB", "concat system")
eq(#r1.messages, 1, "one message")
eq(r1.messages[1].role, "user", "role")
eq(r1.messages[1].content, "hi", "content")

-- Cache flag present: system is an array of text blocks; only the flagged block carries cache_control.
local r2 = AM.prepare({
  { role = "system", content = "INSTR" },
  { role = "system", content = "COMP", cache = true },
  { role = "user",   content = "q" },
})
assert(type(r2.system) == "table", "system is array")
eq(r2.system[1].type, "text", "block1 type")
eq(r2.system[1].text, "INSTR", "block1 text")
assert(r2.system[1].cache_control == nil, "block1 has no cache_control")
eq(r2.system[2].text, "COMP", "block2 text")
assert(r2.system[2].cache_control ~= nil, "block2 has cache_control")
eq(r2.system[2].cache_control.type, "ephemeral", "block2 ephemeral")
eq(#r2.messages, 1, "one message (cache case)")

print("anthropic_messages_spec: OK")
