# Testing

The suite runs inside KOReader's LuaJIT runtime via `setupkoenv` with UI modules mocked, so no device or GUI is needed.

## Commands

- All modules: `./test/run.sh`
- Single module: `./test/run.sh exttools` (substring match on the `test_*.lua` name)
- Syntax (LuaJIT): `/usr/lib/koreader/luajit -e "assert(loadfile('main.lua'))"` — **never** `luajit -bl` (the stripped build lacks `jit.*`)
- Standard Lua: `luac -p file.lua` (basic errors only, not LuaJIT constructs)
- UI widget test: `./test/runui.sh model_picker` (add `-w=1072 -h=1448 -d=300` or `-s=kobo-clara` to simulate a device)
- Translation (only when explicitly requested): `cd l10n && make check`
- Before committing: `./test/run.sh` — CI ships without running tests.

## How it works

- `test/run.sh` `cd`s to `/usr/lib/koreader`, then runs `test/run_tests.lua`, which requires `setupkoenv`, adds the project root to `package.path`, discovers `test/test_*.lua` **alphabetically**, and exits non-zero on failure.
- `test/helper.lua` stubs UI/widget modules, mocks `fetchJSON`, and exposes `assert.*` (`equal`, `notNil`, `isTrue`, `isFalse`, `matches`, `notMatches`) plus `runTests(name, tests)`.
- Each test file must end with `return helper.runTests("<name>", tests)`.

### `runTests` return contract (footgun)

`runTests` returns a **single result table** `{ passed, failed, errors }`, not multiple values. Lua 5.1's `require()` propagates only the first return value, so multiple returns would silently drop the failure counts and the runner would always report `0 failed` and exit `0`. If you change the contract, update `test/run_tests.lua` and `test/test_updater_extract.lua` together.

## Adding a test

- Create `test/test_<module>.lua` following `test/test_exttools.lua`; auto-discovered, no registration.
- Keep files independent — they run alphabetically in one shared process.
- Policy: when adding logic, write a test. If the function is exported, `require` it; if it is local, inline a copy in the test file and test that snippet.
- `test/` is excluded from release zips/OTA packages — source only, never shipped.

## Stub discipline

- A new `require` chain reaching a real KOReader widget module crashes the headless suite (the empty `android` stub makes `device.lua` pick the Android impl). Add a stub in `helper.lua`'s `stubs` table when one is pulled in: `device` needs `screen = { getWidth/getHeight }` for layout math; `buttontable`/`titlebar`/containers can be `{}`.
- Beware **duplicate keys in the `stubs` table constructor — the last entry silently wins**. Check for duplicates when adding a stub that already exists.

## Headless pitfalls

- `G_reader_settings` is a global created by `setupkoenv` / `run_tests.lua`. A bare `luajit -e "require('assistant_utils')"` outside `./test/run.sh` fails with `attempt to index global 'G_reader_settings' (a nil value)` (the `device`/`fontlist` chain). Verify modules via `assert(loadfile(...))` (syntax) or `./test/run.sh` (runtime); do **not** `require` UI-touching modules with raw `luajit -e`.
- Prefer `assistant_utils.PLUGIN_DIR` over `DataStorage:getDataDir().."/plugins/..."` directly; the latter diverges under `MULTIUSER`/extra_plugin_paths.

## UI test scripts

`test/wbuilder` bootstraps the KOReader UI framework and plugin path for isolated widget tests. A UI test requires `test/wbuilder`, shows widgets with `UIManager:show(...)`, and ends with `UIManager:run()`.
