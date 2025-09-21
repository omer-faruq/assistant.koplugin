--[[
LanguageRankers documentation
===============================
This module centralises all ranking logic that the dictionary and other AI surfaces rely on.
It is intentionally data-driven so contributors can tweak behaviour without touching the core
Lua code. The key ideas are:

1. Feature-based scoring
   - Each context (paragraph/sentence) is scored by a set of small feature functions defined
     in FEATURE_IMPLEMENTATIONS. Examples: raw term frequency, preferred length ranges,
     descriptor word hits, proximity to the current reading position.
   - `_default_features` lists every feature. Language configs can explicitly enable/disable
     any of them via the `enabled_features` table (see assistant_language_descriptors.lua).
   - Adding a new feature only requires providing an implementation and toggling it in the
     descriptor file.

2. Language-specific descriptors
   - Per-language configuration lives in assistant_language_descriptors.lua. Each entry can
     declare word lists, regex patterns, custom scoring callbacks, and feature flags.
   - The descriptors file is purely data, so localisers can maintain language assets without
     editing logic. LanguageRankers automatically registers every descriptor on load.

3. Metadata inputs
   - `rankContexts` accepts an optional metadata table with fields such as `total_units`,
     `current_paragraph_index`, or `current_index`. Features that need this information (e.g.
     position diversity, proximity) read it to adjust scores. Callers should send whichever
     fields they can compute; missing values simply disable dependent features.

Extending the system
--------------------
* To add a new language: copy one of the descriptor tables in assistant_language_descriptors.lua,
  adjust `enabled_features`, `word_groups`, and `patterns`, and (optionally) supply a `custom`
  function for bespoke logic. The module will register it automatically when required.
* To introduce a new scoring feature: add a function to FEATURE_IMPLEMENTATIONS, set a sane
  default flag in `_default_features`, and toggle it per-language in the descriptors file.
* To call the ranker from new code: pass a language tag, a list of contexts (with `text`,
  `position`, and optional precomputed metrics), plus metadata that includes any relevant
  totals or the user's current location.

This comment intentionally avoids locale-specific strings so it can remain English reference
material for the project.
]]
local LanguageRankers = {
    _languages = {},
    _default_language = "en",
    _default_features = {
        term_frequency = true,
        preferred_length = true,
        position_diversity = true,
        descriptor_words = true,
        descriptor_patterns = true,
        dialogue = true,
        proximity = true,
        custom = true,
    },
}

local descriptors = require("assistant_language_descriptors")

local function cloneFeatureFlags(flags)
    local merged = {}
    for feature, enabled in pairs(LanguageRankers._default_features) do
        merged[feature] = enabled and true or false
    end
    if type(flags) == "table" then
        for feature, enabled in pairs(flags) do
            merged[feature] = not not enabled
        end
    end
    return merged
end

local function normalizeForMatch(text)
    local normalized = (text or ""):lower()
    normalized = normalized:gsub('\195\161', 'a')
    normalized = normalized:gsub('\195\160', 'a')
    normalized = normalized:gsub('\195\162', 'a')
    normalized = normalized:gsub('\195\164', 'a')
    normalized = normalized:gsub('\195\163', 'a')
    normalized = normalized:gsub('\195\165', 'a')
    normalized = normalized:gsub('\195\169', 'e')
    normalized = normalized:gsub('\195\168', 'e')
    normalized = normalized:gsub('\195\170', 'e')
    normalized = normalized:gsub('\195\171', 'e')
    normalized = normalized:gsub('\195\173', 'i')
    normalized = normalized:gsub('\195\172', 'i')
    normalized = normalized:gsub('\195\174', 'i')
    normalized = normalized:gsub('\195\175', 'i')
    normalized = normalized:gsub('\195\179', 'o')
    normalized = normalized:gsub('\195\178', 'o')
    normalized = normalized:gsub('\195\180', 'o')
    normalized = normalized:gsub('\195\182', 'o')
    normalized = normalized:gsub('\195\181', 'o')
    normalized = normalized:gsub('\195\186', 'u')
    normalized = normalized:gsub('\195\185', 'u')
    normalized = normalized:gsub('\195\187', 'u')
    normalized = normalized:gsub('\195\188', 'u')
    normalized = normalized:gsub('\195\177', 'n')
    normalized = normalized:gsub('\195\167', 'c')
    normalized = normalized:gsub('\195\159', 'ss')
    normalized = normalized:gsub('\197\147', 'oe')
    normalized = normalized:gsub('\197\146', 'oe')
    normalized = normalized:gsub('\195\184', 'o')
    return normalized
end

local FEATURE_IMPLEMENTATIONS = {}

FEATURE_IMPLEMENTATIONS.term_frequency = function(context)
    return (context.term_frequency or 0) * 10
end

FEATURE_IMPLEMENTATIONS.preferred_length = function(context)
    local word_count = context.word_count or 0
    if word_count >= 30 and word_count <= 150 then
        return 5
    elseif word_count >= 15 and word_count <= 200 then
        return 3
    end
    return 0
end

FEATURE_IMPLEMENTATIONS.position_diversity = function(context, metadata)
    local total_units = metadata.total_units or metadata.total_paragraphs or metadata.total_sentences or 0
    if total_units > 0 and context.position then
        local ratio = context.position / total_units
        if ratio < 0.2 then
            return 3
        elseif ratio > 0.8 then
            return 3
        end
        return 1
    end
    return 1
