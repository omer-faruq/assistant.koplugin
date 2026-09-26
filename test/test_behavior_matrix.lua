-- test_behavior_matrix.lua
-- Phase 0 behavior baseline: locks request-level decisions for each entry
-- point before the conversation refactor.
--
-- Covers:
--   * context insertion policy (initial vs follow-up, per entry)
--   * use_websearch propagation (who sets it, who reads it)
--   * show_suggestions inheritance (per entry, per prompt config)
--   * dictionary use_websearch semantics (currently implicit)
--   * viewer title/header propagation
--
-- Strategy: source-scan the dialog flows (widget-heavy, not headless-safe)
-- plus direct tests for the pure policy functions.
local helper = require("test.helper")
local assert = helper.assert
local Prompts = require("assistant_prompts")
local koutil = require("util")

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local dialog_src = read_source("assistant_dialog.lua")
local feature_src = read_source("assistant_featuredialog.lua")
local dict_src = read_source("assistant_dictdialog.lua")
local querier_src = read_source("assistant_querier.lua")

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    -- =====================================================================
    -- Context insertion policy
    -- =====================================================================

    test("dialog: free question initial inserts book context", function()
        -- _prepareMessageHistoryForUserQuery with include_book_context=true inserts context
        assert.matches(dialog_src, 'self:_prepareMessageHistoryForUserQuery%(message_history, highlightedText, user_question, use_web_search_checkbox.checked%)',
            "free question must prepare history with context")
        assert.matches(dialog_src, 'self:_buildBookContextMessage%(highlightedText%)',
            "context must be built from highlighted text")
    end),

    test("dialog: preset prompt initial inserts book context when configured", function()
        assert.matches(dialog_src, 'if prompt_config.use_book_context == true',
            "preset prompt must check use_book_context")
        assert.matches(dialog_src, 'table.insert%(message_history, self:_buildBookContextMessage%(highlightedText%)%)',
            "preset prompt must insert context when configured")
    end),

    test("dialog: free follow-up keeps book context (include_book_context_for_followup=true)", function()
        assert.matches(dialog_src, 'self:_showResultViewer%(highlightedText, message_history, viewer_title, true%)',
            "free question viewer must pass include_book_context_for_followup=true")
    end),

    test("dialog: preset follow-up does NOT insert new context (include_book_context_for_followup=false)", function()
        assert.matches(dialog_src, 'self:_showResultViewer%(highlightedText, message_history, title, false%)',
            "preset viewer must pass include_book_context_for_followup=false")
    end),

    test("dialog: preset table follow-up with use_book_context=true inserts fresh context", function()
        assert.matches(dialog_src, 'if include_book_context_for_followup%s*and user_question.use_book_context == true',
            "preset table follow-up must conditionally insert context")
    end),

    test("feature: initial request builds its own context (no _buildBookContextMessage)", function()
        assert.notMatches(feature_src, '_buildBookContextMessage',
            "feature does not use the dialog's book context builder")
        assert.matches(feature_src, 'table.insert%(message_history, context_message%)',
            "feature inserts its own context message")
    end),

    test("feature: follow-up does NOT insert new context", function()
        assert.matches(feature_src, 'content = user_question',
            "feature free follow-up must pass question unchanged (no context prefix)")
        assert.matches(feature_src, 'content = expanded_followup',
            "feature table follow-up must pass expanded prompt (no context prefix)")
    end),

    test("dict: initial request builds context from selected word", function()
        assert.matches(dict_src, 'table.insert%(message_history, context_message%)',
            "dict must insert context message")
        assert.matches(dict_src, 'prev_context %.%. highlightedText %.%. next_context',
            "dict context is word-level, not book-level")
    end),

    -- =====================================================================
    -- use_websearch propagation
    -- =====================================================================

    test("dialog: free question sets use_websearch on last user message from checkbox", function()
        assert.matches(dialog_src, 'ASUtils.set_attr%(question_message, "use_websearch", use_websearch or false%)',
            "dialog must tag use_websearch on the question message")
    end),

    test("dialog: preset prompt sets use_websearch from prompt config", function()
        assert.matches(dialog_src, 'ASUtils.set_attr%(_user, "use_websearch", koutil.tableGetValue%(prompt_config, "use_websearch"%) or false%)',
            "preset prompt must tag use_websearch from config")
    end),

    test("dialog: free follow-up sets use_websearch from viewer checkbox", function()
        assert.matches(dialog_src, 'ASUtils.set_attr%(question_message, "use_websearch", use_websearch or false%)',
            "free follow-up must tag use_websearch")
    end),

    test("dialog: preset table follow-up sets use_websearch from prompt config", function()
        assert.matches(dialog_src, 'ASUtils.set_attr%(_user, "use_websearch", user_question.use_websearch%)',
            "preset table follow-up must tag use_websearch from config")
    end),

    test("feature: initial sets use_websearch from feature config", function()
        assert.matches(feature_src, 'ASUtils.set_attr%(context_message, "use_websearch", user_prompt_use_websearch%)',
            "feature must tag use_websearch from its config")
    end),

    test("feature: free follow-up sets use_websearch from viewer checkbox", function()
        assert.matches(feature_src, 'ASUtils.set_attr%(context, "use_websearch", use_websearch or false%)',
            "feature free follow-up must tag use_websearch from checkbox")
    end),

    test("feature: preset table follow-up sets use_websearch from prompt config", function()
        assert.matches(feature_src, 'ASUtils.set_attr%(followup_user, "use_websearch", user_question.use_websearch or false%)',
            "feature table follow-up must tag use_websearch from config")
    end),

    test("querier: does NOT read use_websearch from last message (explicit protocol)", function()
        -- Phase 1: the implicit "last message carries use_websearch" protocol
        -- is removed. Querier receives explicit opts.use_websearch instead.
        assert.notMatches(querier_src, 'ASUtils.get_attr%(message_history%[#message_history%], "use_websearch"',
            "querier must NOT read use_websearch from the last message")
        assert.matches(querier_src, 'opts%.use_websearch',
            "querier must accept explicit opts.use_websearch")
    end),

    -- =====================================================================
    -- show_suggestions inheritance
    -- =====================================================================

    test("dialog: free question inherits show_suggestions from last user message", function()
        assert.matches(dialog_src, 'for i = #message_history, 1, %-1 do%s*if message_history%[i%].role == "user" then%s*local v = ASUtils.get_attr%(message_history%[i%], "show_suggestions"%)',
            "dialog must inherit show_suggestions from the last user message")
    end),

    test("dialog: free question falls back to default when no prior attr", function()
        assert.matches(dialog_src, 'pending_show_suggestions = Prompts.isSuggestionsEnabled%(self.assistant.settings, Prompts.assistant_prompts.default%)',
            "dialog must fall back to default suggestions config")
    end),

    test("dialog: preset prompt sets show_suggestions from prompt config", function()
        assert.matches(dialog_src, 'ASUtils.set_attr%(_user, "show_suggestions", Prompts.isSuggestionsEnabled%(self.assistant.settings, prompt_config%)',
            "preset prompt must set show_suggestions from its config")
    end),

    test("feature: sets show_suggestions from feature config on every message", function()
        assert.matches(feature_src, 'ASUtils.set_attr%(context_message, "show_suggestions", Prompts.isSuggestionsEnabled%(assistant.settings, feature_prompt_config%)',
            "feature initial must set show_suggestions")
        assert.matches(feature_src, 'ASUtils.set_attr%(context, "show_suggestions", Prompts.isSuggestionsEnabled%(assistant.settings, feature_prompt_config%)',
            "feature free follow-up must set show_suggestions")
        assert.matches(feature_src, 'ASUtils.set_attr%(followup_user, "show_suggestions", Prompts.isSuggestionsEnabled%(assistant.settings, feature_prompt_config%)',
            "feature table follow-up must set show_suggestions")
    end),

    test("dict: sets show_suggestions from dict prompt config", function()
        assert.matches(dict_src, 'Conversation%.append_answer%(message_history, ret,%s*Prompts%.isSuggestionsEnabled%(assistant.settings, prompt_config%)',
            "dict must append answer with show_suggestions from its prompt config")
    end),

    -- =====================================================================
    -- Dictionary use_websearch semantics
    -- =====================================================================

    test("dict: does NOT pass explicit use_websearch (relies on global fallback)", function()
        -- Dictionary dialog does not set use_websearch on messages and does
        -- not pass an explicit override; querier falls back to the global setting.
        assert.notMatches(dict_src, 'use_websearch%s*=',
            "dict must not set use_websearch anywhere")
    end),

    test("dict: passes message_history directly to querier", function()
        assert.matches(dict_src, 'Querier:query%(message_history, title%)',
            "dict must query with its full history")
    end),

    -- =====================================================================
    -- Viewer title/header propagation
    -- =====================================================================

    test("dialog: free question viewer has no title", function()
        assert.matches(dialog_src, 'self:_showResultViewer%(highlightedText, message_history, viewer_title, true%)',
            "free question passes nil title to viewer")
    end),

    test("dialog: preset prompt viewer has title from prompt", function()
        assert.matches(dialog_src, 'self:_showResultViewer%(highlightedText, message_history, title, false%)',
            "preset prompt passes its title to viewer")
    end),

    test("feature: viewer has feature title", function()
        assert.matches(feature_src, 'title = feature_title',
            "feature passes its title to viewer")
    end),

    test("dict: viewer has dict/term_xray title", function()
        assert.matches(dict_src, 'title = title',
            "dict passes its title to viewer")
    end),

    -- =====================================================================
    -- Querier interface (the implicit protocol to be replaced)
    -- =====================================================================

    test("querier: signature is query(message_history, title, opts)", function()
        assert.matches(querier_src, 'function Querier:query%(message_history, title, opts%)',
            "querier query signature must be (message_history, title, opts)")
    end),

    test("querier: showError takes message_history", function()
        assert.matches(querier_src, 'function Querier:showError%(err, message_history%)',
            "querier showError must take message_history")
    end),

    -- =====================================================================
    -- Pure policy functions (direct tests)
    -- =====================================================================

    test("Prompts.isSuggestionsEnabled: nil config falls back to global", function()
        local settings = {
            readSetting = function(_, key, def)
                if key == "auto_prompt_suggest" then return true end
                return def
            end,
        }
        -- nil config -> use global setting
        assert.isTrue(Prompts.isSuggestionsEnabled(settings, nil),
            "nil config must fall through to global auto_prompt_suggest")
    end),

    test("Prompts.isSuggestionsEnabled: explicit false beats global true", function()
        local settings = {
            readSetting = function(_, key, def)
                if key == "auto_prompt_suggest" then return true end
                return def
            end,
        }
        assert.isFalse(Prompts.isSuggestionsEnabled(settings, { show_suggestions = false }),
            "explicit false must win over global true")
    end),

    test("Prompts.isSuggestionsEnabled: global auto_prompt_suggest=false gates everything", function()
        -- Current behavior: the global switch is checked first; if off, no
        -- prompt_config override can re-enable suggestions.
        local settings = {
            readSetting = function(_, key, def)
                if key == "auto_prompt_suggest" then return false end
                return def
            end,
        }
        assert.isFalse(Prompts.isSuggestionsEnabled(settings, { show_suggestions = true }),
            "global false must gate even when prompt_config says true")
        assert.isFalse(Prompts.isSuggestionsEnabled(settings, nil),
            "global false must gate when no prompt_config")
    end),

    test("Prompts.isSuggestionsEnabled: explicit false beats default true", function()
        local settings = {
            readSetting = function(_, key, def)
                if key == "auto_prompt_suggest" then return true end
                return def
            end,
        }
        assert.isFalse(Prompts.isSuggestionsEnabled(settings, { show_suggestions = false }),
            "explicit false must win over the default")
    end),

    test("Prompts.isSuggestionsEnabled: explicit true beats default false", function()
        local settings = {
            readSetting = function(_, key, def)
                if key == "auto_prompt_suggest" then return true end
                return def
            end,
        }
        assert.isTrue(Prompts.isSuggestionsEnabled(settings, { show_suggestions = true }),
            "explicit true must win over the default")
    end),

    test("Prompts.isWebSearchEnabled: none disables", function()
        local settings = {
            readSetting = function(_, key, def)
                if key == "use_websearch" then return "none" end
                return def
            end,
        }
        assert.isFalse(Prompts.isWebSearchEnabled(settings),
            "use_websearch=none must disable web search")
    end),

    test("Prompts.isWebSearchEnabled: builtin enables", function()
        local settings = {
            readSetting = function(_, key, def)
                if key == "use_websearch" then return "builtin" end
                return def
            end,
        }
        assert.isTrue(Prompts.isWebSearchEnabled(settings),
            "use_websearch=builtin must enable web search")
    end),

    test("Prompts.isWebSearchEnabled: external key enables", function()
        local settings = {
            readSetting = function(_, key, def)
                if key == "use_websearch" then return "tavilyapi" end
                return def
            end,
        }
        assert.isTrue(Prompts.isWebSearchEnabled(settings),
            "use_websearch=tavilyapi must enable web search")
    end),

    test("Prompts.isWebSearchEnabled: unknown key enables (current behavior)", function()
        -- Current behavior: any value other than "none" enables web search,
        -- including unrecognized keys. This is the baseline to preserve.
        local settings = {
            readSetting = function(_, key, def)
                if key == "use_websearch" then return "nonexistent" end
                return def
            end,
        }
        assert.isTrue(Prompts.isWebSearchEnabled(settings),
            "unknown use_websearch key currently enables web search (baseline)")
    end),
}

return helper.runTests("behavior_matrix.lua", tests)
