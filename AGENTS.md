# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Development Environment

- **Recommended OS**: Debian or Ubuntu.
- **Install KOReader from the official `.deb`** — this places the KOReader runtime at `/usr/lib/koreader/`, so agents can freely read the full KOReader source (Lua frontend, plugins, and bundled libraries) for reference when investigating APIs, widget patterns, or bundled utilities.
- Useful paths under `/usr/lib/koreader/`:
  - `frontend/` — KOReader's Lua frontend modules (widgets, dispatcher, gettext, util, etc.).
  - `plugins/` — Bundled plugins (useful as reference implementations).
  - `luajit` — The exact LuaJIT binary KOReader uses; ideal for syntax checks.
- Agents are encouraged to read files under `/usr/lib/koreader/` to understand upstream APIs before writing plugin code, but must **never modify** anything there.

## Build / Test / Lint

- **No build step** — Lua files run directly in KOReader.
- **Syntax check** (LuaJIT): `/usr/lib/koreader/luajit -e "assert(loadfile('main.lua'))"`. **Do not** use `luajit -bl` (stripped build lacks `jit.*`).
- **Syntax check** (standard Lua): `luac -p file.lua` catches basic errors but not LuaJIT-specific constructs.
- **Translation check** (when explicitly requested): `cd l10n && make check` validates `.po` syntax with `msgfmt`.
- **Test framework** (under `test/`): runs inside KOReader's LuaJIT runtime via `setupkoenv.lua` with mocks for UI modules. Run all modules: `./test/run.sh`; run a single module: `./test/run.sh exttools`.
- Discovery is automatic — any `test/test_*.lua` file is picked up at runtime (each returns `helper.runTests(...)`); files run alphabetically, so keep them independent. Stubs for KOReader UI modules live in `test/helper.lua` (see `stubs` table, lines 20–85).
  - `test/run.sh` → `cd`s to `/usr/lib/koreader` then invokes `test/run_tests.lua`, which requires `setupkoenv`, adds the project root to `package.path`, discovers `test/test_*.lua`, runs them, and exits non-zero on failure.
  - `test/helper.lua` — stubs UI/widget modules, mocks `fetchJSON`, provides `assert.*` helpers (`equal`, `notNil`, `isTrue`, `isFalse`, `matches`, `notMatches`) and a `runTests(name, tests)` runner.
  - The `test/` directory is excluded from release zip archives and OTA packages — it is source-only, not shipped to end users.
- **Adding a test**: create `test/test_<module>.lua` following `test_exttools.lua`; the runner auto-discovers it — no registration. Policy: when adding logic, write a test; if the function is exported, `require` it; if local, inline a copy in the test file and test the snippet.
- **Stub discipline**: new `require` chains reaching a real KOReader widget module crash the headless suite (the empty `android` stub makes `device.lua` pick the Android impl). Add a stub in `helper.lua`'s `stubs` table (lines 42–53) whenever a new module is pulled in.
- **Headless**: tests run without a device or KOReader GUI; UI modules are mocked in `test/helper.lua`. The runner prints a summary and exits non-zero on failure.
- **Headless pitfall — `G_reader_settings`**: `G_reader_settings` is a global created by `setupkoenv` / `test/run_tests.lua`. A bare `luajit -e "require('assistant_utils')"` outside `./test/run.sh` fails with `attempt to index global 'G_reader_settings' (a nil value)` (`device`/`fontlist` chain). `fixer` agents must verify modules via `assert(loadfile(...))` (syntax) or `./test/run.sh` (runtime); do not `require` UI-touching modules with raw `luajit -e`.
- **Self-location pitfall**: prefer `assistant_utils.PLUGIN_DIR` over `DataStorage:getDataDir().."/plugins/..."` directly; the latter diverges under `MULTIUSER`/extra_plugin_paths.
- **Before committing**: run `./test/run.sh` — CI ships without running tests, so local runs are the only automated guard.
- **UI testing**: `./test/runui.sh model_picker` (add `-w=1072 -h=1448 -d=300` or `-s=kobo-clara` to simulate a device). Add a `test/` script that requires `test/wbuilder`, shows widgets with `UIManager:show(...)`, and ends with `UIManager:run()`. `test/wbuilder` bootstraps the KOReader UI framework and plugin path for isolated widget tests.

