# Architecture

KOReader plugin adding AI assistant features: 10+ providers, OpenAI Responses API, translations, summaries, X-Ray/Recap, Term X-Ray (anchor-based), web-search tools, quick notes, custom prompts.

## Request flow

`main.lua` → `Assistant:query` → `Querier:query` → exactly one handler `query` → optional tool loop (`ToolExecutor`) → results shown in `ResultViewer` / `dialogs/dialog.lua`.

## Core

- `main.lua` — slim plugin entry: init, dispatcher actions and 1-line delegates to owning modules. `feature/book_actions.lua` owns book features, identification and the FileManager long-press row; `core/hooks.lua` owns all KOReader monkey patches (Book Description translation button, built-in translation override, auto-recap, ScrollHtmlWidget pagination, highlight-menu and dictionary-popup buttons); `dialogs/settings_menu.lua` owns the main menu, provider dialog and help/about dialogs. Providers and web-search tools are added through `Registry.showProviderDialog` / `SearchRegistry.showWebSearchDialog`.
- `_meta.lua` — version (`X.Y-dev`), manually bumped on `main` after a release tag; CI rewrites it from the tag during packaging.
- `core/querier.lua` (`Querier`) — loads handlers, drives stream/non-stream paths, runs the web-search tool loop (max 3 rounds feeding results back), and parses SSE into one unified format.
- `core/tool_executor.lua` (`ToolExecutor`) — normalizes tool-calling across the `openai`/`anthropic`/`gemini` wire formats; loads enabled search tools from `SearchRegistry` at query time.
- `core/exttools.lua` — search API clients (SerpAPI, Tavily, SearXNG, Exa).

## API handlers (`api_handlers/`)

`base.lua` (`BaseHandler`) provides `SyncOptions`, `makeRequest`/`backgroundRequest`, `normalizeBaseUrl`, and `parseToolCalls`; every handler implements `query`. Handlers use metatable inheritance: `BaseHandler:new{...}` with `self.__index = self` (e.g. `local H = BaseHandler:new{ name = "x" }`).

- `openai.lua` (+ `deepseek`/`ollama`/`openrouter`/`mistral` aliases) — `Authorization: Bearer`, `/chat/completions`; set `base_url` for any OpenAI-compatible endpoint.
- `anthropic.lua` — `x-api-key` + `anthropic-version` headers, `/v1/messages`.
- `gemini.lua` — API key as query param, `{base_url}/{model}:generateContent`.
- `responses.lua` — OpenAI `/v1/responses` with built-in `web_search`/`file_search`/function tools.
- Deltas: `groq.lua` (free-tier debounce), `gigachat.lua` (OAuth token), `gemma.lua` (picks OpenAI/Gemini parent by `base_url`; strips `<thought>`).

### Handler discovery

`Querier` scans `api_handlers/` at runtime. File providers use config keys `{handler}_{description}` (the prefix before the first underscore selects the handler, e.g. `openai_perplexity` → `openai`). UI providers use stable IDs `custom:N` plus a `provider.handler` field naming the handler. `Registry.HANDLERS` allows only `openai`/`anthropic`/`gemini`/`responses` — thin wrappers and deltas are **not** UI-selectable.

### New providers & tool calling

- OpenAI-compatible → alias `OpenAIHandler:new{name="..."}`.
- Custom auth/shape → extend `BaseHandler` (`query`/`SyncOptions`/`FetchModels`) and route parsing through `self:parseToolCalls(...)`.
- Route all tool-call logic through `ToolExecutor` — it already normalizes the three wire formats; do not duplicate per provider.

## Registries

`core/provider_registry.lua` (`Registry`) and `core/search_registry.lua` (`SearchRegistry`) manage UI-configured providers and web-search tools stored as JSON in settings. Lifecycle, storage keys, validation and config rules: **`docs/REGISTRIES.md`**.

## Term X-Ray (anchor-based)

`feature/term_xray.lua` splits book text into sentences (`split_sentences`) with a single delimiter set (ASCII `. ! ? ;` plus the full-width `。！？；` and the ellipsis `…`), each sentence keeping its trailing delimiter. There is no ranking. `feature/term_xray.lua` finds every occurrence of a term with `find_term_indices` (case- and whitespace-insensitive, one retry with edge punctuation stripped) and assembles the bounded context with `build_anchor_context`: ±before/after sentence windows around each anchor, up to `max_occurrences` anchors sampled evenly across the whole book (first and last mention always included), assembled in document order under a character budget that skips oversized sentences. `dialogs/dict.lua` wires the two together.

## UI / Dialogs

