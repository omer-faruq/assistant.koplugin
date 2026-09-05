local CONFIGURATION = {
    -- No `provider` key needed. The active provider is the one marked with
    -- `default = true` below (switch providers anytime from the plugin's
    -- Settings UI or provider switch menu).

    -- Provider-specific settings
    --
    -- NAMING PATTERN: Configuration keys follow the format {handler}_{description}
    -- - The part BEFORE the first underscore determines which API handler is used
    -- - The part AFTER the underscore is just a descriptive name (can be anything)
    --
    -- Only 4 handlers are supported for new configurations:
    --   openai, anthropic, gemini, responses
    -- Any OpenAI-compatible endpoint (DeepSeek, OpenRouter, Grok, Perplexity,
    -- Ollama, Mistral, ...) uses the `openai` handler with its own base_url,
    -- e.g. `openai_deepseek`, `openai_openrouter`.
    --
    -- DISPLAY NAME: add a `display_name` field to any provider. It is shown in
    -- the menu and settings UI instead of the raw key.
    --
    -- LEGACY KEYS: old standalone keys like `deepseek`, `openrouter`, `groq`,
    -- `mistral`, `ollama`, `gemma`, `gigachat` still work for backward
    -- compatibility, but do not use them for new configurations — use the
    -- `openai_*` form with `display_name` instead.
    --
    -- UI-ADDED PROVIDERS: You can also add providers directly from the plugin's
    -- Settings UI (Tools -> AI Assistant -> Settings -> Provider Settings -> Provider API).
    -- UI-added providers are saved to the plugin's settings file (not here) and
    -- merged with this configuration at startup. They support the same protocols:
    -- openai, anthropic, gemini, responses.
    --
    -- NOTE: no `additional_parameters` needed for basic usage. The handlers use
    -- sensible defaults; only add that field if you need to pass extra API
    -- options (temperature, max_tokens, etc.).
    --
    provider_settings = {
        openai = {
            default = true,          -- optional, used when `provider` above is not set
            visible = true,          -- optional, if set to false, will not shown in the provider switch
            model = "gpt-5.4-mini",  -- model list: https://platform.openai.com/docs/models
            base_url = "https://api.openai.com/v1",
            api_key = "your-openai-api-key",
            -- Optional: uncomment to pass extra API options.
            -- additional_parameters = {
            --     temperature = 0.7,
            --     top_p = 1.0,
            --     max_tokens = 4096,
            -- },
        },
        openai_deepseek = {
            display_name = "DeepSeek", -- shown in menu instead of "openai_deepseek"
            model = "deepseek-v4-flash",   -- model list: https://api-docs.deepseek.com/quickstart/first_api_call
            base_url = "https://api.deepseek.com/v1",
            api_key = "your-deepseek-api-key",
        },
        openai_openrouter = {
            display_name = "OpenRouter", -- shown in menu instead of "openai_openrouter"
            model = "openrouter/free", -- model list: https://openrouter.ai/models?order=top-weekly
            base_url = "https://openrouter.ai/api/v1",
            api_key = "your-openrouter-api-key",
            -- Per-model parameter presets (optional).
            -- When you switch models via Settings -> Browse Models, the matching
            -- entry here fully replaces `additional_parameters` for that model
            -- (no partial merge). Models without an entry keep the shared
            -- `additional_parameters` above.
            -- Because of full replacement, every key a model needs must be
            -- repeated in its preset.
            model_parameters = {
                -- Switching to this model via Browse Models applies this preset:
                -- ["qwen/qwen3-next-80b-a3b:free"] = {
                --     temperature = 0.7,
                --     max_tokens = 6000,
                --     reasoning = { effort = "high" },
                -- },
                -- An empty table ({}) discards all shared parameters for that
                -- model — use it only if the model needs no extra parameters:
                -- ["model/that-needs-nothing:free"] = {},
            }
        },
        openai_grok = {
            display_name = "Grok (xAI)", -- shown in menu instead of "openai_grok"
            model = "grok-4-latest",       -- alias tracks the latest Grok 4 release, see: https://docs.x.ai/developers/models
            base_url = "https://api.x.ai/v1",
            api_key = "your-grok-api-key",
        },
        openai_perplexity = {
            display_name = "Perplexity",
            visible = false,          -- optional, if set to false, will not shown in the provider switch
            model = "sonar-pro",      -- model list: https://docs.perplexity.ai/guides/model-cards
            base_url = "https://api.perplexity.ai",
            api_key = "pplx-your-api-key",
        },
        openai_ollama = {
            display_name = "Ollama (local)",
            visible = false,          -- optional, if set to false, will not shown in the provider switch
            model = "your-preferred-model",         -- model list: https://ollama.com/library
            base_url = "your-ollama-api-endpoint",  -- ex: "http://localhost:11434/v1"
            api_key = "ollama",
        },
        anthropic = {
            visible = true,                    -- optional, if set to false, will not shown in the provider switch
            model = "claude-3-5-haiku-latest", -- model list: https://docs.anthropic.com/en/docs/about-claude/models
            base_url = "https://api.anthropic.com/v1",
            api_key = "your-anthropic-api-key",
            -- NOTE: the Anthropic API requires max_tokens — copy the
            -- additional_parameters pattern from `openai` above and set it.
        },
        gemini = {
            model = "gemini-flash-latest", -- model list: https://ai.google.dev/gemini-api/docs/models , ex: gemini-2.5-pro , gemini-2.5-flash
            base_url = "https://generativelanguage.googleapis.com/v1beta/models/",
            api_key = "your-gemini-api-key",
        },
        -- OpenAI Responses API — newer /v1/responses endpoint with built-in tools
        -- Built-in web_search: set use_websearch = "builtin" in plugin settings
        -- (no external search API key needed). The API handles search directly —
        -- no SerpAPI/Tavily/SearXNG/Exa configuration required.
        responses_openai = {
            display_name = "OpenAI Responses",
            visible = false,       -- optional, set to true to show in provider switch
            model = "gpt-4o-mini", -- model list: https://platform.openai.com/docs/models
            base_url = "https://api.openai.com/v1",
            api_key = "your-openai-api-key",
        },
        serpapi = {
            -- External Search Tool API: SerpAPI, free tier: 250 searchs / month
            -- https://serpapi.com/
            api_key = "your-serp-api-key"
        },
        tavilyapi = {
            -- External Search Tool API: Tavily, free tier: 1000 searchs / month
            -- https://www.tavily.com/
            api_key = "your-tavily-api-key"
        },
        searxngapi = {
            -- External Search Tool API: SearXNG, opensource and free, hosted on you own server.
            -- https://github.com/searxng/searxng
            base_url = "https://you-searxng-address"
            -- keys not needed
        },
        exaapi = {
            -- External Search Tool API: Exa.ai, semantic search for AI agents.
            -- Free tier: 100 searches/month. Get key at https://dashboard.exa.ai/api-keys
            -- Docs: https://exa.ai/docs/reference/search-api-guide-for-coding-agents
            api_key = "your-exa-api-key"
        }
    },

    -- Optional features
    features = {
        hide_highlighted_text = false,         -- Set to true to hide the highlighted text at the top
        hide_long_highlights = true,           -- Hide highlighted text if longer than threshold
        long_highlight_threshold = 500,        -- Number of characters considered "long"
        -- system_prompt = "You are a helpful AI assistant. Always respond in Markdown format.", -- Custom system prompt for the AI ("Ask" button) to override the default, to disable set to nil
        updater_disabled = false,              -- Set to true to disable update check.
        update_check_url = "https://api.github.com/repos/omer-faruq/assistant.koplugin/releases/latest", -- URL for checking latest release
        ota_github_base = "https://github.com", -- GitHub proxy base URL for OTA updates
        ota_github_repo = "omer-faruq/assistant.koplugin", -- GitHub repository for OTA updates
        default_folder_for_logs = nil,         -- Set the default folder for auto saved logs, nil for the same folder as the book, ex: "/mnt/onboard/logs/" for Kobo , "/mnt/us/documents/logs/" for Kindle
        max_text_length_for_analysis = 100000, -- max text length to be used on xray-recap-book analyzes,
        max_page_size_for_analysis = 250,      -- maximum page size to be used on xray-recap-book analyzes (for page-based documents, ex: PDF)
        max_page_context_chars = 6000,         -- max characters of nearby-page text sent as context when "Add Nearby Page Text as Context" is enabled

        -- Term X-Ray context expansion settings (for analyzing characters, objects, places, concepts, magic)
        -- NOTE: The following settings are optimized to provide ~40k input tokens per term x-ray lookup, using ~10% of a 400k token context window.
        -- This allows rich analysis of characters, magic systems, plot elements, and relationships in fantasy books.
        term_xray_context_sentences_before = 5, -- Number of sentences to include BEFORE matching sentences for context (captures descriptions, setup)
        term_xray_context_sentences_after = 5,  -- Number of sentences to include AFTER matching sentences for context (captures effects, consequences)
        -- These settings help capture pronouns (he/she/it/that) and narrative context that the LLM needs for complete analysis
        -- Increase to 3+ for complex magic systems or concepts; decrease to 1 for quick summaries
        -- Example: For "the Ring", before context captures "The Dark Lord had created..." and after captures "...His mind began to cloud"

        -- LexRank algorithm configuration for intelligent context selection
        -- LexRank scores sentences based on importance and relevance to identify key content.
        -- Suggested values: 1000-2000 (process quickly), 2500 (recommended), 5000+ (exhaustive analysis)
        lexrank_max_sentences = 2500,

        -- What percentage of high-ranking sentences should be selected? Higher = more inclusive.
        -- 0.70 (70%): Conservative, quality-focused sentences only
        -- 0.90 (90%): Balanced, includes most important content
        -- 0.99 (99%): Comprehensive, nearly all ranked content included
        lexrank_min_selection_percentage = 0.99,

        -- Upper bound on sentence selection. Prevents over-selection in smaller texts.
        -- 0.85 (85%): Conservative approach, focuses on best matches
        -- 1.0 (100%): Includes all available context material
        lexrank_max_selection_percentage = 1.0,

        -- Relevance threshold for sentences containing the searched term. Lower = more inclusive.
        -- 0.05: Strict filtering, only very relevant term matches
        -- 0.01: Inclusive, captures weaker term relevance
        -- 0.005: Exhaustive, includes tangential mentions
        lexrank_threshold_term_specific = 0.01,

        -- Relevance threshold for general context sentences. Lower = more inclusive.
        -- 0.05: Strict filtering, high-relevance background context only
        -- 0.01: Balanced, includes good supporting content
        -- 0.005: Comprehensive, captures all contextual material
        lexrank_threshold_general = 0.01,

        -- Fallback threshold when not enough sentences are found. Very permissive.
        -- 0.02: More selective fallback
        -- 0.005: Very inclusive fallback
        lexrank_threshold_very_inclusive = 0.005,

        -- Term-specific context settings
        -- How many surrounding sentences to include around term mentions?
        -- 5: Minimal context (focuses on term itself)
        -- 10: Moderate context (includes narrative details)
        -- 15+: Extensive context (shows full scene/paragraph)
        term_filter_context_window = 15,

        -- Hard character limit for total context sent to LLM. Controls token usage.
        -- 50000 chars (~12k tokens): Quick lookups, lighter processing
        -- 100000 chars (~25k tokens): Balanced context for rich analysis (recommended)
        -- 200000 chars (~50k tokens): Comprehensive context, uses more of context window
        term_xray_max_characters = 100000,

        -- These are prompts defined in `assistant_prompts.lua`, can be overriden here.
        -- each prompt shown as a button in the main dialog.
        -- The `order` determines the position in the main popup.
        -- The `show_on_main_popup` determines if the prompt is shown in the main popup
        -- The `show_on_dictionary_popup` determines if the prompt is shown in the dictionary popup ( max 3 including the built-in ones)
        -- Set `visible = false` to hide the prompt from all popups.
        -- Available placeholders to use in the prompts: {user_input},{highlight},{title},{author},{language},{progress},{chapter}
        -- Per-prompt override `use_book_context = true/false` (deep-merged over the built-in defaults below).
        -- When true, book metadata (title, author, current reading position incl. chapter) is prepended to the
        -- prompt so the AI can answer with awareness of the book. This is gated by the global master switch
        -- "Add Book Metadata as Context" in the plugin settings menu (enabled by default); that switch is
        -- NOT set in configuration.lua. This flag is the general "book awareness" gate for prompts; future
        -- context levels (e.g. surrounding page text) would reuse it behind their own separate switches.
        -- Enabling "Add Nearby Page Text as Context" in the settings menu additionally appends ±1 page of
        -- surrounding book text (default off; requires the prompt's use_book_context).
        -- Built-in defaults: use_book_context = true only for explain, historical_context, summarize, key_points, ELI5;
        -- false for translate, vocabulary, grammar, wikipedia, simplify, term_xray, dictionary, quick_note and others.
        -- Per-prompt override `show_suggestions = true/false` -- whether to append follow-up questions after this prompt (requires global Show Follow-up Questions enabled).
        -- Built-in defaults: show_suggestions = true only for key_points, ELI5, explain, historical_context, wikipedia;
        -- false for vocabulary, grammar, translate, summarize, simplify, dictionary, quick_note, term_xray.
        prompts = {

            -- hide some prompts to keep the UI clean
            -- simplify           = { visible = false, }, -- hide from everywhere

            --
            -- example of adding a user-defined prompt:
            -- myprompt = { text ="Prompt Title", system_prompt = "you are a helpful assistant.", user_prompt = "describe the following text in detail: {highlight}", order = 50, show_on_main_popup = true, },

        },

        book_level_prompts = {
            -- for an example of a user-defined book-level prompt, see: https://github.com/omer-faruq/assistant.koplugin/wiki/configuration#5-book-level-custom-prompts
        },

        -- AI Recap configuration
        -- If you want to override the default prompts, you can uncomment and modify the following lines:
        -- recap_config = {
        --   system_prompt = "",
        --   user_prompt = ""
        -- },
    }
}

return CONFIGURATION
