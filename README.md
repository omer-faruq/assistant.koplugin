# Assistant: AI Helper Plugin for KOReader
<!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->
[![All Contributors](https://img.shields.io/badge/all_contributors-1-orange.svg?style=flat-square)](#contributors-)
<!-- ALL-CONTRIBUTORS-BADGE:END -->
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/omer-faruq/assistant.koplugin)

A powerful plugin that lets you interact with AI language models (Claude, GPT-4, Gemini, DeepSeek, Ollama etc.) while reading. Ask questions about text, get translations, summaries, explanations and more - all without leaving your book.

<small>Originally forked from a deleted fork of AskGPT by zeeyado, then modified using WindSurf. That fork is now public and includes many updates: https://github.com/zeeyado/koassistant.koplugin </small>

## Features

- **Multiple AI Providers**: Support for:
  - Claude, OpenAI, Gemini, DeepSeek, etc.
  - OpenRouter, Ollama, etc.
  - Other OpenAI-compatible API services (Groq, NVIDIA, etc.)
- **Stream Mode**: Real-time responses from the API. Get the full LLM experience on e-ink devices.
- **Multiple Providers/Models**: Select different models or AI provider platforms in the UI.
- **Web Search Tool Calling**: LLMs search the web and improve the the answer with real and updated infomation.
- **Built-in Prompts**:
  - **Translation**: Instantly translate highlighted text to any language
  - **Quick Actions**: One-click buttons for common tasks like summarizing or explaining
  - **Dictionary**: Get synonyms, context-aware dictionary explanations, and examples for the selected word. (thanks to [plateaukao](https://github.com/plateaukao))
  - **Term X-Ray**: For single word or phrase highlights, get the meaning of it based on the previously mentioned places. (thanks to [Michael Kucek](https://github.com/michael-kucek))
  - **Recap**: Get a quick recap of a book when you open it, for books that haven't been opened in 28 hours and are less than 95% complete. Also available via shortcut/gesture for on-demand access. Fully configurable prompts. (thanks to [jbhul](https://github.com/jbhul))
  - **X-Ray**: Generate a spoiler-free, structured book X-Ray up to your current progress, listing key characters, locations, themes, terms, a concise timeline, and a quick re-immersion section. Fully configurable prompts; available via shortcut/gesture.
- **Custom Prompts**: Create your own specialized AI helpers with their own quick actions and prompts. Possible for highlighted text and book-level.
- **Smart Display**: Automatically hides long text snippets for cleaner viewing
- **Markdown Support**: (thanks to [David Fan](https://github.com/d-fan))
- **"Add to Note" and "Copy to Clipboard"**: Easily add the entire response as a note to highlighted text or copy it for later use.
- **Quick Access**: Ability to access some custom prompts directly from the main highlight menu (configurable).
- **Gesture-Enabled Prompts**: You can assign gestures to **Ask**, **Recap**, and **X-Ray**. This enables the user to ask anything about the book without needing to highlight text first. It also enables triggering the recap at any time. Additionally, you can access these prompts through a [quick menu](https://koreader.rocks/user_guide/#L1-qmandprofiles) as well. (thanks to [Jayphen](https://github.com/Jayphen))
- **AI Dictionary Gesture**: Override the default "Translate" long-press gesture to use the AI Dictionary directly for instant definitions and context.
- **l10n Support**: Supports all languages that the KOReader project supports.

## Basic Requirements

- [KOReader](https://github.com/koreader/koreader) installed on your device
- API key from a LLM provider (Anthropic, OpenAI, Gemini, OpenRouter, DeepSeek, Ollama, etc.)
- (Optional) API key from a search api provider (Tavily, SerpAPI, SearXNG ...)

## Getting Started 

### 1. Get API Keys

See [Obtaining API Keys](../../wiki/Obtaining-API-Keys) from the wiki page.

### 2. Installation:

[Installation Guide](../../wiki/Installation)

Create/modify `configuration.lua` as needed.

### 3. Configure the Plugin

1. Copy `configuration.sample.lua` to `configuration.lua` (do not modify the sample file directly).
2. Edit the `configuration.lua` file as needed.
    - Set your API keys in `provider_settings`.
    - For more advanced configuration, see the Wiki Configuration.lua.

#### Using OpenAI-Compatible APIs

The plugin supports any OpenAI-compatible API through a flexible naming pattern. Configuration keys follow the format `{handler}_{description}`, where:
- **handler**: The API handler to use (e.g., `openai`, `anthropic`, `gemini`)
- **description**: Any descriptive name for your configuration (e.g., `perplexity`, `grok`, `local`)

**Examples:**
- `openai_perplexity` → uses the `openai` handler for Perplexity API
- `openai_grok` → uses the `openai` handler for Grok API
- `anthropic_websearch` → uses the `anthropic` handler with web search enabled

You can create multiple configurations using the same handler with different settings. The part before the first underscore determines which handler is used.

Here's the minimum working example:

```lua
local CONFIGURATION = {

    provider_settings = {
        gemini = {
            model = "gemini-2.5-flash",
            base_url = "https://generativelanguage.googleapis.com/v1beta/models/",
            api_key = "your-gemini-api-key",
        },
        -- You can add other providers here, for example:
        -- openai = {
        --     model = "gpt-4o-mini",
        --     base_url = "https://api.openai.com/v1/chat/completions",
        --     api_key = "your-openai-api-key",
        -- }
    }
}
return CONFIGURATION
```

### 4. Using the Plugin

#### Standard Usage

1. Open any book in KOReader
2. Highlight the text you want to analyze
3. Tap the highlight and select "AI Assistant"
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

#### Dictionary Popup Buttons

The Assistant plugin adds AI-powered buttons (Wikipedia, Term X-Ray, Dictionary, and custom prompts) to the dictionary popup when you look up words.

**Note**: In newer KOReader versions (2026.05+), dictionary popup buttons can be customized via **Dictionary settings → Customize buttons → Max buttons in row**. Increase this value to display multiple plugin buttons on the same row.

### Tips

- Use **Long-tap** (tap & hold for 3+ secs) on a single word to pop up the highlight menu
- **Long press** :
  - On the "AI Assistant" main button to see the **settings** and **reset** buttons
  - On a prompt button to **add** it to the main highlight menu.
  - On a button in the main highlight menu to **remove** it.
  - On the close button in the result window to instantly **close all dialogs** and return directly to your reading experience
- Use the **Select** button on the highlight menu to use text from multiple pages
- Draw a multiswipe to **CLOSE** the dialog (eg: swipe ⮠  or ⮡  or circle ↺)
- Keep highlights reasonably sized for best results
- Use **"Ask"** for specific questions about the text
- Try the pre-made buttons for quick analysis
- Add your own custom prompts for specialized tasks

## Contributors ✨

<a href="https://github.com/omer-faruq/assistant.koplugin/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=omer-faruq/assistant.koplugin" />
</a>

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
