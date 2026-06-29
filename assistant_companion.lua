-- Loads a per-book reference companion sidecar file.
-- Pure module: no KOReader dependencies, LuaJIT-compatible.
-- Exports: getCompanionPath, loadCompanion
local M = {}

-- Derive the sidecar path: same directory, filename stem + ".companion.md".
-- "/Books/Middlemarch.epub" -> "/Books/Middlemarch.companion.md"
function M.getCompanionPath(book_filepath)
  if not book_filepath or book_filepath == "" then
    return nil
  end
  -- Strip a trailing extension only (a final dot followed by non-separator chars).
  local stem = book_filepath:gsub("%.[^./\\]+$", "")
  return stem .. ".companion.md"
end

-- Read the companion sidecar for a book. Returns its contents, or nil if the
-- file is missing, unreadable, or empty. Never throws.
function M.loadCompanion(book_filepath)
  local path = M.getCompanionPath(book_filepath)
  if not path then
    return nil
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  -- read("*a") on a valid handle always returns a string; treat empty as absent.
  if content == "" then
    return nil
  end
  return content
end

-- Cheap existence check: true if the book has a non-empty companion sidecar.
-- Mirrors loadCompanion's "empty == absent" rule without reading the whole file.
-- Used to decide whether to surface companion prompts for the current book.
function M.hasCompanion(book_filepath)
  local path = M.getCompanionPath(book_filepath)
  if not path then
    return false
  end
  local f = io.open(path, "r")
  if not f then
    return false
  end
  local first = f:read(1)
  f:close()
  return first ~= nil
end

return M
