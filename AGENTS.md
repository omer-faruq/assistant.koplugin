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

- **No build step** — Lua files are executed directly by KOReader.
- **Syntax check** (LuaJIT): `/usr/lib/koreader/luajit -e "assert(loadfile('main.lua'))"`
- **Syntax check** (standard Lua): `luac -p <file>.lua` — catches basic errors but not LuaJIT-specific constructs.
- **Do NOT use** `luajit -bl` (bytecode listing) — KOReader's stripped LuaJIT lacks the `jit.*` modules.
- **Translation check**: `cd l10n && make check` — validates all `.po` files with `msgfmt`.

### Test Framework

A headless test framework lives under `test/`. It runs inside the KOReader LuaJIT runtime with KOReader's `setupkoenv.lua` and mocks for UI modules.

**Run all tests:**
```bash
./test/run.sh
```

**Run a single module:**
```bash
./test/run.sh exttools
```

**Structure:**
- `test/run.sh` — Shell entry point. `cd`s to `/usr/lib/koreader` so `setupkoenv.lua` relative paths resolve, then invokes `test/run_tests.lua`.
- `test/run_tests.lua` — Lua test runner. Requires `setupkoenv`, adds the project root to `package.path`, discovers registered test files, runs them, and prints a summary. Exits non-zero on failure.
- `test/test_helper.lua` — Stubs KOReader UI/widget modules, mocks `fetchJSON`, provides `assert.*` helpers (`equal`, `notNil`, `isTrue`, `isFalse`, `matches`, `notMatches`), and a `runTests(name, tests)` runner.
- `test/test_*.lua` — Per-module test files. Each returns the result of `helper.runTests(...)`.

**Adding a new test file:**
1. Create `test/test_<module>.lua` following the `test_exttools.lua` pattern.
2. Register it in `test/run_tests.lua`'s `test_files` table.
3. Run `./test/run.sh` to verify.

**CI:** The `test/` directory is excluded from release zip archives and OTA update packages. It is source-only, not shipped to end users.

**Testing policy:** When adding new functions or logic, write a test for it. If the function is already exported from its module, require it in the test file normally. If the function is a local/closure not exported, inline a copy of it in the test file as a snippet and test the snippet — this is acceptable for pure functions where the logic is the test target. The goal is to catch regressions, not to enforce module structure.

## Architecture

This is a KOReader plugin (`assistant.koplugin`) that adds AI assistant functionality to e-readers. It supports 10+ AI providers (Anthropic, OpenAI, Gemini, DeepSeek, Ollama, Groq, Mistral, GigaChat, OpenRouter, Gemma) and the OpenAI Responses API, plus features like translations, summaries, book X-Ray/Recap, a LexRank-based Term X-Ray, web-search tool calling, quick notes, and custom prompts.

### Entry & Core Orchestration
- **`main.lua`** — Plugin init (`Assistant:init`), menu registration, dispatcher actions/gestures, translate-override hook, auto-recap hook, dictionary-popup button registration.
- **`_meta.lua`** — Plugin name/version/description. Version is manually bumped on `main` after a release tag is applied (see Versioning below). The CI release workflow rewrites it from the tag name during zip packaging.
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

### Provider Registry

- **`assistant_provider_registry.lua`** (`Registry`) — Manages UI-added AI providers stored in KOReader settings as JSON (`settings:saveSetting("ui_providers", json)`). Providers added via the Add Provider dialog use this registry; file-based providers live in `configuration.lua`.
- **Two-source merge**: On startup, `Registry.load(settings)` reads UI providers, then `Registry.merge(file_config, ui_data)` combines them with file providers into `CONFIGURATION.provider_settings`. File providers get `source="file"`, `immutable=true`; UI providers get `source="ui"`.
- **Provider ID scheme**: UI providers use stable IDs `"custom:N"` (auto-incrementing). File providers keep their original key from `configuration.lua`.
- **Validation**: `Registry.validate(record)` checks `display_name`, `handler` (must match an `api_handlers/` file), `model` (defaults to `"auto"`), `base_url` (must be `http(s)://`), `api_key`.
- **`Registry.installProvider(assistant, …)`** — Add + save + update in-memory config + load into querier in one call.
- **`Registry.delete(data, id)`** and **`Registry.is_deletable(provider)`** — Only `source=="ui"` providers are deletable.
- **`display_name`**: File providers can set `display_name` in their `configuration.lua` entry; UI providers require it. The Settings radio and main menu show `display_name` as the provider label.

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
- **`assistant_model_picker.lua`** — Paginated/searchable model picker (calls `handler:FetchModels()`). Exports `showPickerDialog` for external reuse; accepts an optional `on_select` callback to customize the selection result.
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
| `assistant_provider_registry.lua` | UI provider add/delete/merge/validate, JSON settings storage |
| `configuration.sample.lua` | Config template — update this, not `configuration.lua` |
| `l10n/` | Translation files (`.po`/`.pot`), Makefile, AI translation script |
| `.github/workflows/release.yml` | CI/CD: auto-release on `v*` tag push |

## Coding Conventions

