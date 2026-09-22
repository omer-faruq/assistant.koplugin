--- Slim shared core: metatable attrs and JSON default.
-- Network, text and document helpers live in assistant_net_utils,
-- assistant_text_utils and assistant_doc_utils.
local json = require("rapidjson")
local M = {}

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
