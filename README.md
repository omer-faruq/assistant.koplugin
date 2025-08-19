# Assistant: AI Helper Plugin for KOReader
<!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->
[![All Contributors](https://img.shields.io/badge/all_contributors-1-orange.svg?style=flat-square)](#contributors-)
<!-- ALL-CONTRIBUTORS-BADGE:END -->

A powerful plugin that lets you interact with AI language models (Claude, GPT-4, Gemini, DeepSeek, Ollama etc.) while reading. Ask questions about text, get translations, summaries, explanations and more - all without leaving your book.

<small>Originally forked from deleted fork of  [zeeyado](https://github.com/zeeyado)  of [AskGPT](https://github.com/drewbaumann/askgpt),then modified using WindSurf.</small>

## Features

- **Ask Questions**: Highlight text and ask questions about it
- **Multiple AI Providers**: Support for:
  - Anthropic's Claude 
  - OpenAI's GPT models
  - Gemini
  - OpenRouter: unified interface for LLMs
  - DeepSeek
  - Ollama
  - Other OpenAI compatible API services (grok, nvidia ...)
- **Builtin Prompts**:
  - **Dictionary** : Get synonyms, context-aware dictionary explanation and example for the selected word. (thanks to [plateaukao](https://github.com/plateaukao))
  - **Recap** : Get a quick recap of a book when you open it, for books that haven't been opened in 28 hrs and <95% complete. Also available via shortcut/gesture for on-demand access. Fully configurable prompts. (thanks to [jbhul](https://github.com/jbhul))
- **Custom Prompts**: Create your own specialized AI helpers with their own quick actions and prompts
  - **Translation**: Instantly translate highlighted text to any language
  - **Quick Actions**: One-click buttons for common tasks like summarizing or explaining
- **Additional Questions** : Ask addtional questions about the highlighted text using your custom prompts
- **Smart Display**: Automatically hides long text snippets for cleaner viewing
  - **Markdown Support**: (thanks to [David Fan](https://github.com/d-fan))

- **"Add to Note" and "Copy to Clipboard"**: Easily add whole dialog as a note to highlighted text or copy to use for later.
- **Quick Access** : Ability to access some of custom prompts directly from the main highlight menu (Configurable).
- **Gesture-Enabled Prompts**: You can assign gestures to **Ask** and **Recap**. This enables the user to ask anything about the book without needing to highlight text first. It also enables triggering the recap at any time. Additionally, you can access these prompts through a [quick menu](https://koreader.rocks/user_guide/#L1-qmandprofiles) as well. (thanks to [Jayphen](https://github.com/Jayphen))
- **AI Dictionary Gesture**: Override the default "Translate" long-press gesture to use the AI Dictionary directly for instant definitions and context.

## Basic Requirements

- [KoReader](https://github.com/koreader/koreader) installed on your device
- API key from your preferred provider (Anthropic, OpenAI, Gemini, OpenRouter, DeepSeek, Ollama, etc.)

## Getting Started 

### 1. Get API Keys

You'll need API keys for the AI service you want to use:

1. Select one of the services listed below, 
1. Sign up and login.
1. create an API key as their web page instructed.

| Platform API Key Pages                                            | Notes                                                     |
| ----------------------------------------------------------------- | --------------------------------------------------------- |
| [OpenAI](https://platform.openai.com/api-keys)                    | ChatGPT.                                                  |
| [Gemini](https://aistudio.google.com/app/apikey)                  | Google's AI.                                              |
| [Claude / Anthropic](https://console.anthropic.com/settings/keys) | AI for complex reasoning and conversation.                |
| [DeepSeek](https://platform.deepseek.com/api_keys)                | Multilingual AI, major in Chinese.                        |
| [Groq](https://console.groq.com/keys)                             | Ultra-fast AI for real-time use.                          |
| [Mistral AI](https://console.mistral.ai/api-keys)                 | Efficient and accurate AI models.                         |
| Ollama                                                            | Local AI models. use placeholder value.<br>(ex: `ollama`) |

### 2. Installation:

#### 2.1. Download the plugin

Choose one of the following:

*   **Stable Release:**
    1.  Download a [release](https://www.github.com/omer-faruq/assistant.koplugin/releases) from GitHub.
        - Choose the `assistant.koplugin-VERSION.zip` file, not the Source code.
    2.  Extract the `assistant.koplugin` directory from the downloaded archive.
*   **Developing Version:**
    1.  Download the [source code](https://github.com/omer-faruq/assistant.koplugin/archive/refs/heads/main.zip) as a zip file.
    2.  Extract, and rename the directory from `assistant.koplugin-main` to `assistant.koplugin`.

#### 2.2. Move `assistant.koplugin` to the platform-specific folder

Copy the `assistant.koplugin` directory (obtained from step 2.1) to your KOReader plugins directory. The location depends on your device:

*   **Kobo:** `.adds/koreader/plugins/`
*   **Kindle:** `koreader/plugins/`
*   **PocketBook:** `applications/koreader/plugins/`
*   **Android:** `koreader/plugins/`
*   **Mac:** `~/Library/Application Support/koreader/plugins/`

#### 2.3. Create/modify configuration.lua as needed

### 3. Configure the Plugin

1. Copy `configuration.sample.lua` to `configuration.lua` ( do not modify the sample file)
2. Edit the `configuration.lua` file as needed.
    - Set the chosen AI provider in `provider`
    - Set your API keys in `provider_settings` 
    - Make sure the file has the correct language written in `features` part.(Initially set to "Turkish")    

#### Advanced Configuration:

The plugin supports extensive customization through `configuration.lua`. See the [sample file](https://raw.githubusercontent.com/omer-faruq/assistant.koplugin/refs/heads/main/configuration.sample.lua) for all options:

- Multiple AI providers with different settings
    - An underscore in `provider` means to use the first part as the handler, various profiles for each API.
    - TODO: Switch different model profile in UI (not implemented yet).
- Display preferences
    - Hide highlighted text at the top
    - Show/Hide dictionary button in Asistant Menu: give `dictionary_translate_to = nil` to hide it
    - Show/Hide dictionary button in main popup
    - Refresh screen after displaying results
- Custom button actions
    - Adjust order of custom buttons
    - Make some custom buttons display on the main popup

Configuration file has this structure:
```lua
local CONFIGURATION = {
    -- Choose your preferred AI provider: "anthropic", "openai", "gemini", "openrouter", "deepseek" or "ollama"
    provider = "openai",
    -- or 
    provider = "openai_grok", -- latter one is in effective
    -- or you can choose one in the Model Provider Switch
    
    -- Provider-specific settings (override defaults in api_handlers/defaults.lua)
    provider_settings = {
        openai = {
            default = true, -- optional, if provider is not set, will try to find the one with `default =  true`
            visible = true, -- optional, if set to false, will not shown in the profile switch
            model = "api-model",
            base_url = "URL_to_API",
            api_key = "your-api-key", -- set your api key here
            additional_parameters = {
              --.. other parameters
            }
        },  
        openai_grok = { -- using same openai handler for compatible API, eg grok
            model = "grok-3-mini-fast", -- see: https://x.ai/api
            base_url = "https://api.x.ai/v1/chat/completions",
            api_key = "your-grok-api-key", -- set your api key here
        },
        -- ... other AI providers
    },
    
    -- Optional features
    features = {
        response_language = "Turkish", --  Set language for the other responses, nil to English response. 
        -- dictionary_translate_to = "German", -- if you want the language of the dictionary to be different from the response language, set it here.
        hide_highlighted_text = false,  -- Set to true to hide the highlighted text at the top
        hide_long_highlights = true,    -- Hide highlighted text if longer than threshold
        long_highlight_threshold = 500,  -- Number of characters considered "long"
        max_display_user_prompt_length = 100,  -- Maximum number of characters of user_prompt to show in result window  (0 or nil for no limit)
        system_prompt = "You are a helpful assistant that provides clear explanations.", -- Custom system prompt for the AI ("Ask" button) to override the default, to disable set to nil
        show_dictionary_button_in_dictionary_popup = true, -- Set to true to show the Dictionary (AI) button in the dictionary popup
        enable_AI_recap = true, -- Set to true to allow for a popup on a book you haven't read in a while to give you a quick AI recap
        render_markdown = true, -- Set to true to render markdown in the AI responses
        markdown_font_size = 20, -- Default normal text font size of rendered markdown.
        updater_disabled = false, -- Set to true to disable update check.
        auto_copy_asked_question  = true, --Set true to automatically copy the question you send using "Ask" button

        -- AI Recap configuration (optional)
        recap_config = {
            system_prompt = "You are a book recap giver with entertaining tone...", -- Custom system prompt for recap
            user_prompt = "{title} by {author} that has been {progress}% read...", -- Custom user prompt template with variables
            language = "Turkish" -- Language for recap responses, uses dictionary_translate_to as fallback
        },

        -- Custom prompts for the AI (text = button text in the UI). system-prompt defaults to "You are a helpful assistant." if not set.
        -- Available placeholder for user prompts:
        -- {title}  : book title from metadata
        -- {author} : book author from metadata
        -- {highlight}  : selected texts
        -- {language}   : the `response_language` variable defined above
        prompts = {
            prompt_id = {
                text = "prompt_name",
                order = 1, -- give order to buttons to fix the order of them
                system_prompt = "You are a helpful assistant that ....",
                user_prompt = "Please ...  in {language}: ",
            },
            -- ... other prompts
        }
    }
}

return CONFIGURATION
```

### 4. Using the Plugin

#### Standard Usage

1. Open any book in KOReader
2. Highlight text you want to analyze
3. Tap the highlight and select "Assistant"
4. Choose an action:
   - **Ask**: Ask a specific question about the text
   - **Custom Actions**: Use any prompts you've configured
       - **Translate**: Convert text to your configured language
5. **Additional Questions**: Ask additional questions about the highlighted text using your custom prompts

#### Using AI Dictionary with Gestures

You can set up a long-press gesture to open the AI Dictionary instantly, bypassing the highlight menu. This is done by overriding KOReader's built-in "Translate" action. (thanks to [Ilia Reutov](https://github.com/Agnesor))

1.  **Enable the Override**:
    *   Navigate to the top menu `Tools (🔧) > More tools`.
    *   Find and enable **Use AI Dictionary for 'Translate'**.

2.  **Set the Gesture**:
    *   Go to KOReader's main menu -> `Taps and gestures` -> `Gesture manager`.
    *   Select `Long-press on text`.
    *   Choose **"Translate"** from the list of actions.

Now, when you long-press a word, the AI Dictionary will open directly. To use the standard translation feature again, simply uncheck the override option in the Assistant plugin's menu.

### Tips

- Use **Long-tap** (tap & hold for 3+ secs) on a single word to popup the highlight menu
- Use **Select** button on the highlight menu to use text from multiple pages
- Draw a multiswipe to **CLOSE** the dialog (eg: swipe ⮠  or ⮡  or circle ↺)
- Keep highlights reasonably sized for best results
- Use **"Ask"** for specific questions about the text
- Try the pre-made buttons for quick analysis
- Add your own custom prompts for specialized tasks

## Contributors ✨

Thanks goes to these wonderful people ([emoji key](https://allcontributors.org/docs/en/emoji-key)):

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/boypt"><img src="https://avatars.githubusercontent.com/u/1033514?v=4?s=100" width="100px;" alt="BEN"/><br /><sub><b>BEN</b></sub></a><br /><a href="https://github.com/omer-faruq/assistant.koplugin/commits?author=boypt" title="Code">💻</a></td>
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

This project follows the [all-contributors](https://github.com/all-contributors/all-contributors) specification. Contributions of any kind welcome!
