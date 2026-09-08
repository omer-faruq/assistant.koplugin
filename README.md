# Assistant: AI Helper Plugin for KOReader
<!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->
[![All Contributors](https://img.shields.io/badge/all_contributors-1-orange.svg?style=flat-square)](#contributors-)
<!-- ALL-CONTRIBUTORS-BADGE:END -->
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/omer-faruq/assistant.koplugin)

A powerful plugin that lets you interact with AI language models (Claude, GPT-4, Gemini, DeepSeek, Ollama etc.) while reading. Ask questions about text, get translations, summaries, explanations and more - all without leaving your book.

<small>Originally forked from a deleted fork of AskGPT by zeeyado, then modified using WindSurf. That fork is now public and includes many updates: https://github.com/zeeyado/koassistant.koplugin </small>

## Features

- **Multiple AI Providers**: Speaks the mainstream protocols natively — OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, and Google Gemini — so most platforms work out of the box. Examples:
  - OpenAI, DeepSeek, OpenRouter, Ollama, Groq, Mistral, NVIDIA, etc. (via OpenAI-compatible endpoints)
  - Claude (Anthropic), Gemini, and the OpenAI Responses API
- **Stream Mode**: Real-time responses from the API. Get the full LLM experience on e-ink devices.
- **Multiple Providers/Models**: Select different models or AI provider platforms in the UI.
- **UI-Based Setup**: Add providers and models entirely from the UI, with built-in model browsing and connection testing.
- **Web Search**: Let LLMs search the web for real and up-to-date information. Supports SerpAPI, Tavily, Exa, and SearXNG, with a per-question toggle.
- **Built-in Prompts**:
  - **Translation**: Instantly translate highlighted text to any language
  - **Quick Actions**: One-click buttons for common tasks like summarizing or explaining
  - **Dictionary**: Get book-aware explanations — meaning, synonyms, and usage in the current book. (thanks to [plateaukao](https://github.com/plateaukao))
  - **Term X-Ray**: For single word or phrase highlights, get the meaning of it based on the previously mentioned places. (thanks to [Michael Kucek](https://github.com/michael-kucek))
  - **Recap**: Catch up on a book you haven't opened for a while. (thanks to [jbhul](https://github.com/jbhul))
  - **X-Ray**: A spoiler-free guide to characters, places, themes, and timeline up to your progress.
- **Markdown Support**: (thanks to [David Fan](https://github.com/d-fan))
- **Notebook & Quick Notes**: Save AI conversations and quick notes as Markdown, either to the current book or a general notebook, with optional auto-save.
- **Highlight Menu Presets**: Pin built-in prompts to the highlight popup for one-tap access (configurable).
- **Book Insights**: Explore the whole book without highlighting — Book Summary & Recs, AI X-Ray, AI Recaps, and analysis or summaries built from your highlights and notes.
- **Gesture Shortcuts**: Trigger Ask, Recap, and X-Ray by gesture, no highlighting needed. (thanks to [Jayphen](https://github.com/Jayphen))
- **AI Dictionary**: Get book-aware definitions and synonyms for any word or phrase, based on the book you are reading.
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

### 3. Configure the Plugin

All setup can be done directly from the KOReader UI.

#### Option A: Configure from the UI

**Providers:**

1. Go to `⚙ → AI Assistant → Settings → Provider API` and choose a preset (e.g. OpenAI, Gemini, Anthropic, DeepSeek, OpenRouter). For any other OpenAI-compatible endpoint, start from the `OpenAI` preset and update the URL.
2. Fill in the dialog:
   - **Provider Name** — the label shown in menus
   - **Base URL** — pre-filled by the preset, editable
   - **API Key** — your provider key
   - **Model** — type it manually, or tap **Browse Models** to fetch the list online and pick one
3. Tap **Test** to check the connection, then **OK** to save. The new provider becomes active right away.
4. To switch providers later, go to `⚙ → AI Assistant → Settings → Providers and Models` and select one. Only providers added from the UI can be edited or deleted.

**Web search keys (SerpAPI / Tavily / Exa / SearXNG):** available both via UI configuration (`Settings → WebSearch API`) and via the configuration file. In the Ask dialog, use the `🌐 Web Search` checkbox to enable it per question.

#### Option B (Advanced): Use `configuration.lua`

For file-based setup (naming pattern, multiple profiles, extra examples), see [Installation](../../wiki/Installation).

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

#### Using AI Translate with Gestures

You can set up a long-press gesture to translate instantly, bypassing the highlight menu. This is done by overriding KOReader's built-in "Translate" action. (thanks to [Ilia Reutov](https://github.com/Agnesor))

1.  **Enable the Override**:
    *   Navigate to the top menu `Tools (🔧) > More tools`.
    *   Find and enable **Use AI Assistant for 'Translate'**.

2.  **Set the Gesture**:
    *   Go to KOReader's main menu -> `Taps and gestures` -> `Gesture manager`.
    *   Select `Long-press on text`.
    *   Choose **"Translate"** from the list of actions.

Now, when you long-press a word, the AI translates it directly. To use the standard translation service again, simply uncheck the override option in the Assistant plugin's menu.

#### Dictionary Output

Choose what the AI Dictionary returns under **Dictionary Settings**: **Standard** or **Full** presets, a **Concise** toggle for shorter answers, and per-section toggles (meaning, synonyms, translation, word form, examples, origin).

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
- **Entering API keys on e-ink**: save the key in a `.txt` file, send it to your reader, open it as a book, copy the key, then long-press the API Key field and paste.
- **Entering very long URLs**: save the provider with a short placeholder URL first, then reopen it with **Edit** and replace it with the full URL.

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