## Architecture

KOReader plugin (`assistant.koplugin`) adding AI assistant features (10+ providers, OpenAI Responses API, translations, summaries, X-Ray/Recap, LexRank Term X-Ray, web-search tools, quick notes, custom prompts).

- **Entry & Core**: `main.lua` (plugin init, TouchMenu registration, dispatcher actions/gestures, translate-override + auto-recap hooks, dictionary-popup button), `_meta.lua` (version, manually bumped on `main` after a release tag; CI rewrites it from the tag during packaging).
- **Request flow**: `main.lua` → `Querier:query` → handler `query` → (optional tool loop via `ToolExecutor`) → results shown in `ChatGPTViewer` / `assistant_dialog.lua`.
- `assistant_querier.lua` (`Querier`) loads handlers, drives stream/non-stream paths, runs the web-search tool loop (max 3 rounds feeding results back), and parses SSE into a unified format. `assistant_tool_executor.lua` (`ToolExecutor`) normalizes tool-calling across `openai`/`anthropic`/`gemini` wire formats; `assistant_exttools.lua` holds the search API clients (SerpAPI, Tavily, SearXNG, Exa).
- **API Handlers** (`api_handlers/`): `base.lua` (`BaseHandler`) provides `SyncOptions`, `makeRequest`/`backgroundRequest`, `normalizeBaseUrl`, `parseToolCalls`; every handler implements `query`.
  - `openai.lua` (+ `deepseek`/`ollama`/`openrouter`/`mistral` aliases) — `Authorization: Bearer`, `/chat/completions`; set `base_url` for any OpenAI-compatible endpoint.
  - `anthropic.lua` — `x-api-key` + `anthropic-version` headers, `/v1/messages`.
  - `gemini.lua` — API key as query param, `{base_url}/{model}:generateContent`.
  - `responses.lua` — OpenAI `/v1/responses` with built-in `web_search`/`file_search`/function tools.
  - Deltas: `groq.lua` (free-tier debounce), `gigachat.lua` (OAuth token), `gemma.lua` (picks OpenAI/Gemini parent by `base_url`; strips `<thought>`).
  - The Querier selects exactly one handler per request using the discovery rules above.
  - **Handler discovery**: `Querier` scans `api_handlers/` at runtime. File providers use config keys `{handler}_{description}` (prefix before first underscore selects the handler, e.g. `openai_perplexity` → `openai`). UI providers use stable IDs `custom:N` but carry a `provider.handler` field naming the handler. `Registry.HANDLERS` only allows `openai`/`anthropic`/`gemini`/`responses` — thin wrappers and deltas are **not** UI-selectable.
- **Provider Registry** (`assistant_provider_registry.lua`, `Registry`): manages UI providers stored as JSON in `settings:saveSetting("ui_providers", ...)`.
  - `Registry.load` reads UI providers; `Registry.merge(file_config, ui_data)` combines them with file providers into `CONFIGURATION.provider_settings`. File providers get `source="file"`, `immutable=true`; UI providers get `source="ui"`, `custom:N` (auto-incrementing). At `main.lua` init this builds the effective config.
  - File providers are defined in `configuration.lua`; only `source=="ui"` providers can be edited or deleted from the settings UI. Config keys: file `{handler}_{description}`, UI `custom:N` (see Handler discovery).
  - `Registry.validate(record)` checks `display_name`, `handler` (must match an `api_handlers/` file), `model` (defaults `"auto"`), `base_url` (`http(s)://`), `api_key`.
  - `Registry.installProvider(assistant, …)` — add + save + update in-memory config + load into querier. `Registry.delete(data, id)` and `Registry.is_deletable(provider)` — only `source=="ui"` providers are deletable.
  - `display_name` drives the Settings radio and main menu label (not the config key). Gemini `base_url` must keep the `/models` segment (`FetchModels` GETs base_url; `query` POSTs `{base_url}/{model}:generateContent`); OpenAI-compatible Gemini endpoints use the `openai` handler.
