-- Search tool catalog: the single source of truth for the web-search modes
-- this plugin offers.
--
-- It owns the values the "use_websearch" setting may hold and nothing else:
--   - the "none" / "builtin" sentinels
--   - the fixed external tool keys, their required credential field ("needs")
--     and their display names
--   - the menu order of every selectable mode
--
-- It is deliberately UI-free (it requires nothing at all) so that pure-logic
-- consumers - notably assistant_prompts.lua, which is loaded early by the
-- menu and the dialogs - can ask "is this setting a recognized enabled mode?"
-- without pulling in a dialog module.
--
-- Persistence of the credentials themselves lives in assistant_search_registry;
-- the API clients live in assistant_exttools.

local SearchTools = {}

--- Sentinel: web search off. This is also the default of the setting.
SearchTools.NONE = "none"

--- Sentinel: the provider's own built-in search tool (no external credential).
SearchTools.BUILTIN = "builtin"

--- Fixed external search tool definitions.
--- `needs` is the one credential field the tool uses and the only one the
--- registry is allowed to persist for it.
SearchTools.DEFINITIONS = {
    serpapi    = { needs = "api_key",  display_name = "SerpAPI" },
    tavilyapi  = { needs = "api_key",  display_name = "Tavily" },
    exaapi     = { needs = "api_key",  display_name = "Exa.ai" },
    searxngapi = { needs = "base_url", display_name = "SearXNG" },
}

--- External tool keys, in menu order.
SearchTools.TOOL_KEYS = { "serpapi", "tavilyapi", "exaapi", "searxngapi" }

--- Every value the "use_websearch" setting may hold, in menu order:
--- the two sentinels followed by the external tool keys.
SearchTools.MENU_ORDER = { SearchTools.NONE, SearchTools.BUILTIN }

for idx, tool_key in ipairs(SearchTools.TOOL_KEYS) do
    SearchTools.MENU_ORDER[#SearchTools.MENU_ORDER + 1] = tool_key
end

--- Look up a fixed external tool definition.
---@param key string|nil The external tool key
---@return table|nil def The `{ needs, display_name }` entry, or nil
function SearchTools.getDefinition(key)
    if type(key) ~= "string" then
        return nil
    end
    return SearchTools.DEFINITIONS[key]
end

--- Check whether a value is one of the fixed external tool keys.
---@param key string|nil The candidate tool key
---@return boolean
function SearchTools.isExternalTool(key)
    return SearchTools.getDefinition(key) ~= nil
end

--- Check whether a "use_websearch" setting value enables web search.
--- Only the "builtin" sentinel and a recognized external tool key do; every
--- other value - nil, "", "none", a typo, a stale key - fails closed.
---@param value string|nil The raw setting value
---@return boolean
function SearchTools.isEnabledMode(value)
    if type(value) ~= "string" then
        return false
    end
    return value == SearchTools.BUILTIN or SearchTools.isExternalTool(value)
end

return SearchTools
