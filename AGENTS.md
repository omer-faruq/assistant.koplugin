# AGENTS.md

Guidance for AI agents working in `assistant.koplugin` (KOReader AI assistant plugin). **Keep this file short** — deep guidance lives in `docs/` and is loaded on demand. Read the relevant doc before editing:

| Before you touch… | Read |
|---|---|
| tests, stubs, headless behavior, test runner | `docs/TESTING.md` |
| modules, request flow, handlers, config | `docs/ARCHITECTURE.md` |
| provider/search registry, UI settings CRUD | `docs/REGISTRIES.md` |
| dialogs, widgets, layout | `docs/UI_DIALOGS.md` |
| translations, `l10n/*.po`, `l10n/helper/*.py`, gettext, msgids | `l10n/README.md` |

## Environment

- Debian/Ubuntu. Install KOReader from the official `.deb`; the runtime lands at `/usr/lib/koreader/`.
- The plugin targets the latest KOReader stable only, currently `2026.07.1`. If the local install differs, fix the environment first — never adapt code to old or hypothetical upstream behavior.
- Read `/usr/lib/koreader/` (`frontend/`, `plugins/`, the bundled `luajit`) for upstream APIs and reference implementations — **never modify anything there**.
- `configuration.lua` is gitignored and holds real secrets: **never read or modify it**. Update `configuration.sample.lua` instead.

## Build / Test / Lint

- No build step; Lua files run directly.
- Syntax: `/usr/lib/koreader/luajit -e "assert(loadfile('main.lua'))"`. **Never** `luajit -bl` (stripped build lacks `jit.*`).
- Tests: `./test/run.sh` (all) or `./test/run.sh <module>`. UI: `./test/runui.sh <name>`. Translation: `cd l10n && make check` (only when explicitly requested). Full detail: `docs/TESTING.md`.
- Before committing: `./test/run.sh`, then `./test/run_diagnose.sh` (lua-language-server scan; skips when absent) — CI ships without running tests.

## Architecture (map)

- `main.lua` — slim plugin entry (dispatcher actions, init, 1-line delegates).
- `feature/book_actions.lua` — book features, identification flow, FileManager long-press row.
- `core/querier.lua` — query engine: handler loading, stream/SSE, web-search tool loop (max 3 rounds).
- `api_handlers/` — one file per wire format; `base.lua` = `BaseHandler`; `openai`/`anthropic`/`gemini`/`responses` are UI-selectable, deltas/wrappers are not.
- `core/tool_executor.lua` — normalizes tool calls across the three wire formats; `core/exttools.lua` — search API clients.
- `Registry` / `SearchRegistry` — UI provider/search CRUD + JSON settings.
- `core/config.lua` — owns the effective `CONFIGURATION`.
- Shared utils: `utils/text.lua` (text/render), `utils/net.lua` (HTTP/fetch), `utils/doc.lua` (book/page extraction, online guard, field trim); `utils/base.lua` is the slim core (`PLUGIN_DIR`, attrs, JSON default).
- UI: `dialogs/dialog.lua`, `dialogs/viewer.lua`, `dialogs/feature.lua`, `dialogs/dict.lua`, `dialogs/provider.lua`, `dialogs/settings_menu.lua`, `dialogs/model_picker.lua`, `dialogs/quicknote.lua`, `dialogs/mdparser.lua`, `dialogs/css.lua`.
- `feature/term_xray.lua` — sentence splitting + term-anchor (keyword-in-context) extraction; `feature/lookup.lua` — selection routing; `feature/notebook.lua` — notebook viewer.
Full flow, handlers, config, key files: `docs/ARCHITECTURE.md`.

## Core Principles

- **Dependencies first**: lean on what is already in the project or upstream before writing your own implementation or adding packages. Check docs and type definitions first; do not assume a library lacks a capability.
- **Long-term decisions**: make architectural decisions for the long term. No stopgaps that only work for now and are meant to be replaced later.
- **Mature patterns first**: before designing a solution, study how mature products solve the same problem - especially KOReader's existing plugins and widgets - and adopt their proven patterns instead of inventing from scratch.

