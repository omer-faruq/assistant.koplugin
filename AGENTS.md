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
- **Stub discipline**: new `require` chains reaching a real KOReader widget module crash the headless suite (the empty `android` stub makes `device.lua` pick the Android impl). Add a stub in `helper.lua`'s `stubs` table whenever a new module is pulled in — e.g. `device` needs a `screen = { getWidth/getHeight }` fake for layout math; `buttontable`/`titlebar`/containers as `{}`. Beware **duplicate keys in the `stubs` table constructor — the last entry silently wins**; check for duplicates when adding a stub that already exists.
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
- **Config** (`assistant_config.lua`, `Config` at `assistant.config`): owns the effective `CONFIGURATION` (built from `configuration.lua` + UI registries via `config:buildEffectiveConfig()`). Getters: `getFeature` / `getProvider` / `getProviderSettings` / `getFeatures` / `isProviderEnabled` / `getActiveProviderId`; mutators: `setProvider` / `deleteProvider` / `setSearchTool` / `deleteSearchTool`; errors: `getLoadError`/`setLoadError`/`clearLoadError`; statics: `loadRawConfig`/`getConfigPath`/`getMetaPath`/`testConfigFile`. `configuration.lua` is user-owned, gitignored, holds secrets — never read/modify; update `configuration.sample.lua` instead.
- **Shared Utils**: `assistant_utils.lua` (extraction, notebook I/O, `httpRequest`, `PLUGIN_DIR` via `debug.getinfo` self-location, set once by `main.lua`), `assistant_gettext.lua` (isolated MO shim, `textdomain "assistant"`, `l10n/assistant.mo`), `assistant_prompts.lua`.
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
- **Indentation**: 4 spaces, never tabs (matches KOReader upstream). Vendored code under `lib/` keeps upstream formatting.
- Error handling: return `nil, err` (or `false, err` for HTTP); callers check the first return value. e.g. `local data, err = fetch(); if not data then return nil, err end`.
- Localization: wrap every user-facing string in `_("text")` (`local _ = require("assistant_gettext")`); plurals via `N_("1 item", "%1 items", n)`. Keep strings contiguous inside `T(_("..."))` templates; title-case UI labels (short words lowercase).
  - **ASCII-only msgids**: every `_("...")`/`N_()`/`C_()`/`NC_()` string must be US-ASCII only (U+0000–U+007F). Inject Unicode glyphs (emoji, arrows, dashes) **outside** `_()` via `T()` placeholders or concatenation — e.g. `T(_("Provider %1 NOT CONFIGURED"), "▸")` not `_("Provider ▸ NOT CONFIGURED")`; `"🌐 " .. _("Web Search")` not `_("🌐 Web Search")`; `_("Provider Name - shown ...")` not `_("Provider Name — shown ...")` (use `-`/`...`). Prevents `msgattrib`/`msgcat`/`msgmerge` `invalid multibyte`/`Charset missing` warnings, keeps `l10n/Makefile` to a shell `msgattrib` pipeline (no `polib` needed), and follows GNU gettext manual (ASCII msgids).
- OOP: metatable inheritance — `BaseHandler:new{...}` with `self.__index = self`; every handler implements `query`. e.g. `local H = BaseHandler:new{ name = "x" }`.
- Helpers:
  - Nested reads: always via `assistant.config:getFeature` / `getProvider` / `getProviderSettings` / `getFeatures` / `getActiveProviderId` / `isProviderEnabled` for CONFIGURATION, or `koutil.tableGetValue(t, ...)` for other tables; never use manual `and` chains like `t and t.foo and t.foo.bar`. `koutil.tableMerge(t1,t2)` **mutates `t1` in place** (returns nil — never assign its result).
  - `T = require("ffi/util").template` for `T(_("%1 items"), n)`; `util.orderedPairs(t)` for deterministic key order.
  - JSON only `require("rapidjson")`; `null` is `rapidjson.null` — check `== nil or == rapidjson.null`, fall back with `assistant_utils.json_default`. Never introduce another JSON library (e.g. `dkjson`, `cjson`) — mixed null representations cause subtle bugs.
  - Bold runs via `assistant_utils.bold_format(T(_("<b>Header:</b> %1"), val))` with `<b>`/`</b>`; avoid manual concatenation inside translated strings.
  - Prefer `koutil.tableDeepCopy`/`tableSize`/`tableEquals` over manual table loops.
