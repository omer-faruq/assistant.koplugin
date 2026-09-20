--- Slim shared core: plugin dir, metatable attrs, JSON default.
-- Network, text and document helpers live in assistant_net_utils,
-- assistant_text_utils and assistant_doc_utils.
local json = require("rapidjson")
local M = {}

-- Standalone plugin-dir resolver. assistant_gettext must NOT require this
-- module (it resolves its own l10n dir from its own source location), so the
-- dependency stays one-way: utils -> gettext.
local lfs_plugin_dir = require("libs/libkoreader-lfs")

-- PLUGIN_DIR is lazily delegated to assistant_gettext.plugin_dir (the single
-- source of truth). Tests / direct requires without gettext fall back to the
-- self-computation below.
local _cached_dir

-- Compute the plugin dir (fallback used only when main.lua has not yet set
-- M.PLUGIN_DIR, e.g. in the test suite or a direct require).
local function computePluginDir()
  local function fromSelf()
    local info = debug.getinfo(2, "S")
    local src = info and info.source and info.source:match("^@(.+)$") or ""
    local dir = src:match("(.*/)") or ""
    dir = dir:gsub("/$", "")
    if dir ~= "" and lfs_plugin_dir.attributes(dir, "mode") == "directory" then return dir end
    info = debug.getinfo(1, "S")
    src = info and info.source and info.source:match("^@(.+)$") or ""
    dir = src:match("(.*/)") or ""
    dir = dir:gsub("/$", "")
    if dir ~= "" and lfs_plugin_dir.attributes(dir, "mode") == "directory" then return dir end
    return nil
  end
  local d = fromSelf()
  if d then
    if lfs_plugin_dir.attributes(d .. "/l10n", "mode") == "directory" or lfs_plugin_dir.attributes(d .. "/lib", "mode") == "directory" then return d end
    return d
  end
  local ok, DataStorage = pcall(require, "datastorage")
  if ok and DataStorage then
    local p = DataStorage:getDataDir() .. "/plugins/assistant.koplugin"
    if lfs_plugin_dir.attributes(p, "mode") == "directory" then return p end
    return p
  end
    if lfs_plugin_dir.attributes("plugins/assistant.koplugin", "mode") == "directory" then return "plugins/assistant.koplugin" end
  return "."
end

-- Backward-compatible accessor: prefer assistant_gettext.plugin_dir (single
-- source), then the cached self-computation for tests without gettext.
function M.getPluginDir()
  if M.PLUGIN_DIR and M.PLUGIN_DIR ~= "" then return M.PLUGIN_DIR end
  if _cached_dir then return _cached_dir end
  -- Try gettext first (single source of truth).
  local ok, gt = pcall(require, "assistant_gettext")
  if ok and gt and gt.plugin_dir and gt.plugin_dir ~= "" then
    _cached_dir = gt.plugin_dir
    return _cached_dir
  end
  -- Fallback: self-compute (tests / standalone luajit without gettext).
  _cached_dir = computePluginDir()
  return _cached_dir
end

-- Initialize PLUGIN_DIR at file load so tests without main still have it.
-- getPluginDir() now delegates to assistant_gettext.plugin_dir when available.
if not M.PLUGIN_DIR then
  M.PLUGIN_DIR = M.getPluginDir()
end

-- gettext require placed after PLUGIN_DIR is set so any consumer that reads
-- utils.PLUGIN_DIR during gettext's load sees a usable value.
local _ = require("assistant_gettext")

--- Sets a metadata attribute on an object
--- The attribute is stored in the object's metatable under the __attr field
--- This keeps metadata separate from the object's own data fields
---
--- @param obj table The object to attach metadata to
--- @param key string The attribute key name
--- @param value any The attribute value (can be any Lua type)
--- @throws Error if obj is not a table
function M.set_attr(obj, key, value)
    -- Validate that we're working with a table
    if type(obj) ~= "table" then
        error("obj must be a table")
    end

    -- Get or create the metatable
    local mt = getmetatable(obj)
    if not mt then
        mt = {}
        setmetatable(obj, mt)
    end

    -- Get or create the __attr sub-table within the metatable
    if not mt.__attr then
        mt.__attr = {}
    end

    -- Store the key-value pair in the __attr table
    mt.__attr[key] = value
end

--- Retrieves a metadata attribute from an object
--- Looks up the attribute in the object's metatable __attr field
--- Returns nil if the object has no metatable, no __attr field, or the key doesn't exist
---
--- @param obj table The object to query
--- @param key string The attribute key name
--- @param default any Optional default value to return if attribute doesn't exist
--- @return any The attribute value, or the default value if provided, or nil
function M.get_attr(obj, key, default)
    -- Safety check: ensure we're working with a table
    if type(obj) ~= "table" then
        return default
    end

    -- Attempt to retrieve the metatable and __attr field
    local mt = getmetatable(obj)
    if mt and mt.__attr then
        local value = mt.__attr[key]
        -- Explicitly check for nil to distinguish between nil and false
        if value ~= nil then
            return value
        end
    end

    -- Return default if attribute doesn't exist or is nil
    return default
end

-- default_value for rapidjson decoded object
function M.json_default(value, default_value)
    if value == nil or value == json.null then
        return default_value
    end
    return value
end

return M