## Refactoring and Compatibility

- The plugin ships and updates atomically: never preserve backward compatibility for internal interfaces.
- Target latest KOReader only: never code against old or hypothetical upstream APIs, and never add version fallbacks.
- Internal modules may be freely refactored, renamed, or deleted. Do not add compatibility shims, fallbacks, or migration layers for internal-only code; update every call site in one go.
- Comments describe what the code is now, never its change history (no "moved from X", "formerly", "no shim left"). Objective and brief: state what the current code does, not how it got that way (no "now allows", "used to", "instead of"); the commit message owns the why.
- Keep comments short: a `---` doc comment states the contract in 1-3 lines; inline comments only where the code cannot speak for itself. Delete comments that restate the code; never narrate history or process.

## Invariants (never break)

1. **Config**: read/write `CONFIGURATION` only via `assistant.config` getters/mutators; UI provider/search CRUD only via `Registry`/`SearchRegistry`. Never touch `settings:saveSetting("ui_providers"/"ui_search_tools", ...)`.
2. **JSON**: `rapidjson` only (never `dkjson`/`cjson`); `null` is `rapidjson.null` — compare `== nil or == rapidjson.null`, fall back via `utils/base.json_default`.
3. **Nested reads**: use `assistant.config:get*` or `koutil.tableGetValue(t, ...)` (also for API responses, incl. numeric keys). Never `t and t.foo and t.foo.bar` — it crashes on malformed shapes. `koutil.tableMerge(t1,t2)` mutates `t1` and returns nil.
4. **gettext**: wrap every user-facing string in `_()`; msgids must be US-ASCII — replace Unicode punctuation with ASCII (`-` not `—`, `...` not `…`) and inject all non-ASCII glyphs (emoji, arrows, symbols) **outside** `_()` via `T()` placeholders or concatenation. Msgids carry only human-readable words plus the custom `<b>` tag (parsed by `bold_format`, not real HTML) — never real HTML/markup; build real markup with `T()` placeholders or concatenation outside `_()` (e.g. `T(_("<b>Header:</b> %1"), val)` vs `T('<div>%1</div>', _("Text"))`). Plurals via `N_()`; keep strings contiguous inside `T(_("..."))`. Guarded by `test/test_gettext_ascii_msgids.lua`.
5. **Never use `_` as a discarded loop variable** (`for _, x in ...`): it shadows the gettext function and crashes `_()` calls in the loop body. Guarded by `test/test_gettext_loop_shadow.lua`.
6. **Dialogs**: cancellation/close on the **left**, action buttons (Save/OK) on the **right**. Title Case labels; short words (`to`, `for`, `as`, `and`, `in`) lowercase.
7. **Notifications**: `Notification:notify(msg, Notification.SOURCE_ALWAYS_SHOW)` only for transient success; errors/failures/ack → `UIManager:show(InfoMessage:new{...})`.
8. **Credentials**: UI-entered `api_key`/`base_url` are trimmed and internal whitespace rejected in `Registry.validate`/`SearchRegistry.validate`. Normalize there — not per handler, not at header build.
9. **Module structure**: `require` the owning module directly (one hop); split by domain and keep module responsibilities explicit.
10. **Style**: Lua 5.1 / LuaJIT 2.1; use `string.buffer` for hot loops. 4 spaces, never tabs (vendored `lib/` keeps upstream formatting); `snake_case` modules, `PascalCase` classes, `camelCase` methods, `UPPER_CASE` consts. Errors return `nil, err`.
11. **Directions/formatting**: `T = require("ffi/util").template`; bold via `utils/text.bold_format(T(_("<b>Header:</b> %1"), val))`; message metadata via `utils/base.set_attr`/`get_attr`.
12. **Scope**: exclude `l10n/` from code searches/reads (40+ languages, no code insight). Polish non-native English wording into idiomatic English without changing intent.
13. **Widgets**: reuse existing scaffolding (`ResultViewer`, `dialogs/dialog.lua`); read `docs/UI_DIALOGS.md` before hand-building dialogs. KOReader widget internals only as a last resort.
14. **Upstream helpers**: when a helper exists in `/usr/lib/koreader/` (`frontend/`, `ffi/util`, plugins), reuse it; drop the replaced local helper outright.
15. **Thin delegates**: `main.lua` keeps only KOReader entry points (init, addToMainMenu, onDispatcherRegisterActions, onClose, onFlushSettings, on* event handlers, isConfigured); all other logic lives in owning modules and is invoked directly; no thin Assistant delegates. Where a top-level require would cycle (settings_menu<->provider_registry/search_registry/provider) or break headless loads (hooks/settings_menu), use function-local inline require following existing precedent.
16. **EmmyLua annotations**: new functions with more than 3 params must document every param/return in `---` EmmyLua style (`@param name type desc`, `@return type desc`), as in `utils/net.fetchJSON`.