- **Language**: Lua 5.1 / LuaJIT 2.1. KOReader bundles LuaJIT — use `string.buffer` over repeated concatenation for performance-sensitive string building.
- **Naming**: modules use `snake_case`; classes use `PascalCase`; methods use `camelCase`; constants use `UPPER_CASE`.
- **Error handling**: Functions return `nil, err` on failure (or `false, err` for HTTP calls). Callers check the first return value.
- **OOP pattern**: Lua metatable-based inheritance — `BaseHandler:new{...}` creates instances, `setmetatable(o, self)` with `self.__index = self` for class-like behavior.
- **Localization**: All user-facing strings wrapped in `_("text")`. Import with `local _ = require("assistant_gettext")`. Plural forms use `N_("1 item", "%1 items", n)`.
- **Rich Text & Formatting**: Use `assistant_utils.bold_format(...)` with `<b>` and `</b>` tags (e.g. `assistant_utils.bold_format(T(_("<b>Header:</b> %1"), val))`) to format bold runs in dialogs. Avoid manual string concatenation; keep strings contiguous inside `T(_("..."))` templates so they remain easy to translate.
- **Configuration access**: Use `koutil.tableGetValue(CONFIGURATION, "path", "to", "key")` for safe nested access with defaults.
- **Metadata on messages**: Use `assistant_utils.set_attr(msg, key, value)` / `get_attr(msg, key)` for fields that must not be serialized into API request bodies (e.g. `use_websearch`, `is_context`, `search_keywords`).
- **JSON null handling**: Always use `require("rapidjson")` — this is the one JSON library for the project. KOReader's bundled `rapidjson` represents JSON `null` as a userdata value (`rapidjson.null`), not Lua `nil`. To avoid null-related bugs:
  1. Prefer `rapidjson.decode(str, {null=nil})` to convert JSON nulls to Lua `nil` at decode time.
  2. When that's not suitable, check with `if value == nil or value == rapidjson.null then` before using a decoded value.
  3. Use `assistant_utils.json_default(value, default)` when reading a nullable field and you need a fallback. This helper handles both `nil` and `rapidjson.null` in a single call.
  4. Never introduce another JSON library (e.g. `dkjson`, `cjson`, `lunajson`) — mixing JSON implementations leads to incompatible null representations and subtle bugs.

## Git Workflow

- **Branch**: `main` is the default branch.
- **Commit style**: Conventional commits — `fix:`, `refactor:`, `add:`, `feat:` prefixes.
- **Releases**: Tag with `v*` (e.g. `v1.12`). The CI workflow rewrites `_meta.lua` version and creates a zip release asset.

### Versioning

- **`_meta.lua`** holds the current development version (the *next* release).
- When a release is ready:
  1. Tag the commit that represents the current version. Example: if `_meta.lua` says `"1.14"`, tag that commit as `v1.14`.
  2. Bump the version in `_meta.lua` to the next number (e.g. `"1.15"`) and commit with `chore: bump version to 1.15`.
- The CI workflow rewrites `_meta.lua` from the tag name during zip packaging, so the released artifact gets the correct version regardless of what's on `main`.
- **AI agents**: when asked to tag a release, tag the commit matching the current `_meta.lua` version, then bump `_meta.lua` and commit the bump.

## CI/CD

- **Trigger**: Push of a `v*` tag (e.g. `v1.2.3`).
- **Workflow** (`.github/workflows/release.yml`):
  1. Checkout code
  2. Rewrite `version` in `_meta.lua` from the tag
  3. Archive project into `assistant.koplugin-<tag>.zip` (excluding dotfiles, `.md` files, and non-`.po` files in `l10n/`)
  4. Create a GitHub pre-release with the zip as asset
- No tests run in CI — testing is manual in KOReader.

## Translation Management

Translation scripts in `l10n/` are run manually by developers. **AI agents should not run them or create translation-update tasks** — do not invoke `make template`, `make update`, `make translate`, or `make ai-translate` as part of code changes. Only `make check` may be used to validate `.po` syntax when explicitly requested.

For reference, the developer-facing commands are:

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
- **Provider config keys**: file providers use `{handler}_{description}` as key (e.g. `openai_perplexity`). UI providers use `"custom:N"`. Use `Registry` for all UI provider CRUD; never manipulate `settings:saveSetting("ui_providers", ...)` directly.
- **`display_name`**: always set this field on provider records. Settings UI and the main menu label use `display_name` (not the config key). File providers can add `display_name` to their `configuration.lua` entry.
- **UI provider lifecycle**: `main.lua` `init()` does `Registry.load` → `Registry.merge` → effective `CONFIGURATION`. Add dialog calls `Registry.installProvider`. Delete calls `Registry.delete` + `Registry.save`. Consult `assistant_provider_registry.lua` before touching provider storage.
- **Tool calling**: route all tool-call logic through `assistant_tool_executor.lua`'s `ToolExecutor` — it already normalizes the three wire formats. Don't duplicate per-provider.
- **LexRank**: read `LEXRANK_LANGUAGES.md` before adding or modifying a language module.
- **UI**: use existing dialog patterns from `assistant_dialog.lua` / `assistant_viewer.lua` (`ChatGPTViewer`) rather than building new widget scaffolding.
- **UI testing with wbuilder**: KOReader provides a widget builder (`tools/wbuilder.lua` in upstream, run via `./kodev wbuilder`) to test widgets in isolation without starting the full reader. This project has its own `test/wbuilder.lua` that bootstraps the KOReader UI framework and plugin path. Run a widget test with:
  ```bash
  ./test/runui.sh model_picker
  ```
  To simulate a specific device screen size (compatible with `kodev run` semantics):
  ```bash
  ./test/runui.sh -w=1072 -h=1448 -d=300 model_picker
  ./test/runui.sh -s=kobo-clara model_picker
  ```
  Add a test script under `test/` that requires `test/wbuilder`, shows widgets with `UIManager:show(...)`, and finishes with `UIManager:run()`. Use mock objects for `assistant` when the widget depends on plugin state.
- **Dependencies**: no external dependencies beyond KOReader's standard libraries. The optional `hoedown` native library is the only exception, with a pure-Lua fallback.
- **License**: GPL-3.0 (see `LICENSE`).
