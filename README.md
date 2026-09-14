# Assistant: AI Helper Plugin for KOReader
<!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->
[![All Contributors](https://img.shields.io/badge/all_contributors-1-orange.svg?style=flat-square)](#contributors-)
<!-- ALL-CONTRIBUTORS-BADGE:END -->
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/omer-faruq/assistant.koplugin)

Interact with AI language models while reading. Ask questions, get translations, summaries, explanations and more - all without leaving your book.

<small>Originally forked from a deleted fork of AskGPT by zeeyado, then modified using WindSurf. That fork is now public and includes many updates: https://github.com/zeeyado/koassistant.koplugin </small>

## Features

- **Multiple AI Providers**: Natively speaks the four mainstream protocols — OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, and Google Gemini — so popular platforms such as DeepSeek, OpenRouter, Ollama, Groq, and Mistral work out of the box.
- **Stream Mode**: Real-time responses from the API. Get the full LLM experience on e-ink devices.
- **Web Search**: Let LLMs search the web for real and up-to-date information. Supports SerpAPI, Tavily, Exa, and SearXNG, with a per-question toggle.
- **UI-Based Setup**: Add providers and models entirely from the UI, with built-in model browsing and connection testing.
- **Built-in Prompts** (from the highlight menu):
  - **Translation**: Instantly translate highlighted text to any language.
  - **Quick Actions**: One-click buttons for common tasks like summarizing, simplifying, or explaining.
  - **Dictionary**: Get book-aware explanations — meaning, synonyms, and usage in the current book. (thanks to [plateaukao](https://github.com/plateaukao))
  - **Term X-Ray**: Explain a highlighted word or phrase using its earlier mentions in the book. (thanks to [Michael Kucek](https://github.com/michael-kucek))
- **Notebook & Quick Notes**: Save AI conversations and quick notes as Markdown, either to the book's notebook or to a general notebook — with optional auto-save and multiple general notebooks to organize your logs.
- **Highlight Menu Presets**: Pin built-in prompts to the highlight popup for one-tap access (configurable).
- **Book Insights** (whole-book features, no highlight needed):
  - **Book Summary & Recs**: Summary, author biography, historical context, and similar book recommendations.
  - **X-Ray**: A spoiler-free guide to characters, places, themes, and timeline up to your progress.
  - **Recap**: Catch up on a book you haven't opened for a while. (thanks to [jbhul](https://github.com/jbhul))
  - **Highlight & Note Analysis**: Analysis of your highlights and notes from the book.
  - **Summary Using Highlights & Notes**: A book summary built from your highlights and notes.
- **Gesture Shortcuts**: Trigger Ask, Recap, and X-Ray by gesture, no highlighting needed. (thanks to [Jayphen](https://github.com/Jayphen))
- **AI Dictionary**: Get book-aware definitions and synonyms for any word or phrase.
- **l10n Support**: Supports every language available in KOReader.

## Basic Requirements

- **[Required]** [KOReader](https://github.com/koreader/koreader) installed on your device
- **[Required]** API key from at least one LLM provider
- **[Recommended]** API key from a search provider (Tavily, SerpAPI, Exa, SearXNG, ...)

## Getting Started 

### 1. Get API Keys

See [Obtaining API Keys](../../wiki/Obtaining-API-Keys) from the wiki page.

### 2. Installation:

[Installation Guide](../../wiki/Installation)

### 3. Configure the Plugin

All setup is done directly from the KOReader UI.

#### Before You Start: Get the API Key onto the Reader

Typing a long API key on an e-ink keyboard is painful. The easy path:

1. Save your API key in a `.txt` file on your computer.
2. Send that file to your reader (USB, cloud, etc.).
3. Open the `.txt` file as a book in KOReader.
4. Copy the key to the clipboard.
5. Then follow the configuration below and paste it into the API Key field.

#### Option A: Configure from the UI

**Providers:**

1. Go to `⚙ → AI Assistant → Settings → Provider API` and choose the preset matching your platform. For any other OpenAI-compatible endpoint, start from the `OpenAI` preset and update the URL.
2. Fill in the dialog:
   - **Provider Name** — the label shown in menus
   - **Base URL** — pre-filled by the preset, editable
   - **API Key** — your provider key
   - **Model** — type it manually, or tap **Browse Models** to fetch the list online and pick one
3. Tap **Test** to check the connection, then **OK** to save. The new provider becomes active right away.
4. To add another provider, go to `⚙ → AI Assistant → Settings → Provider API`. To switch providers or models, tap the provider entry (`Provider ▸ ...`) in `⚙ → AI Assistant` to open the **Providers and Models** dialog and select one. Only providers added from the UI can be edited or deleted.

**Web search keys (SerpAPI / Tavily / Exa / SearXNG):** available both via UI configuration (`Settings → WebSearch API`) and via the configuration file. In the Ask dialog, use the `🌐 Web Search` checkbox to enable it per question.

#### Option B (Advanced): Use `configuration.lua`

For file-based setup (naming pattern, multiple profiles, extra examples), see [Installation](../../wiki/Installation).

### 4. Using the Plugin

#### Standard Usage

1. Open any book in KOReader.
2. Highlight the text you want to analyze.
3. Tap the highlight and select **AI Assistant**.
4. In the dialog, either type a question and tap **Ask**, or tap one of the built-in prompt buttons (Translate, Summarize, Explain, Dictionary, Term X-Ray, and more) to run it on the selected text.
5. **Follow-up questions**: keep asking about the same selection; the conversation stays in context.

**Tip**: long-press a prompt button to pin it to the first-level highlight menu for one-tap access. Long-press it in the highlight menu to remove it.

#### Using AI Translate with Gestures

You can override KOReader's built-in "Translate" action so a long-press translates through the AI instantly, bypassing the highlight menu. (thanks to [Ilia Reutov](https://github.com/Agnesor))

1. Enable **Use AI Assistant for 'Translate'** under `⚙ → AI Assistant → Settings → Other Settings`.
2. In KOReader's main menu, go to `Taps and gestures → Gesture manager`, select `Long-press on text`, and choose **Translate**.

Now a long-press translates the word directly. Uncheck the option to restore the standard translation service.

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
