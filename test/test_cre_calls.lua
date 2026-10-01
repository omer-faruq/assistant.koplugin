-- test_cre_calls.lua
-- Static guard: every crengine binding the plugin calls must exist on the
-- installed wrapper (libs/libkoreader-cre). Calling a field the wrapper does
-- not export crashes only at tap time -- "attempt to call field '<name>' (a
-- nil value)" -- which is how the Response Font menu crashed on
-- cre.getAvailableFonts(): the font list API there is cre.getFontFaces().
--
-- Why a scan: the call sites build TouchMenu item tables, and their module
-- (assistant_settings_menu) cannot load headlessly (its chain pulls reader
-- globals, e.g. G_defaults). The names are therefore read out of the shipped
-- sources and resolved against the real C wrapper -- a fake would test the
-- fake, which is exactly how the wrong name passed review.
--
-- Scope mirrors test_gettext_ascii_msgids.lua: project root + api_handlers/.
local helper = require("test.helper")
local assert = helper.assert

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not lfs_ok then
    lfs_ok, lfs = pcall(require, "lfs")
end

local cre_ok, cre = pcall(require, "libs/libkoreader-cre")

-- The set of cre.<name>( call sites in one source chunk.
local function cre_calls_in(src)
    local names = {}
    for name in src:gmatch("[%s%(=,]cre%.([%w_]+)%s*%(") do
        names[name] = true
    end
    return names
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
    return files
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("scanner self-check: finds calls, ignores method calls", function()
        local found = cre_calls_in(
            'local cre = require("document/credocument"):engineInit()\n'
            .. 'local a = cre.getFontFaces()\n'
            .. 'local b = cre.getFontFaceFilenameAndFaceIndex(name)\n')
        assert.isTrue(found.getFontFaces, "a bare call must be found")
        assert.isTrue(found.getFontFaceFilenameAndFaceIndex, "a call in an assignment must be found")
        assert.isTrue(found.engineInit == nil, "a method call is not a cre binding")
        assert.equal(#cre_calls_in("local x = credocument.foo()"), 0,
            "a longer identifier must not read as a cre binding")
    end),

    test("the installed wrapper exports the bindings the font picker uses", function()
        assert.isTrue(cre_ok and type(cre) == "table", "could not load libs/libkoreader-cre")
        assert.isTrue(type(cre.getFontFaces) == "function",
            "the font list API is cre.getFontFaces(); cre.getAvailableFonts() does not exist")
        assert.isTrue(type(cre.getFontFaceFilenameAndFaceIndex) == "function",
            "the file resolution API of the Response Font picker")
    end),

    test("every cre binding the plugin calls exists on the wrapper", function()
        assert.isTrue(cre_ok and type(cre) == "table", "could not load libs/libkoreader-cre")
        assert.isTrue(lfs_ok and lfs ~= nil, "lfs is unavailable; cannot scan sources")
        local files = collect_source_files()
        assert.isTrue(#files > 0, "no source files found to scan")
        local checked, offenders = 0, {}
        for i = 1, #files do
            local f = io.open(files[i], "r")
            if f then
                local src = f:read("*a")
                f:close()
                for name in pairs(cre_calls_in(src)) do
                    checked = checked + 1
                    if type(cre[name]) ~= "function" then
                        offenders[#offenders + 1] = files[i] .. ": cre." .. name
                    end
                end
            end
        end
        assert.isTrue(checked > 0, "no cre. calls found; the scanner pattern may have gone stale")
        assert.equal(#offenders, 0, "unknown cre binding(s): " .. table.concat(offenders, ", "))
    end),
}

return helper.runTests("cre_calls", tests)
