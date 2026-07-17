# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Codebase Overview

This is a KOReader plugin (`assistant.koplugin`) that adds AI assistant functionality to e-readers. It supports many AI providers (Anthropic, OpenAI, Gemini, DeepSeek, Ollama, Groq, Mistral, GigaChat, OpenRouter, Gemma, etc.), and features like translations, summaries, book X-Ray/Recap, a context-aware "Term X-Ray" powered by a LexRank-based extractive summarizer, web-search tool calling, quick notes, and custom user-defined prompts.

## Architecture

### Entry & Core Orchestration
- **`main.lua`** — Plugin init (`Assistant:init`), menu registration, dispatcher actions/gestures, translate-override hook, auto-recap hook, dictionary-popup button registration.
- **`_meta.lua`** — Plugin name/version/description (version is bumped automatically by the release workflow, don't hand-edit for releases).
- **`assistant_querier.lua`** — The core query engine (`Querier`). Loads the right API handler for the selected provider, and drives both the **stream** and **non-stream** request paths, including the multi-round **tool-call loop** (web search) shared across providers. Also parses SSE chunks (`processChunk`/`processStream`) into a unified format regardless of upstream API shape (OpenAI-style `choices`, Gemini `candidates`, or Anthropic `content_block_*` events).
- **`assistant_tool_executor.lua`** (`ToolExecutor`) — Centralizes the web-search tool-calling protocol across the three wire formats (`openai`, `anthropic`, `gemini`): building tool defs, parsing tool-call responses, executing the configured search API, and building the follow-up messages to append to history.
- **`assistant_exttools.lua`** — External search API clients (SerpAPI, Tavily, SearXNG) used by `ToolExecutor`.

### API Handlers (`api_handlers/`)
- **`base.lua`** (`BaseHandler`) — Base class all handlers extend via `BaseHandler:new{...}`. Defines `SyncOptions`, `query` (must be implemented by subclasses), `makeRequest`/`backgroundRequest` (sync vs. streaming HTTP), and the unified `parseToolCalls` entry point that every handler funnels non-stream responses through.
- **`openai.lua`**, **`anthropic.lua`**, **`gemini.lua`** — Full implementations for the three "native" wire formats; every other handler is either a thin alias or a small delta on top of one of these.
- **Thin wrappers** (just re-point `name`/`base_url` conventions, no new logic): `deepseek.lua`, `ollama.lua`, `openrouter.lua`, `mistral.lua` — all `OpenAIHandler:new{...}`.
- **Small deltas**: `groq.lua` (adds free-tier rate-limit debounce), `gigachat.lua` (adds OAuth token fetch/refresh on top of OpenAI format), `gemma.lua` (dynamically picks OpenAI-format or Gemini-format parent based on `base_url`, and strips Gemma's `<thought>`/channel tags from output).
- When adding a new provider: if it's OpenAI-compatible, just alias `OpenAIHandler`; if it needs custom auth/response shape, extend `BaseHandler` (or the closest existing handler) and implement `query`/`SyncOptions`/`FetchModels` as needed. Delegate content/tool-call parsing to `self:parseToolCalls(...)` rather than reimplementing it.

### LexRank Extractive Summarization (Term X-Ray context selection)
- **`assistant_lexrank.lua`** — TF-IDF weighted LexRank sentence-ranking implementation (tokenize → similarity matrix → PageRank power iteration → score-based selection with named-entity and position boosting). Config knobs (thresholds, selection percentages, max sentences) come from `CONFIGURATION.features` (see `configuration.sample.lua`) with defaults in `get_default_config()`.
- **`assistant_lexrank_languages.lua`** — Per-language modules (stop words, sentence delimiters, tokenization, stemming, entity-detection regex) for `en`, `es`, `fr`, `de`, `tr`, with graceful fallback to English for unsupported languages.
- **`LEXRANK_LANGUAGES.md`** — Full guide + template for contributing a new language module. **Read this before touching LexRank language support.**
- **`assistant_dictdialog.lua`** — Consumer of LexRank for the "Term X-Ray" feature: runs a single `LexRank.rank_sentences(..., return_with_metadata=true)` call, then filters the same candidate list at multiple score thresholds (term-specific → general → fallback) to avoid re-tokenizing, then expands the selected sentences with surrounding context sentences (`expandContextWithSurroundings`) to capture pronouns/narrative context.

### UI / Dialog Layer
- **`assistant_dialog.lua`** — Main "Ask AI" popup dialog and result formatting.
- **`assistant_featuredialog.lua`** — Book-level features (Recap, X-Ray, Book Info, Annotations analysis, Summary-using-annotations).
- **`assistant_dictdialog.lua`** — AI Dictionary + Term X-Ray popup.
- **`assistant_settings.lua`** — Provider/model settings dialog and the settings sub-menu (`genMenuSettings`).
- **`assistant_model_picker.lua`** — Paginated/searchable model picker (calls `handler:FetchModels()`).
- **`assistant_viewer.lua`** (`ChatGPTViewer`) — Scrollable Markdown/HTML result viewer widget shared by all dialogs; handles Add-Note/Save-to-Notebook/Copy, follow-up questions, and RTL rendering.
- **`assistant_quicknote.lua`** — Quick-note capture, appended to the notebook file.
- **`assistant_update_checker.lua`** — GitHub-releases version check with SemVer + pre-release comparison.
- **`assistant_mdparser.lua`** — Markdown→HTML wrapper; prefers native `hoedown` (via `lib/libhoedown.so.3` if present) and falls back to KOReader's pure-Lua `markdown.lua`, with a post-processing pass to convert pipe-table blocks into real `<table>` HTML.

### Shared Utilities & Localization
- **`assistant_utils.lua`** — Grab-bag of shared helpers: book-text/annotation extraction for AI context, notebook file I/O, markdown heading normalization, `httpRequest` with gzip support, metadata attribute helpers (`set_attr`/`get_attr` stored in metatables, used to attach non-serialized fields like `use_websearch` to message-history entries without them leaking into API payloads).
- **`assistant_gettext.lua`** — Pure-Lua gettext subset forked from KOReader's `frontend/gettext.lua`, pointed at this plugin's own `l10n/` directory. Use `_("text")` for all user-facing strings; see Translation Management commands below.
- **`assistant_prompts.lua`** — All built-in prompt templates (custom highlight-menu prompts + book-level feature prompts), plus prompt-merging/sorting helpers that combine built-ins with user overrides from `configuration.lua`.

### Configuration
- **`configuration.lua`** (user-owned, gitignored) / **`configuration.sample.lua`** (template, tracked in git).

## Development Commands

### Translation Management
```bash
# Generate translation template from source code
cd l10n && make template

# Update all language files with new template
cd l10n && make update

# Run full translation pipeline (requires API_KEY)
cd l10n && API_KEY=your_key make translate

# Translate specific language only
cd l10n && API_KEY=your_key make ai-translate L10N_LANG=fr

# Check translation syntax
cd l10n && make check
```

### Release Process
- Releases are automated via `.github/workflows/release.yml` on `v*` tag push.
- The workflow rewrites `version` in `_meta.lua` from the tag, then zips the repo (excluding dotfiles/`.md` files) into `assistant.koplugin-<tag>.zip`, keeping only `.po` files under `l10n/`.
- No build process needed — Lua files are executed directly by KOReader.

### Testing
- No formal test framework — manual testing in a KOReader environment.
- Configuration testing: copy `configuration.sample.lua` to `configuration.lua` and modify.
- API testing requires valid API keys for the target provider(s).
- Syntax checking: use KOReader's bundled LuaJIT to validate Lua files without a full KOReader environment:
  ```bash
  /usr/lib/koreader/luajit -e "assert(loadfile('assistant_querier.lua'))"
  ```
  Do NOT use `luajit -bl` (bytecode listing) — KOReader's stripped LuaJIT lacks the `jit.*` modules it requires. `luac -p` (standard Lua 5.4) also works for pure syntax checks but will not catch LuaJIT-specific constructs.

## Key Files & Patterns

- **Configuration**: `configuration.lua` is user-owned and must only be edited by the user, never by Claude. When the configuration format or schema needs to change, update `configuration.sample.lua` instead — never read or write the real `configuration.lua` (it may contain private API keys).
- **API Integration**: New providers follow the patterns in `api_handlers/base.lua`. Prefer aliasing `api_handlers/openai.lua` for OpenAI-compatible APIs; only write a full new handler for genuinely different wire formats. Always route response parsing through `self:parseToolCalls(...)`.
- **Tool calling / web search**: Don't duplicate per-provider tool-call logic — route through `assistant_tool_executor.lua`'s `ToolExecutor`, which already normalizes the three formats.
- **UI Components**: Use existing dialog patterns from `assistant_dialog.lua` / `assistant_viewer.lua` (`ChatGPTViewer`) rather than building new widget scaffolding from scratch.
- **LexRank / language support**: See `LEXRANK_LANGUAGES.md` before adding or modifying a language module in `assistant_lexrank_languages.lua`.
- **Localization**: Use the `_("text")` function (from `assistant_gettext.lua`) for all user-facing strings; update `l10n/` per the Translation Management commands above.
- **Metadata attributes on messages**: Use `assistant_utils.set_attr`/`get_attr` (metatable-based) instead of adding plain fields to message-history tables when the field must NOT be serialized into the API request body (e.g. `use_websearch`, `is_context`, `search_keywords`).

## Development Workflow

1. Make code changes in Lua files.
2. Update translations if needed: `cd l10n && make update`.
3. Test in a KOReader environment.
4. Commit changes and tag for release: `git tag v1.x.x && git push --tags`.

## Important Notes

- This is a KOReader plugin, not a standalone application.
- All code must be compatible with KOReader's Lua environment.
- KOReader runs on **LuaJIT 2.1.1772619647**, bundled at `/usr/lib/koreader/luajit`. Write code optimized for the LuaJIT runtime where applicable (e.g. use LuaJIT-specific modules like `string.buffer` instead of standard string concatenation for performance-sensitive string building), and avoid relying on features unsupported by LuaJIT (e.g. standard Lua 5.2+/5.3+/5.4-only syntax or libraries).
- No external dependencies beyond standard KOReader libraries (the optional native `hoedown` markdown library, loaded from a `lib/` dir if present, is the one exception, with a pure-Lua fallback).
- Configuration is user-managed via `configuration.lua`.
- **Do not read or modify `configuration.lua`.** This file is user-managed and may contain private configuration (e.g. API keys). If the configuration format needs to change or a new config option needs to be added, make that change only in `configuration.sample.lua`, never in `configuration.lua`.
- Licensed under GPL-3.0 (see `LICENSE`).