- Dialog buttons: cancellation/close on the **left**, action buttons (Save/OK) on the **right** (KOReader `InputDialog` convention).
- Message metadata: `assistant_utils.set_attr`/`get_attr` for fields that must not serialize into API bodies (`use_websearch`, `is_context`, `search_keywords`).
- Menu/UI label casing: Title Case for titles, settings items, checkboxes, dialog labels; keep short words (`to`, `for`, `as`, `and`, `in`) lowercase.
- **Notifications vs InfoMessage**: Use `Notification:notify` **only for success/confirmation messages** that should appear briefly and dismiss automatically. For **errors, failures, or messages requiring user acknowledgment**, always use `UIManager:show(InfoMessage:new{ text = ... })`. `InfoMessage` blocks until dismissed; `Notification` is non-blocking and suited for transient success toasts.

## Git Workflow / Versioning / CI/CD

- Default branch `main`; Conventional Commits (`fix:`, `refactor:`, `add:`, `feat:`). When asked to commit, do it directly with a concise message.
- `_meta.lua` holds the current development version with `-dev` suffix (e.g. `"1.17-dev"` for next `1.17`). When a release is ready: tag the commit (`v1.17` for `1.17-dev`), CI will `git archive "$GITHUB_REF_NAME" --prefix=assistant.koplugin/ | tar xf -` and `sed` only `$PACKAGE_NAME/_meta.lua` to `"1.17"` (repo's `1.17-dev` untouched), then bump repo to next dev (`"1.18-dev"`) and commit (`chore: set version to 1.18-dev`).
- AI agents: when asked to tag a release, tag the commit matching `_meta.lua`'s `X.Y-dev` (tag `vX.Y`), then bump `_meta.lua` to next `X.(Y+1)-dev` and commit.
- CI (`.github/workflows/release.yml`): on `v*` push (+ `workflow_dispatch`) — `git archive "$GITHUB_REF_NAME"` with prefix, `sed` package's `_meta.lua` from tag, `zip -r -x@/tmp/exclude.list` driven by `.releaseignore` (light, `*` includes `/`, `!` kept for OTA compat, CI uses explicit `l10n` list via Python `pkg`/`raw`→`exclude.list`); only `*.mo` shipped. OTA reads `.releaseignore` from the Git archive zip (not CI product) and falls back to legacy `dot/md/l10n/test` rules.
- CI creates a GitHub pre-release with the zip asset; no tests run in CI (testing is manual in KOReader).

## Translation Management

- Translation scripts in `l10n/` are developer-run manually. **AI agents must not** run `make template/update/translate/ai-translate`; only `make check` is allowed when explicitly requested.
- Reference (do not invoke): `cd l10n && make template|update|check|translate`. Domain is `DOMAIN=assistant` (`assistant.pot` / `assistant.po` / `assistant.mo`); `all: mo` is the default target, `translate` builds the MO, `check` validates PO via `msgfmt`, and MO files are committed to the repo.

## Development Principles

- **No backward compatibility for internal code**: This repo is a KOReader plugin; all `assistant_*.lua` modules are internal with no external consumers. When migrating code, move it and update all internal call sites in one go — **do not keep `Deprecated` wrappers / compat layers**. They add duplicate logic and circular dependencies.
- **Prefer clear, direct calls**: Callers should `require` the owning module directly (e.g. `Notebook.saveToNotebookFile`) without proxying through an intermediary. Keep the call chain one hop.
- **Keep module responsibilities explicit**: Split by domain / use case (e.g. `Notebook` owns storage, `QuickNote` owns the interaction flow). Do not blur boundaries for compatibility.
- **Config access**: read/write `CONFIGURATION` only via `assistant.config` (`getFeature`/`getProvider`/`getProviderSettings`/`getFeatures`/`isProviderEnabled`/`getActiveProviderId`/`setProvider`/`deleteProvider`/`buildEffectiveConfig`). Never read `CONFIGURATION.features`/`provider_settings` directly or write `CONFIGURATION.provider_settings[key]` by hand. Use `Registry`/`SearchRegistry` for UI provider/search CRUD, not `settings:saveSetting("ui_providers"/"ui_search_tools", ...)`.

## Tips for AI Agents

- **English polish**: the developer isn't a native speaker; correct wording into idiomatic English while preserving intent (e.g. "bleeding-edge code").
- **Secrets**: never read/modify `configuration.lua` (gitignored, holds keys); update `configuration.sample.lua` only (see Config above). Exclude `l10n/` from code searches/reads (40+ languages, no code insight).
- **New providers & tool calling**: OpenAI-compatible → alias `OpenAIHandler:new{name="..."}`; custom auth/shape → extend `BaseHandler` (`query`/`SyncOptions`/`FetchModels`) and route parsing through `self:parseToolCalls(...)`. Route all tool-call logic through `ToolExecutor` — it already normalizes the three wire formats; don't duplicate per-provider.
- **Registry/Search lifecycle**: do all UI provider/search CRUD via `Registry`/`SearchRegistry`; never manipulate `settings:saveSetting("ui_providers"/"ui_search_tools", ...)` directly.
- **Ask dialog checkbox layout** (`assistant_dialog.lua`): side-by-side rows `HorizontalGroup{ HorizontalSpan(left_gap) + CheckButton(width=half_w) + HorizontalSpan(gap) + CheckButton(width=half_w) }`. Each `CheckButton` needs explicit `width = half_w` or it overflows (`checkbutton.lua:77`). Left inset `left_gap = (dialog_width - available_w - input_extra)/2` where `input_extra = 2*(Size.border.inputtext + Size.padding.small + Size.margin.default)` — aligns to the InputText border, don't hardcode `Size.padding.large`. Actual labels are emoji-prefixed: `✉ Attach Prior Text`, `✎ Current Chapter Only`, `🌐 Web Search`, `⌨ Copy to Clipboard`.
- **Menu markers**: `main.lua` locates TouchMenu items via `assistant_item_id` markers — `assistant_ai_menu`, `assistant_settings`, `assistant_add_provider`. MenuSorter keeps references, so markers survive building; keep them when moving/renaming. Conditional items (e.g. `Custom Prompts`) are safe. The `Provider API` item is added via `Registry.getAddProviderMenuItem` and users navigate to it through the main menu path: Settings -> AI Assistant -> Settings -> Provider API.
- **Hand-built dialogs (no input field)**: `InputDialog` **always** creates and renders an `InputText` — there is no flag to hide it. For checkbox-only / pure-picker forms, build the widget tree by hand instead (see `Registry.showParametersDialog` in `assistant_provider_registry.lua`). Recipe and pitfalls learned there:
  - **Paint hooks are mandatory**: a bare `InputContainer` is never painted. Set `modal = true` and define `onShow` / `onCloseWidget` callbacks that call `UIManager:setDirty(self/nil, function() return "ui", movable.dimen end)` — mirroring `ConfirmBox`/`InputDialog`. Without them the dialog silently never appears.
  - **Children must be positional**: widget containers traverse `[1]`, `[2]`, …; writing `MovableContainer:new{ frame = FrameContainer:new{...} }` stores children in the hash part and renders nothing. Construct sub-widgets into locals first, then pass them positionally.
  - **Composition** (mirror `ConfirmBox`/`SettingsDialog`): `CenterContainer(full-screen Geom) → MovableContainer → FrameContainer(background COLOR_WHITE, radius/border) → VerticalGroup{ TitleBar, content widgets…, CenterContainer(ButtonTable) }`. Keep `frame`/`movable` in locals upvalue-captured by the dirty callbacks.
  - **CheckButton needs an explicit `width`** when its parent has no `getAddedWidgetAvailableWidth()` (it dereferences `parent:getAddedWidgetAvailableWidth()` otherwise).
  - **Never store widget references on module-level tables** (e.g. writing `item.checkbox = ...` back onto a shared catalog): it pins the whole closed dialog tree in memory and leaks state across dialog instances. Keep widget refs in locals.
  - **Declare locals before closures that use them**: button callbacks (e.g. Save) built in a `buttons` table close over dialog locals; if the local is declared *after* the buttons table, the callback silently captures a nil **global** and crashes only when the button is tapped (`attempt to index global 'x' (a nil value)`). Declare shared locals (`dialog`, checkbox tables, …) above any closure that references them, and note why.
  - **Missing children crash at first paint, not construction**: a stale/nil child reference (e.g. left over from a refactor, like `item.checkbox` renamed to a `checkboxes[i]` local) leaves a container without `[1]`; construction succeeds and the crash surfaces only on repaint (`framecontainer.lua:55 self[1]:getSize()`). Reproduce with a runui script: show the dialog, then `UIManager:scheduleIn(2, function() UIManager:forceRePaint(); UIManager:quit() end); UIManager:run()` — and exercise button callbacks programmatically (`button_table:getButtonById("save").callback()`) to cover tap-time paths headlessly.
- **KOReader widget internals**: only as a last resort. Check the public API first, then read the widget source under `/usr/lib/koreader/frontend/ui/widget/` to trace the `widget[1]`/`[2]` tree; swap a sub-widget and nil `_size`/`_offsets`/`dimen` up the tree to re-layout. Always comment the widget-tree path.
- **UI patterns & reference**: reuse existing dialog/widget scaffolding (`ChatGPTViewer`, `assistant_dialog.lua`) rather than building new widget trees. KOReader UI is niche — when touching plugin UI/widget code, scan `/usr/lib/koreader/frontend/ui/widget/` and `/usr/lib/koreader/plugins/` for reference patterns before writing new layouts.
