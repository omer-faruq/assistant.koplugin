# Architecture

KOReader plugin adding AI assistant features: 10+ providers, OpenAI Responses API, translations, summaries, X-Ray/Recap, Term X-Ray (anchor-based), web-search tools, quick notes, custom prompts.

## Request flow

`main.lua` → `Assistant:query` → `Querier:query` → exactly one handler `query` → optional tool loop (`ToolExecutor`) → results shown in `ChatGPTViewer` / `assistant_dialog.lua`.

## Core

- `main.lua` — plugin init, TouchMenu registration, dispatcher actions/gestures, and dictionary-popup button. `assistant_hooks.lua` owns all KOReader monkey patches (Book Description translation button, built-in translation override, auto-recap, and ScrollHtmlWidget pagination). `Assistant:_showAddProviderDialog` / `_showAddWebSearchDialog` delegate to the registries.
- `_meta.lua` — version (`X.Y-dev`), manually bumped on `main` after a release tag; CI rewrites it from the tag during packaging.
- `assistant_querier.lua` (`Querier`) — loads handlers, drives stream/non-stream paths, runs the web-search tool loop (max 3 rounds feeding results back), and parses SSE into one unified format.
- `assistant_tool_executor.lua` (`ToolExecutor`) — normalizes tool-calling across the `openai`/`anthropic`/`gemini` wire formats; loads enabled search tools from `SearchRegistry` at query time.
- `assistant_exttools.lua` — search API clients (SerpAPI, Tavily, SearXNG, Exa).

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

`assistant_provider_registry.lua` (`Registry`) and `assistant_search_registry.lua` (`SearchRegistry`) manage UI-configured providers and web-search tools stored as JSON in settings. Lifecycle, storage keys, validation and config rules: **`docs/REGISTRIES.md`**.

## Term X-Ray (anchor-based)

`assistant_term_xray.lua` splits book text into sentences (`split_sentences`) with a single delimiter set (ASCII `. ! ? ;` plus the full-width `。！？；` and the ellipsis `…`), each sentence keeping its trailing delimiter. There is no ranking. `assistant_term_xray.lua` finds every occurrence of a term with `find_term_indices` (case- and whitespace-insensitive, one retry with edge punctuation stripped) and assembles the bounded context with `build_anchor_context`: ±before/after sentence windows around each anchor, up to `max_occurrences` anchors sampled evenly across the whole book (first and last mention always included), assembled in document order under a character budget that skips oversized sentences. `assistant_dictdialog.lua` wires the two together.

## UI / Dialogs

- `assistant_dialog.lua` — Ask AI popup + result formatting.
- `assistant_hooks.lua` — centralized, idempotent KOReader monkey patches.
- `assistant_featuredialog.lua` — book features: Recap/X-Ray/annotations.
- `assistant_dictdialog.lua` — AI Dictionary + Term X-Ray.
- `assistant_provider_dialog.lua` — provider/model settings (`ProviderDialog`, via `Assistant:showProviderDialog`).
- `assistant_settings_menu.lua` — settings menu builders (`genMenuSettings`/`genWebSearchSubMenuItem`/`genDictionaryOutputMenu`).
- `assistant_model_picker.lua` — `showPickerDialog`/`fetchModels`; call inside `Trapper:wrap`.
- `assistant_viewer.lua` (`ChatGPTViewer`) — scrollable result viewer.
- `assistant_quicknote.lua` — quick-note capture; `assistant_updater.lua` — GitHub release check; `assistant_mdparser.lua` — hoedown → markdown.lua fallback.

## Config

`assistant_config.lua` (`Config` at `assistant.config`) owns the effective `CONFIGURATION`, built from `configuration.lua` + UI registries via `config:buildEffectiveConfig()`. Getters: `getFeature` / `getProvider` / `getProviderSettings` / `getFeatures` / `isProviderEnabled` / `getActiveProviderId`; mutators: `setProvider` / `deleteProvider` / `setSearchTool` / `deleteSearchTool`; errors: `getLoadError`/`setLoadError`/`clearLoadError`; statics: `loadRawConfig`/`getConfigPath`/`getMetaPath`/`testConfigFile`. Access rules: `docs/REGISTRIES.md`.

## Shared utils & gettext

- `assistant_utils.lua` — slim core: metatable attrs, JSON default, and shared path joining.
- `assistant_text_utils.lua` — truncation, selection cleanup, PTF bold, page-text flattening, single-message renderer.
- `assistant_net_utils.lua` — `httpRequest`, JSON fetch, headers, error messages, online guard.
- `assistant_doc_utils.lua` — book/chapter/page extraction, page info, dialog field trim/validate.
- `assistant_gettext.lua` — isolated MO shim, `textdomain "assistant"`, reads `l10n/*/assistant.mo` (MO, not PO); exposes the same `_`/`N_`/`C_`/`NC_` API as upstream, keeping plugin strings out of KOReader's core catalog.
- `assistant_prompts.lua` — prompt templates.
- Helpers: prefer `koutil.tableGetValue`, `koutil.tableDeepCopy`/`tableSize`/`tableEquals` over manual table loops; `util.orderedPairs(t)` for deterministic key order. Error handling returns `nil, err` (or `false, err` for HTTP); callers check the first return value.
- Formatting: bold runs via `assistant_text_utils.bold_format(T(_("<b>Header:</b> %1"), val))`; message metadata via `assistant_utils.set_attr`/`get_attr` for fields that must not serialize into API bodies (`use_websearch`, `is_context`, `search_keywords`).
- **PLUGIN_DIR**: runtime constant `assistant_utils.PLUGIN_DIR` computed in `main.lua` from its own source path with `lfs` existence checks + `DataStorage`/install-dir fallbacks; used by gettext (`l10n`) and mdparser (`lib`). OTA target remains `DataStorage:getFullDataDir()/plugins` (writable).
- **Dependencies**: none beyond KOReader's standard libraries; the optional `hoedown` native library has a pure-Lua fallback. License: GPL-3.0 (see `LICENSE`).

## Key files

| Path | Purpose |
|---|---|
| `main.lua` | Plugin entry, dispatcher actions, menu hooks |
| `assistant_querier.lua` | Core query engine, handler loading, SSE parsing, tool loop |
| `api_handlers/base.lua` | Handler base class |
| `assistant_provider_registry.lua` | UI provider add/edit/merge/validate |
| `assistant_search_registry.lua` | UI search-tool add/merge/validate |
| `assistant_config.lua` | Effective `CONFIGURATION` |
| `configuration.sample.lua` | Config template — update this, not `configuration.lua` |
| `assistant_gettext.lua` | MO shim (assistant domain) |
| `assistant_utils.lua` | Slim core: `PLUGIN_DIR`, attrs, JSON default |
| `assistant_text_utils.lua` | Text helpers + single-message renderer |
| `assistant_net_utils.lua` | HTTP/fetch, headers, error messages |
| `assistant_doc_utils.lua` | Book/page extraction, online guard, field trim |
| `assistant_updater.lua` | GitHub release check |
