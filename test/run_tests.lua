-- run_tests.lua
-- Test runner entry point for the assistant.koplugin test suite.
--
-- Usage:
--   ./test/run.sh              (run all tests)
--   ./test/run.sh exttools    (run a single module)
--
-- The shell script cd's to /usr/lib/koreader so setupkoenv.lua relative paths work,
-- then passes the project root as the first argument.

-- First arg: project root directory (required)
local PROJECT_ROOT, filter = ...
if not PROJECT_ROOT then
    error("Usage: luajit run_tests.lua <project_root> [module]")
end

-- CWD is /usr/lib/koreader, so setupkoenv's relative paths work
require("setupkoenv")

-- Add project root to package.path
package.path = PROJECT_ROOT .. "/?.lua;" .. PROJECT_ROOT .. "/?/init.lua;" .. package.path

-- Collect test files
local test_files = {
    "test.test_exttools",
    "test.test_prompts",
    "test.test_menu_paths",
    "test.test_provider_registry",
    "test.test_search_registry",
    "test.test_updater",
    "test.test_querier_stream",
    "test.test_notebook",
    "test.test_handler_timeouts",
}

if filter then
    local filtered = {}
    for _, f in ipairs(test_files) do
        if f:find(filter, 1, true) then
            table.insert(filtered, f)
        end
    end
    if #filtered == 0 then
        error("No test module matching '" .. filter .. "'")
    end
    test_files = filtered
end

local total_passed = 0
local total_failed = 0
local all_errors = {}

print("=== assistant.koplugin Test Suite ===")
print(string.format("  Running %d test file(s)", #test_files))

for _, test_file in ipairs(test_files) do
    local ok, passed, failed, errors = pcall(require, test_file)
    if not ok then
        print("  ERROR loading " .. test_file .. ": " .. tostring(passed))
        total_failed = total_failed + 1
    else
        total_passed = total_passed + (passed or 0)
        total_failed = total_failed + (failed or 0)
        if errors then
            for _, e in ipairs(errors) do
                table.insert(all_errors, { file = test_file, name = e.name, error = e.error })
            end
        end
    end
end

-- Summary
print("\n========================================")
print(string.format("TOTAL: %d passed, %d failed", total_passed, total_failed))
if #all_errors > 0 then
    print("\nFailed tests:")
    for _, e in ipairs(all_errors) do
        print(string.format("  [%s] %s", e.file, e.name))
        print(string.format("    %s", e.error))
    end
end
print("========================================")

if total_failed > 0 then
    os.exit(1)
end
