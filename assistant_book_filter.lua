-- Decide whether a prompt's `book_filter` matches the current book's properties.
-- Pure module: no KOReader dependencies, LuaJIT-compatible.
-- A filter supports `title_contains` and `author_contains` (case-insensitive
-- substring). All present conditions must match (AND). A nil/empty filter matches.
local M = {}

local function contains(haystack, needle)
  if not needle or needle == "" then
    return true
  end
  if type(haystack) ~= "string" then
    return false
  end
  return string.find(haystack:lower(), needle:lower(), 1, true) ~= nil
end

function M.matches(filter, props)
  if not filter then
    return true
  end
  props = props or {}
  if not contains(props.title, filter.title_contains) then
    return false
  end
  if not contains(props.authors, filter.author_contains) then
    return false
  end
  return true
end

return M
