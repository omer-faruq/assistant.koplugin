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
  - DeepSeek (not tested)
  - Ollama
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

## Basic Requirements

- [KoReader](https://github.com/koreader/koreader) installed on your device
- API key from your preferred provider (Anthropic, OpenAI, Gemini, OpenRouter, DeepSeek, Ollama, etc.)

## Getting Started 

### 1. Get API Keys

You'll need API keys for the AI service you want to use:

**For Claude/Anthropic**:
1. Go to [console.anthropic.com](https://console.anthropic.com)
2. Sign up for an account or login to your existing account
3. Go to "API Keys" and create a new key

**For OpenAI**:
1. Visit [platform.openai.com](https://platform.openai.com)
2. Create an account or login to your existing account
3. Go to "API Keys" section and create a new key

**For Gemini**:
1. Visit [aistudio.google.com](https://aistudio.google.com/)
2. Create an account or login to your existing account
3. Go to ["Get Api Key"](https://aistudio.google.com/app/apikey) section and create a new key

**For OpenRouter**:
1. Visit [openrouter.ai/](https://openrouter.ai)
2. Create an account or login to your existing account
3. Go to [API Keys](https://openrouter.ai/settings/keys) section and create a new key

**For DeepSeek**:
1. Visit [platform.deepseek.com](https://platform.deepseek.com)
2. Create an account or login to your existing account
3. Go to "API Keys" section and create a new key

**For Ollama**:
1. Ollama doesn't use an API key. However, a placeholder API key value (ex: "ollama") is required.

### 2. Installation:
#### Using The Latest Version:
1. Clone the repository
2. Rename the directory as  `assistant.koplugin` and copy it to your KOReader plugins directory:
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
   - PocketBook: `applications/koreader/plugins/`
   - Android: `koreader/plugins/`
3. Create/modify `configuration.lua` as needed.

#### Using A Stable Release:
1. Download a [release](https://www.github.com/omer-faruq/assistant.koplugin/releases) from GitHub 
2. Extract `assistant.koplugin` to your KOReader plugins directory:
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
   - PocketBook: `applications/koreader/plugins/`
   - Android: `koreader/plugins/`
3. Create/modify `configuration.lua` as needed.

### 3. Configure the Plugin

1. Copy `configuration.lua.sample` to `configuration.lua` ( do not modify the sample file)
2. Edit the `configuration.lua` file as needed.
    - Set the chosen AI provider in `provider`
    - Set your API keys in `provider_settings` 
    - Make sure the file has the correct language written in `features` part.(Initially set to "Turkish")    

#### Advanced Configuration:

The plugin supports extensive customization through `configuration.lua`. See the [sample file](https://raw.githubusercontent.com/omer-faruq/assistant.koplugin/refs/heads/main/configuration.lua.sample) for all options:

- Multiple AI providers with different settings
- Display preferences
    - Hide highlighted text at the top
    - Show/Hide dictionary button in Asistant Menu: give dictionary_translate_to = nil to hide it
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
    
    -- Provider-specific settings (override defaults in api_handlers/defaults.lua)
    provider_settings = {
        AI_ID = {
            model = "api-model",
            base_url = "URL_to_API",
            api_key = "your-api-key", -- set your api key here
            additional_parameters = {
              --.. other parameters
            }
        },  
        -- ... other AI providers
    },
    
    -- Optional features, replace each "Turkish" with your desired language
    features = {
        hide_highlighted_text = false,  -- Set to true to hide the highlighted text at the top
        hide_long_highlights = true,    -- Hide highlighted text if longer than threshold
        long_highlight_threshold = 500,  -- Number of characters considered "long",
        system_prompt = "You are a helpful assistant that provides clear explanations and if not stated oterwise always answers in Turkish .", -- Custom system prompt for the AI ("Ask" button) to override the default, to disable set to nil
        refresh_screen_after_displaying_results = true, -- Set to true to refresh the screen after displaying the results
        show_dictionary_button_in_main_popup = true, -- Set to true to show the dictionary button in the main popup
        dictionary_translate_to = "tr-TR", -- Set to the desired language code for the dictionary, nil to hide it

        -- AI Recap configuration (optional)
        recap_config = {
            system_prompt = "You are a book recap giver with entertaining tone...", -- Custom system prompt for recap
            user_prompt = "{title} by {author} that has been {progress}% read...", -- Custom user prompt template with variables
            language = "tr-TR" -- Language for recap responses, uses dictionary_translate_to as fallback
        },

        -- Custom prompts for the AI (text = button text in the UI). system-prompt defaults to "You are a helpful assistant." if not set.
        prompts = {
            prompt_id = {
                text = "prompt_name",
                order = 1, -- give order to buttons to fix the order of them
                system_prompt = "You are a helpful assistant that ....",
                user_prompt = "Please ...  in Turkish: ",
                show_on_main_popup = false -- Show the button in main popup    
            },
            -- ... other prompts
        }
    }
}

return CONFIGURATION
```

### 4. Using the Plugin

1. Open any book in KOReader
2. Highlight text you want to analyze
3. Tap the highlight and select "Assistant"
4. Choose an action:
   - **Ask**: Ask a specific question about the text
   - **Custom Actions**: Use any prompts you've configured
       - **Translate**: Convert text to your configured language
5. **Additional Questions**: Ask additional questions about the highlighted text using your custom prompts

### Tips

- Use **Long-tap** (tap & hold for 3 secs) on a single word to popup the highlight menu
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
