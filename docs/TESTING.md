# Testing

The suite runs inside KOReader's LuaJIT runtime via `setupkoenv` with UI modules mocked, so no device or GUI is needed.

## Commands

- All modules: `./test/run.sh`
- Single module: `./test/run.sh exttools` (substring match on the `test_*.lua` name)
- Syntax (LuaJIT): `/usr/lib/koreader/luajit -e "assert(loadfile('main.lua'))"` — **never** `luajit -bl` (the stripped build lacks `jit.*`)
- Standard Lua: `luac -p file.lua` (basic errors only, not LuaJIT constructs)
- UI widget test: `./test/runui.sh model_picker` (add `-w=1072 -h=1448 -d=300` or `-s=kobo-clara` to simulate a device)
- Visual/screenshot test: `SDL_VIDEODRIVER=dummy ./test/runui.sh ui/<script>` (see [Visual verification](#visual-verification-preferred-over-source-scans))
- Translation (only when explicitly requested): `cd l10n && make check`
- Before committing: `./test/run.sh` — CI ships without running tests.

## How it works

- `test/run.sh` `cd`s to `/usr/lib/koreader`, then runs `test/run_tests.lua`, which requires `setupkoenv`, adds the project root to `package.path`, discovers `test/test_*.lua` **alphabetically**, and exits non-zero on failure.
- `test/helper.lua` stubs UI/widget modules, mocks `fetchJSON`, and exposes `assert.*` (`equal`, `notNil`, `isTrue`, `isFalse`, `matches`, `notMatches`) plus `runTests(name, tests)`.
- Each test file must end with `return helper.runTests("<name>", tests)`.

### `runTests` return contract (footgun)

`runTests` returns a **single result table** `{ passed, failed, errors }`, not multiple values. Lua 5.1's `require()` propagates only the first return value, so multiple returns would silently drop the failure counts and the runner would always report `0 failed` and exit `0`. If you change the contract, update `test/run_tests.lua` together with every `test/test_*.lua`.

## Adding a test

- Create `test/test_<module>.lua` following `test/test_exttools.lua`; auto-discovered, no registration.
- Keep files independent — they run alphabetically in one shared process.
- Policy: when adding logic, write a test that calls the shipped code. `require` the owning module; if the logic is a local in `main.lua` or a widget, **extract it into its own module** rather than copying it. An inlined copy tests the copy, not the plugin: it stays green when production breaks and rots silently (two such copies in this repo had already drifted from the code they claimed to guard). Only fall back to a source scan when the code is genuinely unreachable headlessly, and say so in the test's header.
- **Never assert on source text** (`io.open` + `src:find`, magic character windows) to stand in for behavior. Such a test breaks on a rename that preserves behavior and passes when the feature is deleted. If the target is unreachable headlessly, either shim the load chain (see `test/test_filemanager_bookinfo.lua`) or verify it visually (see below) — do not grep.
- `test/` is excluded from release zips/OTA packages — source only, never shipped.

## Test-code cleanup (proportionality)

- Test code must be proportionate to the change it guards: a small fix does not earn large scaffolding. When a change carries more test code than production code, cut back to the smallest check that can go red — or to none at all when the maintainer accepts the trade-off.
- Verification aids written to eyeball a fix (screenshot scripts, throwaway repro scripts) are deleted once the fix is confirmed and never committed. The permanent demos (`./test/runui.sh <name>`) are the manual re-check path.
- A dropped guard is a deliberate trade-off, not an oversight: say so in the commit message, and only bring a guard back when the behavior bites again.

## Stub discipline

- A new `require` chain reaching a real KOReader widget module crashes the headless suite (the empty `android` stub makes `device.lua` pick the Android impl). Add a stub in `helper.lua`'s `stubs` table when one is pulled in: `device` needs `screen = { getWidth/getHeight }` for layout math; `buttontable`/`titlebar`/containers can be `{}`.
- Beware **duplicate keys in the `stubs` table constructor — the last entry silently wins**. Check for duplicates when adding a stub that already exists.

## Headless pitfalls

- `G_reader_settings` is a global created by `setupkoenv` / `run_tests.lua`. A bare `luajit -e "require('assistant_utils')"` outside `./test/run.sh` fails with `attempt to index global 'G_reader_settings' (a nil value)` (the `device`/`fontlist` chain). Verify modules via `assert(loadfile(...))` (syntax) or `./test/run.sh` (runtime); do **not** `require` UI-touching modules with raw `luajit -e`.
- Prefer `assistant_utils.PLUGIN_DIR` over `DataStorage:getDataDir().."/plugins/..."` directly; the latter diverges under `MULTIUSER`/extra_plugin_paths.

## Static guards

Some invariants are enforced by source-scanning tests rather than runtime checks:

- `test/test_gettext_loop_shadow.lua` — no `_()` call inside a `for _,` loop body (`_` gets shadowed by the loop variable).
- `test/test_gettext_ascii_msgids.lua` — every `_()`/`N_()`/`C_()`/`NC_()` msgid is US-ASCII. Non-ASCII msgids trigger gettext's msgattrib header-loss bug and corrupt glyphs (commit `0353186`); the offenders spanned U+2011 (‑) through U+1F4A1 (💡). Put Unicode punctuation/symbols/emoji outside `_()`.

## UI test scripts

`test/wbuilder` bootstraps the KOReader UI framework and plugin path for isolated widget tests. A UI test requires `test/wbuilder`, shows widgets with `UIManager:show(...)`, and ends with `UIManager:run()`.

### Visual verification (preferred over source scans)

Widgets can be rendered and captured headlessly, so UI wiring does not need to be asserted by grepping source. `test/screenshot.lua` shows a real widget, captures the framebuffer, and reduces it to numbers a test can assert on:

```sh
SDL_VIDEODRIVER=dummy ./test/runui.sh ui/markdown_render
```

- `screenshot.run(cases, opts)` — drive N cases, then quit with the process exit code.
- `screenshot.capture(name, dir)` — framebuffer → PNG → fingerprint.
- `screenshot.fingerprint(path)` — PNG path → metrics.
- `screenshot.fake(mod, value)` / `screenshot.restore()` — install/undo module fakes for the run.
- `screenshot.describe(fp)` — human-readable summary, for debugging a failed assertion.
- `screenshot.ink_between(fp, a, b)` — dark pixels in rows `a..b`.

A case is `{ name, shots = { { name, build|widget }, ... }, verify }`; `verify(ctx)` gets `ctx.shots` (shot name → fingerprint), `ctx.paths`, and `ctx.check(name, ok, detail)`. Fingerprints carry `w`/`h`, `ink_ratio`, `panel_ratio`, `marked_ratio`, `ink_rows`, `row_ink[]`, `first/last_marked_row`, `bands[]`, `grid`/`ink_grid`/`panel_grid` (8×4 density maps), and `panel_boxes[]` — the grey rectangles a styled block actually painted, merged vertically so glyph antialiasing never registers.

PNGs go to `M.OUTPUT_DIR` (default `/tmp/opencode/assistant_shots`, override with `ASSISTANT_SHOT_DIR`); **never into the repo**. Assertions must be perturbed once to confirm they can fail — a visual check that cannot go red is not a check. Examples: `test/ui/markdown_render.lua`, `test/ui/markdown_render_puremd.lua`, `test/ui/stream_status.lua`.

**A visual script must fail the build, and a passing run is the only way to tell.** `screenshot.run` propagates the failure as the process exit code (green → 0, any failed check → 1). If you write a visual script that does **not** go through `screenshot.run`, you must propagate it yourself: `UIManager:quit(code)` only records the code in `self._exit_code` and returns it — upstream `reader.lua` is what calls `os.exit`. Relying on `quit()` alone makes every run exit 0, so a failing check silently passes CI. This was a real defect here; do not reintroduce it. Confirm both directions: a green run exits 0, and after a one-line perturbation the run exits non-zero.

Dummy-driver gotchas: `setRunForeverMode()` is required or the empty-stack tick quits the process mid-run — end with `unsetRunForeverMode()` then `UIManager:quit(code)`. There is no `UIManager:forceLayout`; the call is `UIManager:forceRePaint()`. Widget names are current-version: `ScrollWidget`, not `VerticalScrollWidget`.

### Shared-process discipline

The suite runs every `test_*.lua` in one process, so a test that swaps modules or globals must restore them, including on failure:

- Save the original, and on cleanup put back what was there — if a module was **absent**, remove it; a blanket `= nil` leaks into later files.
- Clearing `package.preload` is not enough. `require` consults `package.loaded` **first**, so a module an earlier file already required must be cleared there too, or your fake is silently ignored (this bug only shows up in the unfiltered run — a single-file `./test/run.sh <name>` will pass).
- Therefore: **always confirm with the unfiltered `./test/run.sh` before committing**, never a single-file run alone.
