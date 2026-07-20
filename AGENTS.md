# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Build / Test / Lint

- **No build step** — Lua files are executed directly by KOReader.
- **No formal test framework** — all testing is manual within a KOReader environment.
- **Syntax check** (LuaJIT): `/usr/lib/koreader/luajit -e "assert(loadfile('main.lua'))"`
- **Syntax check** (standard Lua): `luac -p <file>.lua` — catches basic errors but not LuaJIT-specific constructs.
- **Do NOT use** `luajit -bl` (bytecode listing) — KOReader's stripped LuaJIT lacks the `jit.*` modules.
- **Translation check**: `cd l10n && make check` — validates all `.po` files with `msgfmt`.

## Architecture

This is a KOReader plugin (`assistant.koplugin`) that adds AI assistant functionality to e-readers. It supports 10+ AI providers (Anthropic, OpenAI, Gemini, DeepSeek, Ollama, Groq, Mistral, GigaChat, OpenRouter, Gemma) and the OpenAI Responses API, plus features like translations, summaries, book X-Ray/Recap, a LexRank-based Term X-Ray, web-search tool calling, quick notes, and custom prompts.

### Entry & Core Orchestration
- **`main.lua`** — Plugin init (`Assistant:init`), menu registration, dispatcher actions/gestures, translate-override hook, auto-recap hook, dictionary-popup button registration.
- **`_meta.lua`** — Plugin name/version/description. Version is bumped automatically by the release workflow; never hand-edit for releases.
- **`assistant_querier.lua`** (`Querier`) — Core query engine. Dynamically loads the right API handler, drives both stream and non-stream request paths, and runs the multi-round tool-call loop (web search, max 3 rounds). Parses SSE chunks into a unified format regardless of upstream API shape.
- **`assistant_tool_executor.lua`** (`ToolExecutor`) — Centralizes web-search tool-calling across the three wire formats (`openai`, `anthropic`, `gemini`): building tool defs, parsing tool-call responses, executing search APIs, and building follow-up messages.
- **`assistant_exttools.lua`** — External search API clients (SerpAPI, Tavily, SearXNG, Exa) used by `ToolExecutor`.

### API Handlers (`api_handlers/`)
- **`base.lua`** (`BaseHandler`) — Base class extended by all handlers. Provides `SyncOptions`, `makeRequest`/`backgroundRequest` (sync vs. streaming HTTP), `normalizeBaseUrl`, and the unified `parseToolCalls` entry point. Every handler must implement `query`.
- **Three native wire formats**: `openai.lua`, `anthropic.lua`, `gemini.lua` — full implementations.
- **Thin wrappers** (just alias `OpenAIHandler`): `deepseek.lua`, `ollama.lua`, `openrouter.lua`, `mistral.lua`.
- **Small deltas**: `groq.lua` (free-tier rate-limit debounce), `gigachat.lua` (OAuth token fetch/refresh on top of OpenAI format), `gemma.lua` (dynamically picks OpenAI or Gemini parent by `base_url`; strips `<thought>` tags).
- **`responses.lua`** — OpenAI's `/v1/responses` endpoint with built-in web_search, file_search, and function-calling tools.
- **Handler discovery**: at runtime, `Querier` scans `api_handlers/` for `.lua` files. Provider config keys use the pattern `{handler}_{description}` — the prefix before the first underscore selects the handler (e.g. `openai_perplexity` → `openai` handler).

### LexRank Extractive Summarization (Term X-Ray)
- **`assistant_lexrank.lua`** — TF-IDF weighted LexRank sentence-ranking (tokenize → similarity matrix → PageRank → score-based selection with entity/position boosting). Configurable via `CONFIGURATION.features`.
- **`assistant_lexrank_languages.lua`** — Per-language modules (stop words, sentence delimiters, tokenization, stemming, entity-detection) for `en`, `es`, `fr`, `de`, `tr`; falls back to English.
- **`LEXRANK_LANGUAGES.md`** — Guide + template for adding new language modules. **Read before touching LexRank.**
- **`assistant_dictdialog.lua`** — Consumer of LexRank for "Term X-Ray": runs `rank_sentences` once, filters at multiple thresholds, expands selected sentences with surrounding context.

### UI / Dialog Layer
- **`assistant_dialog.lua`** — Main "Ask AI" popup dialog and result formatting.
- **`assistant_featuredialog.lua`** — Book-level features (Recap, X-Ray, Book Info, Annotations analysis, Summary-using-annotations).
- **`assistant_dictdialog.lua`** — AI Dictionary + Term X-Ray popup.
- **`assistant_settings.lua`** — Provider/model settings dialog and sub-menu.
- **`assistant_model_picker.lua`** — Paginated/searchable model picker (calls `handler:FetchModels()`).
- **`assistant_viewer.lua`** (`ChatGPTViewer`) — Scrollable Markdown/HTML result viewer widget; handles Add-Note/Save-to-Notebook/Copy, follow-up questions, and RTL rendering.
- **`assistant_quicknote.lua`** — Quick-note capture, appended to the notebook file.
- **`assistant_update_checker.lua`** — GitHub-releases version check with SemVer + pre-release comparison.
- **`assistant_mdparser.lua`** — Markdown→HTML wrapper; prefers native `hoedown` (via `lib/libhoedown.so.3`), falls back to KOReader's pure-Lua `markdown.lua`, with pipe-table post-processing.

