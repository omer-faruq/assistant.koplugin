local CONFIGURATION = {
    -- Choose your preferred AI provider: "anthropic", "openai", "gemini", ...
    -- use one of the settings defined in provider_settings below.
    -- NOTE: "openai" , "openai_grok" are different service using same handling code.
    provider = "openai",

    -- Provider-specific settings
    provider_settings = {
        openai = {
            defalut = true, -- optional, if provider above is not set, will try to find one with `defalut =  true`
            visible = true, -- optional, if set to false, will not shown in the provider switch
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
            visible = true, -- optional, if set to false, will not shown in the profile switch
            model = "claude-3-5-haiku-latest", -- model list: https://docs.anthropic.com/en/docs/about-claude/models
            base_url = "https://api.anthropic.com/v1/messages",
            api_key = "your-anthropic-api-key",
            additional_parameters = {
                anthropic_version = "2023-06-01", -- api version list: https://docs.anthropic.com/en/api/versioning
                max_tokens = 4096
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
            model = "your-preferred-model", -- model list: https://ollama.com/library
            base_url = "your-ollama-api-endpoint", -- ex: "https://ollama.example.com/api/chat"
            api_key = "ollama",
            additional_parameters = { }
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
            deployment_name = "your-deployment-name", -- Your model deployment name
            api_version = "2024-02-15-preview", -- Azure OpenAI API version
            api_key = "your-azure-api-key", -- Your Azure OpenAI API key
            temperature = 0.7,
            max_tokens = 4096
        },
    },

    -- Optional features 
    features = {
        hide_highlighted_text = false,  -- Set to true to hide the highlighted text at the top
        hide_long_highlights = true,    -- Hide highlighted text if longer than threshold
        long_highlight_threshold = 500,  -- Number of characters considered "long"
        -- system_prompt = "You are a helpful AI assistant. Always respond in Markdown format.", -- Custom system prompt for the AI ("Ask" button) to override the default, to disable set to nil
        render_markdown = true, -- Set to true to render markdown in the AI responses
        updater_disabled = false, -- Set to true to disable update check.
        default_folder_for_logs = nil, -- Set the default folder for auto saved logs, nil for the same folder as the book, ex: "/mnt/onboard/logs/" for Kobo , "/mnt/us/documents/logs/" for Kindle
        max_text_length_for_analysis = 100000, -- max text lenght to be used on xray-recap-book analyzes, 
        max_page_size_for_analysis =250, --maximum page size to be used on xray-recap-book analyzes (for page-based documents, ex: PDF)

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

        -- AI Recap configuration
        -- If you want to override the default prompts, you can uncomment and modify the following lines:
        -- recap_config = {
        --   system_prompt = "",
        --   user_prompt = ""
        -- },
    }
}

return CONFIGURATION
