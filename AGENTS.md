# AGENTS.md

Guidance for AI agents working in `assistant.koplugin` (KOReader AI assistant plugin). **Keep this file short** — deep guidance lives in `docs/` and is loaded on demand. Read the relevant doc before editing:

| Before you touch… | Read |
|---|---|
| tests, stubs, headless behavior, test runner | `docs/TESTING.md` |
| modules, request flow, handlers, config | `docs/ARCHITECTURE.md` |
| provider/search registry, UI settings CRUD | `docs/REGISTRIES.md` |
| dialogs, widgets, layout | `docs/UI_DIALOGS.md` |

## Environment

- Debian/Ubuntu. Install KOReader from the official `.deb`; the runtime lands at `/usr/lib/koreader/`.
- Read `/usr/lib/koreader/` (`frontend/`, `plugins/`, the bundled `luajit`) for upstream APIs and reference implementations — **never modify anything there**.
- `configuration.lua` is gitignored and holds real secrets: **never read or modify it**. Update `configuration.sample.lua` instead.

## Build / Test / Lint

- No build step; Lua files run directly.
- Syntax: `/usr/lib/koreader/luajit -e "assert(loadfile('main.lua'))"`. **Never** `luajit -bl` (stripped build lacks `jit.*`).
- Tests: `./test/run.sh` (all) or `./test/run.sh <module>`. UI: `./test/runui.sh <name>`. Translation: `cd l10n && make check` (only when explicitly requested). Full detail: `docs/TESTING.md`.
- Run `./test/run.sh` before committing — CI ships without running tests.

## Architecture (map)

- `main.lua` — plugin entry, dispatcher actions/gestures, menu + popup hooks.
- `assistant_querier.lua` — query engine: handler loading, stream/SSE, web-search tool loop (max 3 rounds).
- `api_handlers/` — one file per wire format; `base.lua` = `BaseHandler`; `openai`/`anthropic`/`gemini`/`responses` are UI-selectable, deltas/wrappers are not.
- `assistant_tool_executor.lua` — normalizes tool calls across the three wire formats; `assistant_exttools.lua` — search API clients.
- `Registry` / `SearchRegistry` — UI provider/search CRUD + JSON settings.
- `assistant_config.lua` — owns the effective `CONFIGURATION`.
- UI: `assistant_dialog.lua`, `assistant_viewer.lua`, `assistant_featuredialog.lua`, `assistant_dictdialog.lua`, `assistant_settings.lua`, `assistant_model_picker.lua`, `assistant_quicknote.lua`, `assistant_mdparser.lua`.
- `assistant_sentence_splitter.lua` — language-aware sentence splitting + language detection; `assistant_term_xray.lua` — term-anchor (keyword-in-context) extraction.
Full flow, handlers, config, key files: `docs/ARCHITECTURE.md`.

## Invariants (never break)

1. **Config**: read/write `CONFIGURATION` only via `assistant.config` getters/mutators; UI provider/search CRUD only via `Registry`/`SearchRegistry`. Never touch `settings:saveSetting("ui_providers"/"ui_search_tools", ...)`.
2. **JSON**: `rapidjson` only (never `dkjson`/`cjson`); `null` is `rapidjson.null` — compare `== nil or == rapidjson.null`, fall back via `assistant_utils.json_default`.
3. **Nested reads**: use `assistant.config:get*` or `koutil.tableGetValue(t, ...)` (also for API responses, incl. numeric keys). Never `t and t.foo and t.foo.bar` — it crashes on malformed shapes. `koutil.tableMerge(t1,t2)` mutates `t1` and returns nil.
4. **gettext**: wrap every user-facing string in `_()`; msgids must be US-ASCII — replace Unicode punctuation with ASCII (`-` not `—`, `...` not `…`) and inject all non-ASCII glyphs (emoji, arrows, symbols) **outside** `_()` via `T()` placeholders or concatenation. Plurals via `N_()`; keep strings contiguous inside `T(_("..."))`. Guarded by `test/test_gettext_ascii_msgids.lua`.
5. **Never use `_` as a discarded loop variable** (`for _, x in ...`): it shadows the gettext function and crashes `_()` calls in the loop body. Guarded by `test/test_gettext_loop_shadow.lua`.
6. **Dialogs**: cancellation/close on the **left**, action buttons (Save/OK) on the **right**. Title Case labels; short words (`to`, `for`, `as`, `and`, `in`) lowercase.
7. **Notifications**: `Notification:notify(msg, Notification.SOURCE_ALWAYS_SHOW)` only for transient success; errors/failures/ack → `UIManager:show(InfoMessage:new{...})`.
8. **Credentials**: UI-entered `api_key`/`base_url` are trimmed and internal whitespace rejected in `Registry.validate`/`SearchRegistry.validate`. Normalize there — not per handler, not at header build.
9. **No backward compatibility for internal code**: move code and update every call site in one go; no `Deprecated` wrappers. `require` the owning module directly (one hop); split by domain and keep module responsibilities explicit.
10. **Style**: Lua 5.1 / LuaJIT 2.1; use `string.buffer` for hot loops. 4 spaces, never tabs (vendored `lib/` keeps upstream formatting); `snake_case` modules, `PascalCase` classes, `camelCase` methods, `UPPER_CASE` consts. Errors return `nil, err`.
11. **Directions/formatting**: `T = require("ffi/util").template`; bold via `assistant_utils.bold_format(T(_("<b>Header:</b> %1"), val))`; message metadata via `assistant_utils.set_attr`/`get_attr`.
12. **Scope**: exclude `l10n/` from code searches/reads (40+ languages, no code insight). Polish non-native English wording into idiomatic English without changing intent.
13. **Widgets**: reuse existing scaffolding (`ChatGPTViewer`, `assistant_dialog.lua`); read `docs/UI_DIALOGS.md` before hand-building dialogs. KOReader widget internals only as a last resort.

## Git / Versioning

- `main`; Conventional Commits (`fix:`, `refactor:`, `add:`, `feat:`). Commit directly when asked, with a concise message.
- `_meta.lua` holds `X.Y-dev`. Release: tag `vX.Y` on the matching commit; CI rewrites the packaged `_meta.lua` from the tag (repo stays `X.Y-dev`), then bump the repo to `X.(Y+1)-dev` and commit.
- CI (`.github/workflows/release.yml`) builds the zip using `.releaseignore`, creates a GitHub pre-release, and runs **no tests**. `.releaseignore` already excludes `*.md`, `test/`, `docs/`, `.github/`, `l10n` sources (the OTA updater reads the same file).

## Translation

- Translation scripts are developer-run: **never** run `make template/update/translate/ai-translate`. Only `make check` when explicitly requested.
- Domain `assistant` (`assistant.pot`/`.po`/`.mo`); MO files are committed. See `l10n/Makefile`.
