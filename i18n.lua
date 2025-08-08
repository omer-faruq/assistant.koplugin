-- i18n.lua: Load locale from Lua table files (lang/en.lua, lang/vi.lua, ...)

local function get_system_lang()
    local success, CONFIGURATION = pcall(function() return require("configuration") end)
    if success and CONFIGURATION.locale ~= nil then
        return CONFIGURATION.locale
    end

    local env_vars = { "LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG" }
    for _, var in ipairs(env_vars) do
        local val = os.getenv(var)
        if val and #val > 0 then
            return val
        end
    end
    return "en"
end

-- "en_US.UTF-8"/"vi-VN"/"vi_VN" -> "en"/"vi"
local function normalize_lang(lang)
    return (lang:match("^([a-zA-Z]+)[-_]?") or "en"):lower()
end

-- Load lang.xx.lua
local function load_locale(lang_code)
    local ok, data = pcall(require, "lang." .. lang_code)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

local lang = normalize_lang(get_system_lang())
local translations = load_locale(lang) or {}
local fallback_en = load_locale("en") or {}
local function merge_fallback(primary, fallback)
    local merged = {}
    for k, v in pairs(fallback) do merged[k] = v end
    for k, v in pairs(primary) do merged[k] = v end
    return merged
end
translations = merge_fallback(translations, fallback_en)

return function(key)
    return translations[key] or key
end