- **Search Registry** (`assistant_search_registry.lua`, `SearchRegistry`): mirrors the provider registry for web-search tools stored under `ui_search_tools`, but uses **fixed tool keys** (`serpapi`, `tavilyapi`, `exaapi`, `searxngapi`) rather than `custom:N`. `SEARCH_TOOLS` defines those keys and their schema. Covered engines: SerpAPI, Tavily, SearXNG, Exa. UI tools are added via the Settings → Search Tools dialog.
  - `SearchRegistry.load`/`save`/`merge`/`validate`/`installSearchTool`/`delete`/`is_deletable` follow the same `source`/`immutable` pattern (file tools `source="file"`, immutable; only UI tools deletable). Merge combines file + UI data keyed by tool key.
  - `ToolExecutor` loads enabled (non-empty `api_key`) tools from `SearchRegistry` at query time and passes them into the handler's tool defs. Both registries must be used directly — never touch `settings:saveSetting("ui_providers"/"ui_search_tools", ...)`.
- **LexRank (Term X-Ray)**: `assistant_lexrank.lua` does TF-IDF-weighted LexRank sentence ranking (tokenize → similarity matrix → PageRank → score-based selection with entity/position boosting); its tunables (`lexrank_max_sentences`, etc.) live **here**. Per-language modules in `assistant_lexrank_languages.lua` (`en`,`es`,`fr`,`de`,`tr`; fallback en) — read `LEXRANK_LANGUAGES.md` before editing. Display thresholds (multi-level filtering, context expansion) live in `assistant_dictdialog.lua`, which consumes `rank_sentences`.
- **UI / Dialogs**: `assistant_dialog.lua` (Ask AI popup + result formatting), `assistant_featuredialog.lua` (book features: Recap/X-Ray/annotations), `assistant_dictdialog.lua` (AI Dictionary + Term X-Ray), `assistant_settings.lua` (provider/model settings), `assistant_model_picker.lua` (`showPickerDialog`/`fetchModels`, call inside `Trapper:wrap`).
  - `assistant_viewer.lua` (`ChatGPTViewer` scrollable result viewer), `assistant_quicknote.lua` (quick-note capture), `assistant_updater.lua` (GitHub release check), `assistant_mdparser.lua` (hoedown → markdown.lua fallback).
- **Shared Utils & Config**: `assistant_utils.lua` (extraction, notebook I/O, `httpRequest`, `PLUGIN_DIR` constant via `debug.getinfo` self-location with `DataStorage` fallback, set once by `main.lua`), `assistant_gettext.lua` (isolated MO shim that dofiles `frontend/gettext.lua`, `ffi.cdef` guard, `textdomain "assistant"`, `l10n/assistant.mo`), `assistant_prompts.lua`. `configuration.lua` is user-owned, gitignored, holds secrets — never read/modify; update `configuration.sample.lua` instead. Runtime config lives in `CONFIGURATION` (built from `configuration.lua` + UI registries via `Assistant:buildEffectiveConfig`); read/write only via `Assistant:confGet*` / `confSet*` (e.g. `confGetFeature`, `confGetProvider`, `confGetFeatures`).
- **PLUGIN_DIR**: runtime constant `assistant_utils.PLUGIN_DIR` computed once in `main.lua` from its own source path (`debug.getinfo`), with `lfs` existence checks + `DataStorage`/install-dir fallbacks. Used by gettext (`l10n`) and mdparser (`lib`). OTA target remains `DataStorage:getFullDataDir()/plugins` (writable).
- **gettext / Translation**: `assistant_gettext.lua` now reads `l10n/*/assistant.mo` (MO, not PO) and exposes the same `_` / `N_` / `C_` / `NC_` API as upstream. It isolates the assistant domain so plugin strings never clash with KOReader's core catalog.
- **Dependencies**: none beyond KOReader's standard libraries; the optional `hoedown` native library has a pure-Lua fallback. License: GPL-3.0 (see `LICENSE`).

## Key Files

| Path | Purpose |
|---|---|
| `main.lua` | Plugin entry, dispatcher actions, menu hooks |
| `assistant_querier.lua` | Core query engine, handler loading, SSE parsing, tool loop |
| `api_handlers/base.lua` | Handler base class (registries: `assistant_provider_registry.lua`, `assistant_search_registry.lua`) |
| `configuration.sample.lua` | Config template — update this, not `configuration.lua` |
| `assistant_search_registry.lua` | UI search-tool add/merge/validate, JSON settings storage |
| `assistant_gettext.lua` | MO shim (assistant domain) |
| `assistant_utils.lua` | `httpRequest`, `PLUGIN_DIR`, extraction, notebook I/O |
| `assistant_updater.lua` | GitHub release check |

