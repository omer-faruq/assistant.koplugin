-- test_prompts.lua
-- Tests for assistant_prompts.lua:
--   * built-in prompt flag defaults (use_book_context)
--   * deep-merge override semantics via M.getMergedPrompts
--   * the two global feature switches (isSuggestionsEnabled / isWebSearchEnabled)
--   * the AI Dictionary output sections, presets and prompt builder
-- Chapter and page-text extraction are covered by test_chapter_context.lua.
local helper = require("test.helper")
local assert = helper.assert
local M = require("assistant_prompts")
local SearchTools = require("assistant_search_tools")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Fake LuaSettings returning a fixed value for one key.
local function settingsWith(value, key)
    return {
        readSetting = function(_, k, def)
            if k == key then return value end
            return def
        end,
    }
end

local tests = {

    -- =========================================================================
    -- 1. Built-in flag defaults
    -- =========================================================================

    test("builtin_prompts: all 13 keys exist", function()
        local keys = {
            "term_xray", "dictionary", "quick_note", "vocabulary", "grammar",
            "translate", "summarize", "simplify", "key_points", "ELI5",
            "explain", "historical_context", "wikipedia",
        }
        for idx, key in ipairs(keys) do
            -- `idx` rather than `_`: the gettext guard forbids a discarded `_`.
            assert.notNil(M.builtin_prompts[key], "builtin_prompts." .. key .. " should exist")
        end
    end),

    test("builtin_prompts: use_book_context == true on the 5 expected keys", function()
        local true_keys = { "summarize", "key_points", "ELI5", "explain", "historical_context" }
        for idx, key in ipairs(true_keys) do
            assert.equal(M.builtin_prompts[key].use_book_context, true,
                key .. ".use_book_context should be true")
        end
    end),

    test("builtin_prompts: use_book_context == false on the other 8 keys", function()
        local false_keys = {
            "term_xray", "dictionary", "quick_note", "vocabulary", "grammar",
            "translate", "simplify", "wikipedia",
        }
        for idx, key in ipairs(false_keys) do
            assert.equal(M.builtin_prompts[key].use_book_context, false,
                key .. ".use_book_context should be false")
        end
    end),

    test("default system prompt: describes KOReader context boundaries", function()
        local prompt = M.assistant_prompts.default.system_prompt
        assert.matches(prompt, "KOReader")
        assert.matches(prompt, "If no book context")
        assert.matches(prompt, "system state")
        assert.matches(prompt, "Do not claim to have inspected or changed the user's")
        assert.notMatches(prompt, "You are a helpful assistant")
    end),

    test("KOReader version: system prompt carries the reported runtime revision", function()
        local version = M.getKoreaderVersion()
        assert.isTrue(type(version) == "string" and version ~= "",
            "getKoreaderVersion must report a non-empty string")
        local prompt = M.assistant_prompts.default.system_prompt
        assert.matches(prompt, "current KOReader runtime version is")
        -- Plain find: the revision may contain Lua pattern magic characters.
        assert.isTrue(prompt:find(version, 1, true) ~= nil,
            "the reported revision must appear verbatim in the system prompt")
    end),

    -- =========================================================================
    -- 2. Deep-merge override semantics
    -- =========================================================================

    test("getMergedPrompts: field-level merge (explain flipped to false)", function()
        M.invalidateCache()
        local merged = M.getMergedPrompts({ explain = { use_book_context = false } })
        assert.equal(merged.explain.use_book_context, false,
            "explain.use_book_context should be overridden to false")
        -- other fields preserved (field-level merge, not whole-entry replace)
        assert.notNil(merged.explain.text, "explain.text should be preserved")
        assert.notNil(merged.explain.order, "explain.order should be preserved")
    end),

    test("getMergedPrompts: flip default-false vocabulary up to true", function()
        M.invalidateCache()
        local merged = M.getMergedPrompts({ vocabulary = { use_book_context = true } })
        assert.equal(merged.vocabulary.use_book_context, true,
            "vocabulary.use_book_context should be flipped to true")
        assert.notNil(merged.vocabulary.text, "vocabulary.text should be preserved")
    end),

    test("getMergedPrompts: nil conf after invalidateCache returns built-in defaults", function()
        M.invalidateCache()
        local merged = M.getMergedPrompts(nil)
        assert.equal(merged.summarize.use_book_context, true, "summarize should default true")
        assert.equal(merged.vocabulary.use_book_context, false, "vocabulary should default false")
        assert.equal(merged.explain.use_book_context, true, "explain should default true")
    end),

    -- =========================================================================
    -- 3. Feature switches: M.isSuggestionsEnabled
    -- =========================================================================

    test("isSuggestionsEnabled: global true, no prompt_config -> built-in default", function()
        -- With the global switch on and no per-prompt override, the built-in
        -- default for the "default" prompt decides.
        assert.equal(M.assistant_prompts.default.show_suggestions, true,
            "the built-in default prompt is expected to enable suggestions")
        assert.isTrue(M.isSuggestionsEnabled(settingsWith(true, "auto_prompt_suggest"), nil))
    end),

    test("isSuggestionsEnabled: explicit false overrides the global true", function()
        assert.isFalse(M.isSuggestionsEnabled(settingsWith(true, "auto_prompt_suggest"),
            { show_suggestions = false }),
            "an explicit per-prompt false must win over the global true")
    end),

    test("isSuggestionsEnabled: explicit true overrides the global true", function()
        assert.isTrue(M.isSuggestionsEnabled(settingsWith(true, "auto_prompt_suggest"),
            { show_suggestions = true }))
    end),

    test("isSuggestionsEnabled: the global switch gates every prompt_config", function()
        local off = settingsWith(false, "auto_prompt_suggest")
        assert.isFalse(M.isSuggestionsEnabled(off, { show_suggestions = true }),
            "no prompt_config may re-enable suggestions while the global switch is off")
        assert.isFalse(M.isSuggestionsEnabled(off, nil))
        -- An unset global switch (readSetting default false) is off too.
        assert.isFalse(M.isSuggestionsEnabled({ readSetting = function(_, _, def) return def end },
            { show_suggestions = true }))
    end),

    test("isSuggestionsEnabled: a missing setting reads as off", function()
        local unset = { readSetting = function(_, _, def) return def end }
        assert.isFalse(M.isSuggestionsEnabled(unset, nil))
        assert.isFalse(M.isSuggestionsEnabled(unset, { show_suggestions = true }))
    end),

    -- =========================================================================
    -- 4. Feature switches: M.isWebSearchEnabled
    -- =========================================================================

    test("isWebSearchEnabled: 'none' disables", function()
        assert.isFalse(M.isWebSearchEnabled(settingsWith("none", "use_websearch")))
    end),

    test("isWebSearchEnabled: an unset setting disables", function()
        local unset = { readSetting = function(_, _, def) return def end }
        assert.isFalse(M.isWebSearchEnabled(unset))
    end),

    test("isWebSearchEnabled: the builtin engine enables", function()
        assert.isTrue(M.isWebSearchEnabled(settingsWith("builtin", "use_websearch")))
    end),

    test("isWebSearchEnabled: an external tool key enables", function()
        assert.isTrue(M.isWebSearchEnabled(settingsWith("tavilyapi", "use_websearch")))
    end),

    -- Failing closed is the whole point of the predicate: an unrecognized value
    -- must never route book text and questions to a search provider.
    test("isWebSearchEnabled: an unknown key disables", function()
        assert.isFalse(M.isWebSearchEnabled(settingsWith("nonexistent", "use_websearch")),
            "an unrecognized value must not enable web search")
    end),

    test("isWebSearchEnabled: the whitelist is exact (near misses disable)", function()
        assert.isFalse(M.isWebSearchEnabled(settingsWith("tavily", "use_websearch")))
        assert.isFalse(M.isWebSearchEnabled(settingsWith("serpapi ", "use_websearch")))
        assert.isFalse(M.isWebSearchEnabled(settingsWith(" builtin", "use_websearch")))
        assert.isFalse(M.isWebSearchEnabled(settingsWith("BUILTIN", "use_websearch")))
        assert.isFalse(M.isWebSearchEnabled(settingsWith("", "use_websearch")))
        assert.isFalse(M.isWebSearchEnabled(settingsWith(nil, "use_websearch")))
        assert.isFalse(M.isWebSearchEnabled(settingsWith(false, "use_websearch")))
    end),

    test("isWebSearchEnabled: every catalog tool key enables", function()
        for i, tool_key in ipairs(SearchTools.TOOL_KEYS) do
            assert.isTrue(M.isWebSearchEnabled(settingsWith(tool_key, "use_websearch")),
                tool_key .. " should enable web search")
        end
    end),

    -- =========================================================================
    -- 5. AI Dictionary output sections / presets
    -- =========================================================================

    test("dict_presets: standard/full exact lists and no concise preset", function()
        assert.equal(M.dict_presets.concise, nil, "concise is no longer a preset")

        assert.equal(#M.dict_presets.standard, 3, "standard should have 3 sections")
        assert.equal(M.dict_presets.standard[1], "meaning")
        assert.equal(M.dict_presets.standard[2], "translation")
        assert.equal(M.dict_presets.standard[3], "synonyms")

        local full = M.dict_presets.full
        assert.equal(#full, 6, "full should have 6 sections")
        assert.equal(full[1], "meaning")
        assert.equal(full[2], "translation")
        assert.equal(full[3], "synonyms")
        assert.equal(full[4], "word_form")
        assert.equal(full[5], "example")
        assert.equal(full[6], "origin")
    end),

    test("build_dict_prompt: standard has three sections and omits the rest", function()
        local p = M.build_dict_prompt(M.dict_presets.standard)
        assert.matches(p, "Meaning & Usage")
        assert.matches(p, "Translation")
        assert.matches(p, "Synonyms")
        assert.notMatches(p, "Word Form & Lemma")
        assert.notMatches(p, "Example")
        assert.notMatches(p, "Word Origin")
    end),

    test("build_dict_prompt: full has all six sections and word-form rules", function()
        local p = M.build_dict_prompt(M.dict_presets.full)
        assert.matches(p, "Meaning & Usage")
        assert.matches(p, "Translation")
        assert.matches(p, "Synonyms")
        assert.matches(p, "Word Form & Lemma")
        assert.matches(p, "Example")
        assert.matches(p, "Word Origin")
        assert.matches(p, "Word%-Form Analysis %(required%)")
    end),

    test("build_dict_prompt: a section subset omits word-form task and analysis rules", function()
        local p = M.build_dict_prompt({ "meaning", "translation" })
        assert.notMatches(p, "Word%-Form Analysis %(required%)")
        assert.matches(p, "## Task: Book%-Aware Dictionary")
        assert.notMatches(p, "and Word%-Form Analysis")
    end),

    test("build_dict_prompt: keeps caller placeholders", function()
        local p = M.build_dict_prompt(M.dict_presets.standard)
        assert.matches(p, "{word}")
        assert.matches(p, "{context}")
        assert.matches(p, "{language}")
    end),

    test("build_dict_prompt: bolds the queried headword everywhere", function()
        local p = M.build_dict_prompt(M.dict_presets.standard)
        assert.matches(p, "%*%*Headword in Bold%*%*")
        assert.matches(p, "%*%*{word}%*%*")
    end),

    test("build_dict_prompt: headword exception only when translation is enabled", function()
        local with_translation = M.build_dict_prompt({ "meaning", "translation" })
        assert.matches(with_translation, "in the Translation section")
        local without_translation = M.build_dict_prompt({ "meaning", "synonyms" })
        assert.notMatches(without_translation, "in the Translation section")
    end),

    test("presetToMap: standard maps meaning+translation+synonyms", function()
        local map = M.presetToMap("standard")
        assert.equal(map.meaning, true)
        assert.equal(map.translation, true)
        assert.equal(map.synonyms, true)
        assert.equal(map.word_form, nil)
    end),

    test("resolveDictSections: default returns standard", function()
        local store = {}
        local settings = { readSetting = function(self, k, d) return store[k] or d end }
        local result = M.resolveDictSections(settings)
        assert.equal(#result, 3)
        assert.equal(result[1], "meaning")
        assert.equal(result[2], "translation")
        assert.equal(result[3], "synonyms")
    end),

    test("resolveDictSections: preset full returns full", function()
        local store = { dict_output_preset = "full" }
        local settings = { readSetting = function(self, k, d) return store[k] or d end }
        local result = M.resolveDictSections(settings)
        assert.equal(#result, 6)
        assert.equal(result[4], "word_form")
        assert.equal(result[5], "example")
        assert.equal(result[6], "origin")
    end),

    test("resolveDictSections: custom reads the saved section map in order", function()
        local store = {
            dict_output_preset = "custom",
            dict_output_sections = { meaning = true },
        }
        local settings = { readSetting = function(self, k, d) return store[k] or d end }
        local result = M.resolveDictSections(settings)
        assert.equal(#result, 1)
        assert.equal(result[1], "meaning")
    end),

    test("resolveDictSections: custom with empty map falls back to standard", function()
        local store = {
            dict_output_preset = "custom",
            dict_output_sections = {},
        }
        local settings = { readSetting = function(self, k, d) return store[k] or d end }
        local result = M.resolveDictSections(settings)
        assert.equal(#result, 3)
        assert.equal(result[1], "meaning")
        assert.equal(result[2], "translation")
        assert.equal(result[3], "synonyms")
    end),

    test("build_dict_prompt: concise opts swaps Book-Awareness for Brevity", function()
        local p = M.build_dict_prompt({ "meaning", "translation" }, { concise = true })
        assert.matches(p, "%*%*Brevity%*%*")
        assert.notMatches(p, "Book%-Awareness")
    end),

    test("build_dict_prompt: concise opts uses the short meaning body", function()
        local p = M.build_dict_prompt({ "meaning", "translation" }, { concise = true })
        assert.matches(p, "in one sentence")
        assert.notMatches(p, "what it suggests about the characters")
    end),

    test("build_dict_prompt: standard without opts keeps the full meaning body", function()
        local p = M.build_dict_prompt(M.dict_presets.standard)
        assert.matches(p, "Book%-Awareness")
        assert.notMatches(p, "%*%*Brevity%*%*")
        assert.matches(p, "what it suggests about the characters")
    end),

    test("build_dict_prompt: full with concise opts keeps sections but Brevity rules", function()
        local p = M.build_dict_prompt(M.dict_presets.full, { concise = true })
        assert.matches(p, "%*%*Brevity%*%*")
        assert.notMatches(p, "Book%-Awareness")
        assert.matches(p, "Word Form & Lemma")
    end),
}

return helper.runTests("assistant_prompts.lua", tests)
