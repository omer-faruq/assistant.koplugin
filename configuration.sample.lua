local CONFIGURATION = {
    -- Choose your preferred AI provider: "anthropic", "openai", "gemini", ...
    -- use one of the settings defined in provider_settings below.
    -- NOTE: "openai" , "openai_grok" are different service using same handling code.
    provider = "openai",

    -- Provider-specific settings
    provider_settings = {
        openai = {
            defalut = true,        -- optional, if provider above is not set, will try to find one with `defalut =  true`
            visible = true,        -- optional, if set to false, will not shown in the provider switch
            model = "gpt-4o-mini", -- model list: https://platform.openai.com/docs/models
            base_url = "https://api.openai.com/v1/chat/completions",
            api_key = "your-openai-api-key",
            additional_parameters = {
                temperature = 0.7,
                max_tokens = 4096
            }
        },
        openai_grok = {
            --- use grok model via openai handler
            model = "grok-3-mini-fast", -- model list: https://docs.x.ai/docs/models
            base_url = "https://api.x.ai/v1/chat/completions",
            api_key = "your-grok-api-key",
            additional_parameters = {
                temperature = 0.7,
                max_tokens = 4096
            }
        },
        anthropic = {
            visible = true,                    -- optional, if set to false, will not shown in the profile switch
            model = "claude-3-5-haiku-latest", -- model list: https://docs.anthropic.com/en/docs/about-claude/models
            base_url = "https://api.anthropic.com/v1/messages",
            api_key = "your-anthropic-api-key",
            additional_parameters = {
                anthropic_version = "2023-06-01", -- api version list: https://docs.anthropic.com/en/api/versioning
                max_tokens = 4096
            }
        },
        -- Anthropic with web search
        anthropic_websearch = {
            visible = false,                   -- optional, if set to false, will not shown in the profile switch
            model = "claude-3-5-haiku-latest", -- model list: https://docs.anthropic.com/en/docs/about-claude/models
            base_url = "https://api.anthropic.com/v1/messages",
            api_key = "your-anthropic-api-key",
            additional_parameters = {
                anthropic_version = "2023-06-01", -- api version list: https://docs.anthropic.com/en/api/versioning
                max_tokens = 4096,
                tools = {
                    { -- enable web search
                        type = "web_search_20250305",
                        name = "web_search",
                        max_uses = 5,
                    },
                }
            }
        },
        gemini = {
            model = "gemini-2.5-flash", -- model list: https://ai.google.dev/gemini-api/docs/models , ex: gemini-2.5-pro , gemini-2.5-flash
            base_url = "https://generativelanguage.googleapis.com/v1beta/models/",
            api_key = "your-gemini-api-key",
            additional_parameters = {
                temperature = 0.7,
                max_tokens = 1048576,
                -- Set to 0 to disable thinking. Recommended for gemini-2.5-* and newer, where thinking is enabled by default.
                thinking_budget = 0
            }
        },
        openrouter = {
            model = "google/gemini-2.0-flash-exp:free", -- model list: https://openrouter.ai/models?order=top-weekly
            base_url = "https://openrouter.ai/api/v1/chat/completions",
            api_key = "your-openrouter-api-key",
            additional_parameters = {
                temperature = 0.7,
                max_tokens = 4096,
                -- Reasoning tokens configuration (optional)
                -- reference: https://openrouter.ai/docs/use-cases/reasoning-tokens
                -- reasoning = {
                --     -- One of the following (not both):
                --     effort = "high", -- Can be "high", "medium", or "low" (OpenAI-style)
                --     -- max_tokens = 2000, -- Specific token limit (Anthropic-style)
                --     -- Or enable reasoning with the default parameters:
                --     -- enabled = true -- Default: inferred from effort or max_tokens
                -- }
            }
        },
        openrouter_free = {
            --- use another free model with defferent configuration
            model = "deepseek/deepseek-chat-v3-0324:free", -- model list: https://openrouter.ai/models?order=top-weekly
            base_url = "https://openrouter.ai/api/v1/chat/completions",
            api_key = "your-openrouter-api-key",
            additional_parameters = {
                temperature = 0.7,
                max_tokens = 4096,
            }
        },
        deepseek = {
            model = "deepseek-chat",
            base_url = "https://api.deepseek.com/v1/chat/completions",
            api_key = "your-deepseek-api-key",
            additional_parameters = {
                temperature = 0.7,
                max_tokens = 4096
            }
        },
        ollama = {
            model = "your-preferred-model",        -- model list: https://ollama.com/library
            base_url = "your-ollama-api-endpoint", -- ex: "https://ollama.example.com/api/chat"
            api_key = "ollama",
            additional_parameters = {}
        },
        mistral = {
            model = "mistral-small-latest", -- model list: https://docs.mistral.ai/getting-started/models/models_overview/
            base_url = "https://api.mistral.ai/v1/chat/completions",
            api_key = "your-mistral-api-key",
            additional_parameters = {
                temperature = 0.7,
                max_tokens = 4096
            }
        },
        groq = {
            model = "llama-3.3-70b-versatile", -- model list: https://console.groq.com/docs/models
            base_url = "https://api.groq.com/openai/v1/chat/completions",
            api_key = "your-groq-api-key",
            additional_parameters = {
                temperature = 0.7,
                -- config options, see: https://console.groq.com/docs/api-reference
                -- eg: disable reasoning for model qwen3, set:
                -- reasoning_effort = "none"
            }
        },
        groq_qwen = {
            --- Recommended setting
            --- qwen3 without reasoning
            model = "qwen/qwen3-32b",
            base_url = "https://api.groq.com/openai/v1/chat/completions",
            api_key = "your-groq-api-key",
            additional_parameters = {
                temperature = 0.7,
                reasoning_effort = "none"
            }
        },
        azure_openai = {
            endpoint = "https://your-resource-name.openai.azure.com", -- Your Azure OpenAI resource endpoint
            deployment_name = "your-deployment-name",                 -- Your model deployment name
            api_version = "2024-02-15-preview",                       -- Azure OpenAI API version
            api_key = "your-azure-api-key",                           -- Your Azure OpenAI API key
            temperature = 0.7,
            max_tokens = 4096
        },
    },

    -- Optional features
    features = {
        hide_highlighted_text = false,         -- Set to true to hide the highlighted text at the top
        hide_long_highlights = true,           -- Hide highlighted text if longer than threshold
        long_highlight_threshold = 500,        -- Number of characters considered "long"
        -- system_prompt = "You are a helpful AI assistant. Always respond in Markdown format.", -- Custom system prompt for the AI ("Ask" button) to override the default, to disable set to nil
        render_markdown = true,                -- Set to true to render markdown in the AI responses
        updater_disabled = false,              -- Set to true to disable update check.
        default_folder_for_logs = nil,         -- Set the default folder for auto saved logs, nil for the same folder as the book, ex: "/mnt/onboard/logs/" for Kobo , "/mnt/us/documents/logs/" for Kindle
        max_text_length_for_analysis = 100000, -- max text length to be used on xray-recap-book analyzes,
        max_page_size_for_analysis = 250,      -- maximum page size to be used on xray-recap-book analyzes (for page-based documents, ex: PDF)

        -- Term X-Ray context expansion settings (for analyzing characters, objects, places, concepts, magic)
        -- NOTE: The following settings are optimized to provide ~40k input tokens per term x-ray lookup, using ~10% of a 400k token context window.
        -- This allows rich analysis of characters, magic systems, plot elements, and relationships in fantasy books.
        term_xray_context_sentences_before = 5, -- Number of sentences to include BEFORE matching sentences for context (captures descriptions, setup)
        term_xray_context_sentences_after = 5,  -- Number of sentences to include AFTER matching sentences for context (captures effects, consequences)
        -- These settings help capture pronouns (he/she/it/that) and narrative context that the LLM needs for complete analysis
        -- Increase to 3+ for complex magic systems or concepts; decrease to 1 for quick summaries
        -- Example: For "the Ring", before context captures "The Dark Lord had created..." and after captures "...His mind began to cloud"

        -- LexRank algorithm configuration for intelligent context selection
        -- LexRank scores sentences based on importance and relevance. These settings control how much text is sent to the LLM.
        lexrank_max_sentences = 2500,            -- Maximum number of sentences to extract (default: 2500, was: 200). Increase for fuller context, decrease for faster processing.
        lexrank_min_selection_percentage = 0.99, -- Minimum percentage of top-ranked sentences to include (default: 0.99 = 99%, was: 0.70). Higher = more inclusive.
        lexrank_max_selection_percentage = 1.0,  -- Maximum percentage of top-ranked sentences to include (default: 1.0 = 100%, was: 0.85). Higher = more comprehensive.

        -- LexRank filtering thresholds (lower threshold = more sentences included)
        lexrank_threshold_term_specific = 0.01,   -- Threshold for sentences containing the searched term (default: 0.01, was: 0.05). Lower = include weaker matches.
        lexrank_threshold_general = 0.01,         -- Threshold for general context sentences (default: 0.01, was: 0.05). Lower = more context sentences.
        lexrank_threshold_very_inclusive = 0.005, -- Threshold for fallback when not enough sentences found (default: 0.005, was: 0.02). Very low threshold.

        -- Term-specific context settings
        term_filter_context_window = 15, -- Sentences to capture around term mentions (default: 15, was: 5). Higher = more surrounding context.
        term_xray_min_sentences = 1600,  -- Target minimum sentences to extract (default: 1600, was: 150). Increase for more comprehensive coverage.
        term_xray_max_sentences = 2400,  -- Hard cap on sentences sent to LLM (default: 2400, was: 200). Provides ~40k input tokens for rich fantasy book analysis.

        -- These are prompts defined in `prompts.lua`, can be overriden here.
        -- each prompt shown as a button in the main dialog.
        -- The `order` determines the position in the main popup.
        -- The `show_on_main_popup` determines if the prompt is shown in the main popup
        -- The `show_on_dictionary_popup` determines if the prompt is shown in the dictionary popup ( max 3 including the built-in ones)
        -- Set `visible = false` to hide the prompt from all popups.
        -- Available placeholders to use in the prompts: {user_input},{highlight},{title},{author},{language},{progress}
        prompts = {

            -- hide some prompts to keep the UI clean
            -- simplify           = { visible = false, }, -- hide from everywhere

            --
            -- example of adding a custom prompt:
            -- myprompt = { text ="Prompt Title", system_prompt = "you are a helpful assistant.", user_prompt = "describe the following text in detail: {highlight}", order = 50, show_on_main_popup = true, },

        },

        book_level_prompts = {
            -- for an example of a custom book-level prompt, see: https://github.com/omer-faruq/assistant.koplugin/wiki/configuration#5-book-level-custom-prompts
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