## Coding Conventions

- Lua 5.1 / LuaJIT 2.1; use `string.buffer` for hot loops. Naming: `snake_case` modules, `PascalCase` classes, `camelCase` methods, `UPPER_CASE` consts. Never use `_` as a discarded loop var (it is the gettext function).
- Error handling: return `nil, err` (or `false, err` for HTTP); callers check the first return value. e.g. `local data, err = fetch(); if not data then return nil, err end`.
- Localization: wrap every user-facing string in `_("text")` (`local _ = require("assistant_gettext")`); plurals via `N_("1 item", "%1 items", n)`. Keep strings contiguous inside `T(_("..."))` templates; title-case UI labels (short words lowercase).
- OOP: metatable inheritance — `BaseHandler:new{...}` with `self.__index = self`; every handler implements `query`. e.g. `local H = BaseHandler:new{ name = "x" }`.
- Helpers:
  - Nested reads via `Assistant:confGetFeature` / `confGetProvider` (or `koutil.tableGetValue` for non-CONFIGURATION tables); `koutil.tableMerge(t1,t2)` **mutates `t1` in place** (returns nil — never assign its result).
  - `T = require("ffi/util").template` for `T(_("%1 items"), n)`; `util.orderedPairs(t)` for deterministic key order.
  - JSON only `require("rapidjson")`; `null` is `rapidjson.null` — check `== nil or == rapidjson.null`, fall back with `assistant_utils.json_default`. Never introduce another JSON library (e.g. `dkjson`, `cjson`) — mixed null representations cause subtle bugs.
  - Bold runs via `assistant_utils.bold_format(T(_("<b>Header:</b> %1"), val))` with `<b>`/`</b>`.
  - Prefer `koutil.tableDeepCopy`/`tableSize`/`tableEquals` over manual table loops.
- Dialog buttons: cancellation/close on the **left**, action buttons (Save/OK) on the **right** (KOReader `InputDialog` convention).
- Message metadata: `assistant_utils.set_attr`/`get_attr` for fields that must not serialize into API bodies (`use_websearch`, `is_context`, `search_keywords`).
- Rich text & formatting: use `assistant_utils.bold_format(...)` with `<b>`/`</b>`; avoid manual concatenation inside translated strings. e.g. `assistant_utils.bold_format(T(_("<b>Note:</b> %1"), txt))`.
- Menu/UI label casing: Title Case for titles, settings items, checkboxes, dialog labels; keep short words (`to`, `for`, `as`, `and`, `in`) lowercase.

## Git Workflow / Versioning / CI/CD

- Default branch `main`; Conventional Commits (`fix:`, `refactor:`, `add:`, `feat:`). When asked to commit, do it directly with a concise message.
- `_meta.lua` holds the current development version (the *next* release). When a release is ready: tag the commit matching it (e.g. `_meta.lua` says `"1.14"` → tag `v1.14`), then bump `_meta.lua` to the next number and commit (`chore: bump version to 1.15`).
- AI agents: when asked to tag a release, tag the commit matching `_meta.lua`'s version, then bump and commit the bump.
- CI (`.github/workflows/release.yml`): on `v*` push — checkout, rewrite `_meta.lua` from the tag, zip (excludes dotfiles, `.md`, l10n non-mo files — only `*.mo` shipped; MO files are now tracked in repo, built via `l10n/Makefile DOMAIN=assistant`, `all: mo`).
- CI creates a GitHub pre-release with the zip asset; no tests run in CI (testing is manual in KOReader).

## Translation Management

- Translation scripts in `l10n/` are developer-run manually. **AI agents must not** run `make template/update/translate/ai-translate`; only `make check` is allowed when explicitly requested.
- Reference (do not invoke): `cd l10n && make template|update|check|translate`. Domain is `DOMAIN=assistant` (`assistant.pot` / `assistant.po` / `assistant.mo`); `all: mo` is the default target, `translate` builds the MO, `check` validates PO via `msgfmt`, and MO files are committed to the repo.

## Development Principles