### Shared Utilities & Localization
- **`assistant_utils.lua`** — Book-text/annotation extraction, notebook file I/O, `httpRequest` with gzip support, metadata attribute helpers (`set_attr`/`get_attr` via metatables — for fields like `use_websearch` that must NOT leak into API payloads).
- **`assistant_gettext.lua`** — Pure-Lua gettext subset forked from KOReader's `frontend/gettext.lua`, pointed at this plugin's `l10n/` directory. Use `_("text")` for all user-facing strings.
- **`assistant_prompts.lua`** — All built-in prompt templates (highlight-menu + book-level features), plus prompt-merging/sorting helpers that combine built-ins with user overrides from `configuration.lua`.

### Configuration
- **`configuration.lua`** — User-owned, gitignored, contains API keys. **Never read or modify it.**
- **`configuration.sample.lua`** — Template tracked in git. When the config format changes, update this file only.

## Key Files & Directories

| Path | Purpose |
|---|---|
| `main.lua` | Plugin entry point, dispatcher actions, menu hooks |
| `assistant_querier.lua` | Core query engine, handler loading, SSE parsing, tool-call loop |
| `api_handlers/base.lua` | Base handler class — extend this for new providers |
| `api_handlers/openai.lua` | OpenAI handler — alias for OpenAI-compatible APIs |
| `api_handlers/responses.lua` | OpenAI Responses API handler (`/v1/responses`) |
| `assistant_tool_executor.lua` | Tool-call normalization across all three wire formats |
| `configuration.sample.lua` | Config template — update this, not `configuration.lua` |
| `l10n/` | Translation files (`.po`/`.pot`), Makefile, AI translation script |
| `.github/workflows/release.yml` | CI/CD: auto-release on `v*` tag push |

## Coding Conventions

- **Language**: Lua 5.1 / LuaJIT 2.1. KOReader bundles LuaJIT — use `string.buffer` over repeated concatenation for performance-sensitive string building.
- **Naming**: modules use `snake_case`; classes use `PascalCase`; methods use `camelCase`; constants use `UPPER_CASE`.
- **Error handling**: Functions return `nil, err` on failure (or `false, err` for HTTP calls). Callers check the first return value.
- **OOP pattern**: Lua metatable-based inheritance — `BaseHandler:new{...}` creates instances, `setmetatable(o, self)` with `self.__index = self` for class-like behavior.
- **Localization**: All user-facing strings wrapped in `_("text")`. Import with `local _ = require("assistant_gettext")`. Plural forms use `N_("1 item", "%1 items", n)`.
- **Configuration access**: Use `koutil.tableGetValue(CONFIGURATION, "path", "to", "key")` for safe nested access with defaults.
- **Metadata on messages**: Use `assistant_utils.set_attr(msg, key, value)` / `get_attr(msg, key)` for fields that must not be serialized into API request bodies (e.g. `use_websearch`, `is_context`, `search_keywords`).

## Git Workflow

- **Branch**: `main` is the default branch.
- **Commit style**: Conventional commits — `fix:`, `refactor:`, `add:`, `feat:` prefixes.
- **Releases**: Tag with `v*` (e.g. `v1.12`). The CI workflow rewrites `_meta.lua` version and creates a zip release asset.

## CI/CD

- **Trigger**: Push of a `v*` tag (e.g. `v1.2.3`).
- **Workflow** (`.github/workflows/release.yml`):
  1. Checkout code
  2. Rewrite `version` in `_meta.lua` from the tag
  3. Archive project into `assistant.koplugin-<tag>.zip` (excluding dotfiles, `.md` files, and non-`.po` files in `l10n/`)
  4. Create a GitHub pre-release with the zip as asset
- No tests run in CI — testing is manual in KOReader.

## Translation Management

```bash
cd l10n && make template      # Generate .pot from source
cd l10n && make update        # Merge .pot into all .po files
cd l10n && make check         # Validate .po syntax
cd l10n && make translate     # Full pipeline (requires API_KEY in .env)
cd l10n && API_KEY=your_key make ai-translate L10N_LANG=fr  # Single language
```

## Tips for AI Agents

- **Never read or modify `configuration.lua`** — it contains user secrets. Update `configuration.sample.lua` only.
- **Exclude `l10n/` from code searches and reads** — it contains only `.po`/`.pot` translation strings in 40+ languages. Searching or reading these files wastes tokens with no code insight.
- **New providers**: if OpenAI-compatible, alias `OpenAIHandler:new{name="..."}` (see `deepseek.lua`). If it needs custom auth/response shape, extend `BaseHandler` and implement `query`/`SyncOptions`/`FetchModels`. Route response parsing through `self:parseToolCalls(...)`.
- **Tool calling**: route all tool-call logic through `assistant_tool_executor.lua`'s `ToolExecutor` — it already normalizes the three wire formats. Don't duplicate per-provider.
- **LexRank**: read `LEXRANK_LANGUAGES.md` before adding or modifying a language module.
- **UI**: use existing dialog patterns from `assistant_dialog.lua` / `assistant_viewer.lua` (`ChatGPTViewer`) rather than building new widget scaffolding.
- **Dependencies**: no external dependencies beyond KOReader's standard libraries. The optional `hoedown` native library is the only exception, with a pure-Lua fallback.
- **License**: GPL-3.0 (see `LICENSE`).
