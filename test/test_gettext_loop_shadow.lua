-- test_gettext_loop_shadow.lua
-- Static guard against shadowing the gettext `_` function with a discarded
-- loop variable: `for _, x in ... do`.
--
-- Such a loop makes `_` a number inside the loop body, so any gettext call
-- `_(...")` in that body (directly or from a closure defined there) crashes at
-- runtime with "attempt to call upvalue '_' (a number value)". This is exactly
-- the bug that broke the dictionary settings long-press callback.
--
-- Scope: shipped plugin sources (project root + api_handlers/). test/, l10n/,
-- lib/ (vendored) and the user-owned configuration.lua are skipped.
local helper = require("test.helper")
local assert = helper.assert

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not lfs_ok then
    lfs_ok, lfs = pcall(require, "lfs")
end

local function read_lines(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    return lines
end

local function leading_indent(line)
    local _, e = line:find("^%s*")
    return e or 0
end

-- Returns true when `line` contains a gettext `_(...)` call. `N_(`, `C_(` and
-- `NC_(` are different functions and must not match, hence the boundary check.
local function has_gettext_call(line)
    -- Drop a trailing comment so commented-out samples don't trip the check.
    local code = line:gsub("%-%-.*$", "")
    local init = 1
    while true do
        local pos = code:find("_(", init, true)
        if not pos then return false end
        local prev = pos > 1 and code:sub(pos - 1, pos - 1) or ""
        if not prev:match("[%w_]") then
            return true
        end
        init = pos + 1
    end
end

-- Finds the line index of the `end` that closes the loop starting at `start`,
-- using indentation: the first `end` at an indentation <= the `for` line's.
-- Falls back to the last line when no match is found.
local function find_loop_end(lines, start)
    local base = leading_indent(lines[start])
    for j = start + 1, #lines do
        local line = lines[j]
        if leading_indent(line) <= base and line:match("^%s*end%s*$") then
            return j
        end
    end
    return #lines
end

-- Returns the list of "file:line" for `for _,` loops whose body calls `_()`.
local function scan_file(path)
    local lines = read_lines(path)
    if not lines then return {} end
    local offenders = {}
    for i, line in ipairs(lines) do
        if line:match("^%s*for%s+_%s*,") then
            local last = find_loop_end(lines, i)
            for j = i, last do
                if has_gettext_call(lines[j]) then
                    offenders[#offenders + 1] = string.format("%s:%d", path, i)
                    break
                end
            end
        end
    end
    return offenders
end

local function collect_source_files()
    local files = {}
    if not project_root then return files end
    local function add_dir(dir)
        if not (lfs and lfs.attributes and lfs.attributes(dir, "mode") == "directory") then
            return
        end
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".."
                and entry ~= "configuration.lua"
                and entry:match("%.lua$") then
                files[#files + 1] = dir .. entry
            end
        end
    end
    add_dir(project_root)
    add_dir(project_root .. "api_handlers/")
    add_dir(project_root .. "core/")
    add_dir(project_root .. "feature/")
    add_dir(project_root .. "dialogs/")
    add_dir(project_root .. "utils/")
    return files
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("for _: no gettext _() call inside a `for _,` loop body", function()
        assert.notNil(project_root, "could not locate project root")
        assert.isTrue(lfs_ok and lfs ~= nil, "lfs is unavailable; cannot scan sources")
        local files = collect_source_files()
        assert.isTrue(#files > 0, "no source files found to scan")

        local offenders = {}
        for _, path in ipairs(files) do
            for _, hit in ipairs(scan_file(path)) do
                offenders[#offenders + 1] = hit
            end
        end

        if #offenders > 0 then
            error("gettext `_` shadowed by `for _,` loop and called inside the loop:\n  "
                .. table.concat(offenders, "\n  ")
                .. "\nRename the discarded loop variable (e.g. `for _idx, x in ...`).", 2)
        end
    end),
}

return helper.runTests("gettext_loop_shadow", tests)