end

FEATURE_IMPLEMENTATIONS.dialogue = function(_, _, _, raw_text)
    if raw_text:find('"[^"]+"') then
        return 2
    end
    return 0
end

FEATURE_IMPLEMENTATIONS.descriptor_words = function(context, _, config, _, normalized_text)
    local score = 0
    if type(config.word_groups) ~= "table" then
        return score
    end
    for _, group in ipairs(config.word_groups) do
        local weight = group.weight or 1
        for _, word in ipairs(group.words or {}) do
            local pattern = "%f[%w]" .. word .. "%f[%W]"
            if normalized_text:find(pattern) then
                score = score + weight
            end
        end
    end
    return score
end

FEATURE_IMPLEMENTATIONS.descriptor_patterns = function(_, _, config, raw_text, normalized_text)
    local score = 0
    if type(config.patterns) ~= "table" then
        return score
    end
    for _, pattern_config in ipairs(config.patterns) do
        local target = pattern_config.target or "normalized"
        local haystack = target == "raw" and raw_text or normalized_text
        if haystack:find(pattern_config.pattern) then
            score = score + (pattern_config.weight or 1)
        end
    end
    return score
end

FEATURE_IMPLEMENTATIONS.custom = function(context, metadata, config)
    if type(config.custom) == "function" then
        return config.custom(context, metadata) or 0
    end
    return 0
end

FEATURE_IMPLEMENTATIONS.proximity = function(context, metadata)
    local current = metadata.current_index or metadata.current_paragraph_index
    if not current or not context.position then
        return 0
    end
    local distance = math.abs(current - context.position)
    if distance == 0 then
        return 6
    elseif distance == 1 then
        return 4
    elseif distance == 2 then
        return 3
    elseif distance <= 4 then
        return 2
    elseif distance <= 6 then
        return 1
    end
    return 0
end

local function resolveLanguage(language_code)
    if type(language_code) ~= "string" then
        return LanguageRankers._languages[LanguageRankers._default_language], LanguageRankers._default_language
    end
    local code = language_code:lower()
    if LanguageRankers._languages[code] then
        return LanguageRankers._languages[code], code
    end
    local prefix = code:match("^(%a%a)")
    if prefix and LanguageRankers._languages[prefix] then
        return LanguageRankers._languages[prefix], prefix
    end
    return LanguageRankers._languages[LanguageRankers._default_language], LanguageRankers._default_language
end

function LanguageRankers.register(language_code, config)
    if type(language_code) ~= "string" or type(config) ~= "table" then
        return
    end
    local normalized_code = language_code:lower()
    local stored = {
        word_groups = config.word_groups,
        patterns = config.patterns,
        custom = config.custom,
        enabled_features = cloneFeatureFlags(config.enabled_features),
    }
    if type(stored.custom) ~= "function" then
        stored.custom = nil
        stored.enabled_features.custom = false
    end
    if stored.word_groups == nil then
        stored.enabled_features.descriptor_words = false
    end
    if stored.patterns == nil then
        stored.enabled_features.descriptor_patterns = false
    end
    LanguageRankers._languages[normalized_code] = stored
end

function LanguageRankers.getRegisteredLanguages()
    local list = {}
    for code in pairs(LanguageRankers._languages) do
        table.insert(list, code)
    end
    table.sort(list)
    return list
end

function LanguageRankers.rankContexts(language_code, contexts, metadata)
    if type(contexts) ~= "table" then
        return {}
    end
    local config = resolveLanguage(language_code)
    if not config then
        return contexts
    end
    metadata = metadata or {}

    local features = cloneFeatureFlags(config.enabled_features)
    if not metadata.current_index and not metadata.current_paragraph_index then
        features.proximity = false
    end

    for _, context in ipairs(contexts) do
        local raw_text = context.text or ""
        local normalized_text = normalizeForMatch(raw_text)
        local score = 0
        local contributions = {
            descriptor = 0,
            term_frequency = 0,
        }
        for feature, enabled in pairs(features) do
            if enabled then
                local impl = FEATURE_IMPLEMENTATIONS[feature]
                if impl then
                    local delta = impl(context, metadata, config, raw_text, normalized_text) or 0
                    score = score + delta
                    if feature == "descriptor_words" or feature == "descriptor_patterns" then
                        contributions.descriptor = contributions.descriptor + delta
                    elseif feature == "term_frequency" then
                        contributions.term_frequency = contributions.term_frequency + delta
                    end
                end
            end
        end
        context.rank_score = score
        context.feature_contributions = contributions
    end

    table.sort(contexts, function(a, b)
        if a.rank_score == b.rank_score then
            return (a.position or 0) < (b.position or 0)
        end
        return a.rank_score > b.rank_score
    end)

    local total_contexts = #contexts
    if total_contexts > 0 then
        for index, context in ipairs(contexts) do
            context.rank_order = index
            context.rank_weight = (total_contexts - index + 1) / total_contexts
            local contributions = context.feature_contributions or {}
            context.descriptor_score = contributions.descriptor or 0
            context.term_frequency_score = contributions.term_frequency or 0
        end
    end

    return contexts
end

function LanguageRankers.resolve(language_code)
    return resolveLanguage(language_code)
end

for code, descriptor in pairs(descriptors) do
    LanguageRankers.register(code, descriptor)
end

return LanguageRankers
