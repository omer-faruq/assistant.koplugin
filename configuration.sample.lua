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
            model = "gemini-2.0-flash-001", -- model list: https://ai.google.dev/gemini-api/docs/models/gemini , ex: gemini-1.5-pro-latest , gemini-2.0-flash-001
            base_url = "https://generativelanguage.googleapis.com/v1beta/models/",
            api_key = "your-gemini-api-key",
            additional_parameters = {
                temperature = 0.7,
                max_tokens = 4096,
                -- Set to 0 to disable thinking. Recommended for gemini-2.5-* and newer, where thinking is enabled by default.
                thinking_budget = nil
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
        dictionary_translate_to = "English", -- Default translation target; change if desired.
        response_language = nil, --  Nil means default to English; change to another language to localize all answers.
        hide_highlighted_text = false,  -- Set to true to hide the highlighted text at the top
        hide_long_highlights = true,    -- Hide highlighted text if longer than threshold
        long_highlight_threshold = 500,  -- Number of characters considered "long"
        max_display_user_prompt_length = 100,  -- Maximum number of characters of user_prompt to show in result window  (0 or nil for no limit)
        system_prompt = "You are a helpful assistant that provides clear explanations.", -- Custom system prompt for the AI ("Ask" button) to override the default, to disable set to nil
        refresh_screen_after_displaying_results = true, -- Set to true to refresh the screen after displaying the results
        show_dictionary_button_in_main_popup = true, -- Set to true to show the dictionary button in the main popup
        show_dictionary_button_in_dictionary_popup = true, -- Set to true to show the Dictionary (AI) button in the dictionary popup
        enable_AI_recap = true, -- Set to true to allow for a popup on a book you haven't read in a while to give you a quick AI recap
        render_markdown = true, -- Set to true to render markdown in the AI responses
        markdown_font_size = 20, -- Default normal text font size of rendered markdown.
        updater_disabled = false, -- Set to true to disable update check.

        -- AI Recap configuration
        recap_config = {
            system_prompt = "You are a book recap giver with entertaining tone and high quality detail with a focus on summarization. You also match the tone of the book provided.",
            user_prompt = [[
'''{title}''' by '''{author}''' that has been {progress}% read.
Given the above title and author of a book and the positional parameter, very briefly summarize the contents of the book prior with rich text formatting.
Above all else do not give any spoilers to the book, only consider prior content.
Focus on the more recent content rather than a general summary to help the user pick up where they left off.
Match the tone and energy of the book, for example if the book is funny match that style of humor and tone, if it's an exciting fantasy novel show it, if it's a historical or sad book reflect that.
Use text bolding to emphasize names and locations. Use italics to emphasize major plot points. No emojis or symbols.
Answer this whole response in {language} language. Only show the replies, do not give a description.]],
            language = "Turkish" -- Language for recap responses, uses dictionary_translate_to as fallback
        },

        -- Custom prompts for the AI (text = button text in the UI). system-prompt defaults to "You are a helpful assistant." if not set.
        -- Available placeholder for user prompts:
        -- {title}  : book title from metadata
        -- {author} : book author from metadata
        -- {highlight}  : selected texts
        -- {language}   : the `response_language` variable defined above
        prompts = {
            translate = {
                text = "Translate",
                order = 1,
                system_prompt = "You are a helpful translation assistant. Provide direct translations without additional commentary.",
                user_prompt = "Please translate the following text to {language}: {highlight}",
                show_on_main_popup = true -- Show the button in main popup
            },
            simplify = {
                text = "Simplify",
                order = 2,
                system_prompt = "You are a helpful assistant that provides clear explanations.",
                user_prompt = "Please simplify the following text in its own language: {highlight}",
                show_on_main_popup = false -- Show the button in main popup
            },
            explain = {
                text = "Explain",
                order = 3,
                system_prompt = "You are a helpful assistant that explains complex topics clearly and concisely. Break down concepts into simple terms.",
                user_prompt = "Please explain the following text: {highlight}",
                show_on_main_popup = false -- Show the button in main popup
            },
            summarize = {
                text = "Summarize",
                order = 4,
                system_prompt = "You are a summarization expert. Provide clear, concise summaries that capture the main points.",
                user_prompt = "Please provide a concise summary of the following text in its own language: {highlight}",
                show_on_main_popup = false -- Show the button in main popup
            },
            historical_context = {
                text = "Historical Context",
                order = 5,
                system_prompt = "You are a historical context expert. Provide relevant historical background and connections.",
                user_prompt = "Explain the historical context of this text: {highlight}",
                show_on_main_popup = false -- Show the button in main popup
            },
            key_points = {
                text = "Key Points",
                order = 6,
                system_prompt = "You are a key points expert. Provide a concise list of key points from the text.",
                user_prompt = "Please provide a concise list in markdown format of key points from the following text: {highlight}",
                show_on_main_popup = false -- Show the button in main popup
            },
            ELI5 = {
                text = "ELI5",
                order = 7,
                system_prompt = "You are an ELI5 expert. Provide simple, concise explanations for complex terms.",
                user_prompt = "Please provide an ELI5 explanation: {highlight}",
                show_on_main_popup = false -- Show the button in main popup
            },
            grammar = {
                text = "Grammar",
                order = 8,
                system_prompt = "You are a grammar expert.",
                user_prompt = "Explain the grammar of the following text: {highlight}",
                show_on_main_popup = true -- Show the button in main popup
            },
            vocabulary = {
                text = "Vocabulary",
                order = 9,
                system_prompt = "You are a vocabulary expert.",
                user_prompt = [[**Your Task:** Analyze the Input Text below. Find words/phrases that are B2 level or higher. Ignore common words (B1 level) and proper nouns.

                                **Output Requirements:**
                                1.  For each difficult word/phrase found:
                                    *   Correct any typos.
                                    *   Convert it to its base form (e.g., "go", "dog", "good", "kick the bucket").
                                    *   List up to 3 simple synonyms (suitable for B1+ learners). Do not reuse the original word.
                                    *   Explain its meaning simply **in English**, considering its context in the text. Do not reuse the original word in the explanation.
                                2.  **Format:** Create a numbered list using this exact structure for each item:
                                    `index. base_form : synonym1, synonym2, synonym3 : English_explanation`
                                3.  **Output Content:** **ONLY** provide the numbered list. Do not include the original text, titles, or any extra sentences.

                                **Input Text:** {highlight} ]], 
                show_on_main_popup = false -- Show the button in main popup
            },
            wikipedia = {
                text = "Wikipedia",
                order = 10,
                system_prompt = "You are an informative assistant that provides wikipedia articles.",
                user_prompt = "I want you to act as a Wikipedia page. I will give you the name of a topic, and you will provide a summary of that topic in the format of a Wikipedia page. Your summary should be informative and factual, covering the most important aspects of the topic. Start your summary with an introductory paragraph that gives an overview of the topic. I prefer the answer in {language}. My first topic is {highlight}",
                show_on_main_popup = false -- Show the button in main popup
            }
        }
    }
}

return CONFIGURATION