- **No backward compatibility for internal code**: This repo is a KOReader plugin; all `assistant_*.lua` modules are internal with no external consumers. When migrating code, move it and update all internal call sites in one go — **do not keep `Deprecated` wrappers / compat layers**. They add duplicate logic and circular dependencies.
- **Prefer clear, direct calls**: Callers should `require` the owning module directly (e.g. `Notebook.saveToNotebookFile`) without proxying through an intermediary. Keep the call chain one hop.
- **Keep module responsibilities explicit**: Split by domain / use case (e.g. `Notebook` owns storage, `QuickNote` owns the interaction flow). Do not blur boundaries for compatibility.
- **Avoid direct access to CONFIGURATION raw table**: Read and write CONFIGURATION only via `Assistant:confGet*` / `confSet*` / `buildEffectiveConfig` (e.g. `confGetFeature`, `confGetProvider`, `confGetFeatures`). Do not read `CONFIGURATION.features` / `CONFIGURATION.provider_settings` directly and do not write `CONFIGURATION.provider_settings[key]` by hand.

## Tips for AI Agents

- **English polish**: the developer isn't a native speaker; correct wording into idiomatic English while preserving intent (e.g. "bleeding-edge code").
- **Secrets**: never read/modify `configuration.lua` (gitignored, holds keys); update `configuration.sample.lua` only. Exclude `l10n/` from code searches/reads (40+ languages, no code insight).
- **New providers**: OpenAI-compatible → alias `OpenAIHandler:new{name="..."}`; custom auth/shape → extend `BaseHandler` (`query`/`SyncOptions`/`FetchModels`) and route parsing through `self:parseToolCalls(...)`. Never duplicate tool-calling — use `ToolExecutor`.
- **Registry/Search lifecycle**: do all UI provider/search CRUD via `Registry`/`SearchRegistry` (consult `assistant_provider_registry.lua` / `assistant_search_registry.lua`); never manipulate `settings:saveSetting("ui_providers"/"ui_search_tools", ...)` directly.
- **Tool calling**: route all tool-call logic through `ToolExecutor` — it already normalizes the three wire formats; don't duplicate per-provider.
- **Tests**: when adding logic, write a test (see Build / Test / Lint). Exported functions are `require`d directly; local closures are inlined as a snippet.
- **Ask dialog checkbox layout** (`assistant_dialog.lua`): side-by-side rows `HorizontalGroup{ HorizontalSpan(left_gap) + CheckButton(width=half_w) + HorizontalSpan(gap) + CheckButton(width=half_w) }`. Each `CheckButton` needs explicit `width = half_w` or it overflows (`checkbutton.lua:77`). Left inset `left_gap = (dialog_width - available_w - input_extra)/2` where `input_extra = 2*(Size.border.inputtext + Size.padding.small + Size.margin.default)` — aligns to the InputText border, don't hardcode `Size.padding.large`. Actual labels are emoji-prefixed: `✉ Attach Prior Text`, `✎ Current Chapter Only`, `🌐 Web Search`, `⌨ Copy to Clipboard`.
- **Menu markers**: `main.lua` locates TouchMenu items via `assistant_item_id` markers — `assistant_ai_menu`, `assistant_settings`, `assistant_add_provider`. MenuSorter keeps references, so markers survive building; keep them when moving/renaming. Conditional items (e.g. `Custom Prompts`) are safe. `showAddProviderMenu` computes the TouchMenu path dynamically from the live `tab_item_table`.
- **LexRank**: read `LEXRANK_LANGUAGES.md` before adding/modifying a language module.
- **KOReader widget internals**: only as a last resort. Check the public API first, then read the widget source under `/usr/lib/koreader/frontend/ui/widget/` to trace the `widget[1]`/`[2]` tree; swap a sub-widget and nil `_size`/`_offsets`/`dimen` up the tree to re-layout. Always comment the widget-tree path.
- **UI testing (wbuilder)**: `./test/runui.sh model_picker` accepts `-w=1072 -h=1448 -d=300` or `-s=kobo-clara` to simulate a device screen.
- **UI patterns**: reuse existing dialog/widget scaffolding (`ChatGPTViewer`, `assistant_dialog.lua`) rather than building new widget trees.
- **UI reference (niche)**: KOReader UI is niche — when touching plugin UI/widget code, scan `/usr/lib/koreader/frontend/ui/widget/` and `/usr/lib/koreader/plugins/` for reference patterns before writing new layouts.