- `dialogs/dialog.lua` — Ask AI popup + result formatting.
- `core/hooks.lua` — centralized, idempotent KOReader monkey patches.
- `dialogs/feature.lua` — book features: Recap/X-Ray/annotations.
- `dialogs/dict.lua` — AI Dictionary + Term X-Ray.
- `dialogs/provider.lua` — provider/model settings (`ProviderDialog`, via `Assistant:showProviderDialog`).
- `dialogs/settings_menu.lua` — settings menu builders (`genMenuSettings`/`genWebSearchSubMenuItem`/`genDictionaryOutputMenu`) plus main menu, provider dialog and help/about dialogs.
- `dialogs/model_picker.lua` — `showPickerDialog`/`fetchModels`; call inside `Trapper:wrap`.
- `dialogs/viewer.lua` (`ResultViewer`) — scrollable result viewer.
- `dialogs/quicknote.lua` — quick-note capture; `core/updater.lua` — GitHub release check; `dialogs/mdparser.lua` — hoedown → markdown.lua fallback.

## Config

`core/config.lua` (`Config` at `assistant.config`) owns the effective `CONFIGURATION`, built from `configuration.lua` + UI registries via `config:buildEffectiveConfig()`. Getters: `getFeature` / `getProvider` / `getProviderSettings` / `getFeatures` / `isProviderEnabled` / `getActiveProviderId`; mutators: `setProvider` / `deleteProvider` / `setSearchTool` / `deleteSearchTool`; errors: `getLoadError`/`setLoadError`/`clearLoadError`; statics: `loadRawConfig`/`getConfigPath`/`getMetaPath`/`testConfigFile`. Access rules: `docs/REGISTRIES.md`.

## Shared utils & gettext

- `utils/base.lua` — slim core: metatable attrs, JSON default, and shared path joining.
- `utils/text.lua` — truncation, selection cleanup, PTF bold, page-text flattening, single-message renderer.
- `utils/net.lua` — `httpRequest`, JSON fetch, headers, error messages, online guard.
- `utils/doc.lua` — book/chapter/page extraction, page info, dialog field trim/validate.
- `feature/lookup.lua` — selection routing: `lookup_mode_for_selection` (CJK runs are measured in characters, not words, because `koutil.splitToWords` collapses a CJK run into one token) and `resolve_translate_route` (whether a short selection may prompt the explainer), plus `showTranslateOrDictionary`.
- `core/gettext.lua` — isolated MO shim, `textdomain "assistant"`, reads `l10n/*/assistant.mo` (MO, not PO); exposes the same `_`/`N_`/`C_`/`NC_` API as upstream, keeping plugin strings out of KOReader's core catalog.
- `core/prompts.lua` — prompt templates.
- Helpers: prefer `koutil.tableGetValue`, `koutil.tableDeepCopy`/`tableSize`/`tableEquals` over manual table loops; `util.orderedPairs(t)` for deterministic key order. Error handling returns `nil, err` (or `false, err` for HTTP); callers check the first return value.
- Formatting: bold runs via `utils/text.bold_format(T(_("<b>Header:</b> %1"), val))`; message metadata via `utils/base.set_attr`/`get_attr` for fields that must not serialize into API bodies (`use_websearch`, `is_context`, `search_keywords`).
- **PLUGIN_DIR**: runtime constant `utils/base.PLUGIN_DIR` computed in `main.lua` from its own source path with `lfs` existence checks + `DataStorage`/install-dir fallbacks; used by gettext (`l10n`) and mdparser (`lib`). OTA target remains `DataStorage:getFullDataDir()/plugins` (writable).
- **Dependencies**: none beyond KOReader's standard libraries; the optional `hoedown` native library has a pure-Lua fallback. License: GPL-3.0 (see `LICENSE`).

## Key files

| Path | Purpose |
|---|---|
| `main.lua` | Slim plugin entry, dispatcher actions, init, delegates |
| `feature/book_actions.lua` | Book features, identification flow, FileManager row |
| `core/querier.lua` | Core query engine, handler loading, SSE parsing, tool loop |
| `api_handlers/base.lua` | Handler base class |
| `core/provider_registry.lua` | UI provider add/edit/merge/validate |
| `core/search_registry.lua` | UI search-tool add/merge/validate |
| `core/config.lua` | Effective `CONFIGURATION` |
| `configuration.sample.lua` | Config template — update this, not `configuration.lua` |
| `core/gettext.lua` | MO shim (assistant domain) |
| `utils/base.lua` | Slim core: `PLUGIN_DIR`, attrs, JSON default |
| `utils/text.lua` | Text helpers + single-message renderer |
| `utils/net.lua` | HTTP/fetch, headers, error messages |
| `utils/doc.lua` | Book/page extraction, online guard, field trim |
| `feature/lookup.lua` | Selection routing: lookup mode + explainer route |
| `core/updater.lua` | GitHub release check |