## Git / Versioning

- `main`; Conventional Commits, one topic per commit. Commit directly when asked. Prefixes: `fix:` (defect), `refactor:` (behavior-preserving restructure), `add:` (new capability or tooling), `feat:` (user-visible feature), `test:` (tests only), `docs:` (documentation, including comment-only changes).
- History rewrite: amend small same-topic follow-ups into the unpushed tip commit; once a commit is pushed, never rewrite it - append a new commit instead.
- Subject line: imperative mood, lowercase first word, no trailing period (`fix: stop API connection tests failing on reasoning models`). Two facets of one change join with `;` (`add: fail closed on an unrecognized web-search key; one credential per tool`).
- Body after a blank line, wrapped at ~76 columns: lead with **why** (the defect or rule behind the change), then what changed. Prose paragraphs for `fix:`/`add:`/`refactor:`/`feat:`; `- ` bullets when the commit covers several topics (`docs:`, `test:`). ASCII only (`->`, `-`, `...`).
- `_meta.lua` holds `X.Y-dev`. Release: tag `vX.Y` on the matching commit; CI rewrites the packaged `_meta.lua` from the tag (repo stays `X.Y-dev`), then bump the repo to `X.(Y+1)-dev` and commit.
- CI (`.github/workflows/release.yml`) builds the zip using `.releaseignore`, creates a GitHub pre-release, and runs **no tests**. `.releaseignore` already excludes `*.md`, `test/`, `docs/`, `.github/`, `l10n` sources (the OTA updater reads the same file).

## Translation

- Translation scripts are developer-run: **never** run `make template/update/translate/ai-translate`. Only `make check` when explicitly requested. `make stats` is read-only (per-language DONE%/FUZZY/UNTRANSLATED table) — after changing many user-facing strings, run it and report the pending load (languages affected, remaining entries) to the developer.
- **Never hand-edit a `.po` to correct a translation — empty the msgstr** and let the next `make` refill it. `translate_file()` only fills *empty* msgstr, so a hand-patched or wrong-language string counts as done forever; a wrong `sk` catalogue shipped Slovenian for 13 `l10n: update translate` runs. Wrong-slot answers (lost `<b>` markup or a ghost `%N` no source form has) are rejected at request time by `helper/ai_translate.py`; run `make check-langs` (offline static-table check via `./helper/ai_translate.py --check-data`) after changing msgids or language tables. Wrong-language or wrong-meaning entries are surfaced by the optional `sk`-only LLM reviewer, `helper/review_translations.py`.
- Per-locale terminology, style and confusion warnings belong in `l10n/<lang>/ai_note.txt` (appended to the prompt), not in the helper scripts. An endonym alone is not a safe language identifier for a model: `LANG_MAP` said `Slovenčina` for `sk`, which is correct Slovak but reads as "Slovene", so Slovak came back in Slovenian. `LANG_EN` supplies the English name that anchors it.
- Domain `assistant` (`assistant.pot`/`.po`/`.mo`); MO files are committed. See `l10n/Makefile` and `l10n/README.md`.
