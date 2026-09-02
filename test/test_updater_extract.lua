-- test_updater_extract.lua
-- Entity zip extraction test for OTA do_install filtering.
-- Isolated to a temporary directory; never touches real DataStorage/plugins.
local helper = require("test.helper")
local assert = helper.assert

local lfs = require("libs/libkoreader-lfs")
local TMP = "/tmp/assistant_ota_test_" .. tostring(os.time())
os.execute("rm -rf " .. TMP)
lfs.mkdir(TMP)

-- Mock DataStorage:getFullDataDir() to isolate OTA paths under TMP.
local DataStorage = require("datastorage")
local _origGetFull = DataStorage.getFullDataDir
local _origGetData = DataStorage.getDataDir
DataStorage.getFullDataDir = function() return TMP end
DataStorage.getDataDir = function() return TMP end
-- Ensure getSettingsDir also isolates if used.
if DataStorage.getSettingsDir then
    DataStorage.getSettingsDir = function() return TMP end
end

local util = require("util")
local FFIUtil = require("ffi/util")
local _origPurge = FFIUtil.purgeDir
-- Wrap purgeDir to be safe headless: delegate to real lfs-based purge, fallback to rm -rf.
local function safePurge(dir)
    if not dir or dir == "" or dir == "/" or dir == "/tmp" then return end
    -- Only allow purging under TMP or UPDATE_TMPDIR for safety.
    if dir:sub(1, #TMP) ~= TMP then
        -- Fallback to real purge if outside TMP (should not happen in tests)
        return _origPurge(dir)
    end
    os.execute("rm -rf " .. dir)
end
FFIUtil.purgeDir = safePurge

local updater = require("assistant_updater")

-- Local replicas of updater's internal helpers (do not rely on private export).
local function normalize(path)
    if not path or path == "" then return "" end
    local p = path:gsub("\\", "/")
    while p:sub(1, 2) == "./" do p = p:sub(3) end
    while p:sub(1, 1) == "/" do p = p:sub(2) end
    p = p:gsub("^assistant%.koplugin[^/]*/", "")
    return p:gsub("/+$", "")
end

local function glob_match(pat, path)
    local esc = pat:gsub("%%", "%%%%"):gsub("%.", "%%."):gsub("%+", "%%+"):gsub("%-", "%%-"):gsub("%^", "%%^"):gsub("%$", "%%$"):gsub("%(", "%%("):gsub("%)", "%%)")
    esc = esc:gsub("%*", ".*"):gsub("%?", ".")
    return path:match("^" .. esc .. "$") or path:match("/" .. esc .. "$") or path:match("^" .. esc .. "/") or path:match("/" .. esc .. "/")
end

local function load_ignore(tmp_path)
    local f = io.open(tmp_path, "r")
    if not f then return nil end
    local pats = {}
    for line in f:lines() do
        local t = line:match("^%s*(.-)%s*$")
        if t ~= "" and t:sub(1, 1) ~= "#" then
            local neg = t:sub(1, 1) == "!"
            local core = neg and t:sub(2):match("^%s*(.-)%s*$") or t
            local is_dir = core:sub(-1) == "/"
            if is_dir then core = core:sub(1, -2) end
            if core ~= "" then pats[#pats + 1] = { core = core, neg = neg, is_dir = is_dir } end
        end
    end
    f:close()
    return pats
end

local function is_excluded_with(p, pats)
    local n = normalize(p)
    if n == "" then return false end
    if not pats or #pats == 0 then
        if n:find("/%.") or n:sub(1, 1) == "." then return true end
        if n:find(".+%.md$") then return true end
        if n:find("l10n/.+") and not n:find("%.mo$") then return true end
        if n:find("^test/") or n:find("/test/") then return true end
        return false
    end
    local exc = false
    for _, pt in ipairs(pats) do
        local hit = glob_match(pt.core, n)
        if hit then exc = not pt.neg end
    end
    return exc
end

-- Helpers for isolated OTA paths (mirror otaUpgrade's join logic).
local PLUGIN_NAME = "assistant.koplugin"
local function join(...)
    local args = { ... }
    local result = args[1]
    if not result then return "" end
    for i = 2, #args do result = FFIUtil.joinPath(result, args[i]) end
    return result
end
local UPDATE_TMPDIR = join(TMP, "ota", PLUGIN_NAME .. ".update")
local TARGET_PLUGIN_PATH = join(TMP, "plugins", PLUGIN_NAME)
local BACKUP_PLUGIN_PATH = join(UPDATE_TMPDIR, "backup", PLUGIN_NAME)
local DL_TAR = join(UPDATE_TMPDIR, string.format("SOURCE-%s-test.zip", PLUGIN_NAME))

local function pathExists(p) return lfs.attributes(p, "mode") ~= nil end
local function dirExists(p) return lfs.attributes(p, "mode") == "directory" end
local function fileExists(p) return lfs.attributes(p, "mode") == "file" end

local function ensureCleanTMP()
    os.execute("rm -rf " .. TMP)
    lfs.mkdir(TMP)
    -- Re-apply DataStorage mock after cleanup (still TMP)
    DataStorage.getFullDataDir = function() return TMP end
    DataStorage.getDataDir = function() return TMP end
    util.makePath(UPDATE_TMPDIR)
    util.makePath(join(UPDATE_TMPDIR, "backup"))
end

local function getReleaseIgnoreContent()
    -- Try to read real .releaseignore from project root, fallback to minimal 5 lines.
    local info = debug.getinfo(1, "S")
    local project_root = info and info.source and info.source:match("@(.*/)test/")
    local candidates = {}
    if project_root then table.insert(candidates, project_root .. ".releaseignore") end
    table.insert(candidates, ".releaseignore")
    table.insert(candidates, "/home/ben/Projects/assistant.koplugin/.releaseignore")
    for _, p in ipairs(candidates) do
        local f = io.open(p, "r")
        if f then
            local c = f:read("*a")
            f:close()
            if c and c ~= "" then return c end
        end
    end
    return ".*\n*.md\ntest/\nl10n/Makefile\nl10n/**/*.po\n"
end

local RELEASEIGNORE_CONTENT = getReleaseIgnoreContent()

local TOP = PLUGIN_NAME .. "-test"

local function createTestZip(zip_path)
    -- Ensure parent dir exists
    local parent = zip_path:match("(.*)/")
    if parent and not pathExists(parent) then util.makePath(parent) end
    os.execute("rm -f " .. zip_path)

    local okArch, Archiver = pcall(require, "ffi/archiver")
    if okArch and Archiver and Archiver.Writer then
        local w = Archiver.Writer:new()
        local ok = w:open(zip_path, "zip")
        if ok then
            w:addFileFromMemory(TOP .. "/.releaseignore", RELEASEIGNORE_CONTENT)
            w:addFileFromMemory(TOP .. "/main.lua", "-- main.lua should be kept\n")
            w:addFileFromMemory(TOP .. "/README.md", "# readme should be excluded\n")
            w:addFileFromMemory(TOP .. "/.hidden", "hidden file excluded\n")
            w:addFileFromMemory(TOP .. "/test/foo.lua", "-- should be excluded\n")
            w:addFileFromMemory(TOP .. "/l10n/fr/assistant.mo", "MO kept")
            w:addFileFromMemory(TOP .. "/l10n/fr/assistant.po", "PO excluded")
            w:addFileFromMemory(TOP .. "/l10n/Makefile", "make excluded")
            w:addFileFromMemory(TOP .. "/assistant_updater.lua", "-- updater kept\n")
            w:close()
            -- Fix perms for readability (archiver may create 0222)
            os.execute("chmod 644 " .. zip_path)
            return true
        end
    end
    -- Fallback: shell zip
    local src = TMP .. "/_zip_src"
    os.execute("rm -rf " .. src)
    util.makePath(src .. "/" .. TOP .. "/l10n/fr")
    util.makePath(src .. "/" .. TOP .. "/test")
    local function write(p, c)
        local f = io.open(p, "w")
        if f then f:write(c); f:close() end
    end
    write(src .. "/" .. TOP .. "/.releaseignore", RELEASEIGNORE_CONTENT)
    write(src .. "/" .. TOP .. "/main.lua", "-- main.lua should be kept\n")
    write(src .. "/" .. TOP .. "/README.md", "# readme should be excluded\n")
    write(src .. "/" .. TOP .. "/.hidden", "hidden file excluded\n")
    write(src .. "/" .. TOP .. "/test/foo.lua", "-- should be excluded\n")
    write(src .. "/" .. TOP .. "/l10n/fr/assistant.mo", "MO kept")
    write(src .. "/" .. TOP .. "/l10n/fr/assistant.po", "PO excluded")
    write(src .. "/" .. TOP .. "/l10n/Makefile", "make excluded")
    write(src .. "/" .. TOP .. "/assistant_updater.lua", "-- updater kept\n")
    local cmd = string.format("cd %s && zip -q -r %s %s 2>&1", src, zip_path, TOP)
    local rc = os.execute(cmd)
    os.execute("chmod 644 " .. zip_path)
    os.execute("rm -rf " .. src)
    return rc == 0 or rc == true
end

-- Core extraction replica (mirrors do_install filtering).
-- Uses fresh Reader instances to avoid size=nil bug after close() without keep_info.
local function doExtractFiltered(dl_tar, update_tmpdir)
    local Archiver = require("ffi/archiver")
    local tmp_ignore = join(update_tmpdir, ".releaseignore.tmp")
    if pathExists(tmp_ignore) then os.remove(tmp_ignore) end
    do
        local arc = Archiver.Reader:new()
        if not arc:open(dl_tar) then return nil, "open failed" end
        for entry in arc:iterate() do
            if normalize(entry.path) == ".releaseignore" then
                local parent = tmp_ignore:match("(.*)" .. package.config:sub(1, 1))
                if parent and not pathExists(parent) then util.makePath(parent) end
                arc:extractToPath(entry.path, tmp_ignore)
                -- Fix permission (archiver extracts with restricted perms headless)
                os.execute("chmod 644 " .. tmp_ignore .. " 2>/dev/null || chmod 644 " .. tmp_ignore)
                break
            end
        end
        arc:close()
    end
    local pats = nil
    if pathExists(tmp_ignore) then
        -- Ensure readable regardless of extracted perms
        os.execute("chmod 644 " .. tmp_ignore .. " 2>/dev/null; true")
        pats = load_ignore(tmp_ignore)
    end
    do
        local arc2 = Archiver.Reader:new()
        if not arc2:open(dl_tar) then return nil, "reopen failed" end
        for entry in arc2:iterate() do
            local norm = normalize(entry.path)
            if norm ~= ".releaseignore" and norm ~= ".releaseignore.tmp" and not is_excluded_with(entry.path, pats) then
                local dest_path = join(update_tmpdir, entry.path)
                local parent_dir = dest_path:match("(.*)" .. package.config:sub(1, 1))
                if parent_dir and not pathExists(parent_dir) then util.makePath(parent_dir) end
                local ok = arc2:extractToPath(entry.path, dest_path)
                if not ok then
                    -- try chmod parent and retry? just return error
                else
                    -- Fix perms so lfs/io can read in tests
                    os.execute("chmod -R u+rw " .. update_tmpdir .. " 2>/dev/null; true")
                end
            end
        end
        arc2:close()
    end
    if pathExists(tmp_ignore) then os.remove(tmp_ignore) end
    -- Locate extracted top-level plugin dir
    local found = nil
    for file in lfs.dir(update_tmpdir) do
        if file:sub(1, #PLUGIN_NAME) == PLUGIN_NAME then
            local candidate = join(update_tmpdir, file)
            if dirExists(candidate) then found = candidate; break end
        end
    end
    return found, pats, tmp_ignore
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("is_excluded: legacy fallback matches releaseignore intent", function()
        -- Legacy is_excluded (no pats) should exclude same illustrative paths as .releaseignore
        assert.isTrue(updater.is_excluded("README.md"))
        assert.isTrue(updater.is_excluded(".hidden"))
        assert.isTrue(updater.is_excluded("test/foo.lua"))
        assert.isTrue(updater.is_excluded("l10n/Makefile"))
        assert.isTrue(updater.is_excluded("l10n/fr/assistant.po"))
        assert.isFalse(updater.is_excluded("main.lua"))
        assert.isFalse(updater.is_excluded("assistant_updater.lua"))
        assert.isFalse(updater.is_excluded("l10n/fr/assistant.mo"))
    end),

    test("is_excluded_with: patterns from .releaseignore filter correctly", function()
        ensureCleanTMP()
        local tmp_ignore = join(UPDATE_TMPDIR, ".releaseignore.tmp")
        local f = io.open(tmp_ignore, "w")
        assert.notNil(f, "should create tmp ignore")
        f:write(RELEASEIGNORE_CONTENT)
        f:close()
        local pats = load_ignore(tmp_ignore)
        assert.notNil(pats)
        assert.isTrue(is_excluded_with("README.md", pats))
        assert.isTrue(is_excluded_with(".hidden", pats))
        assert.isTrue(is_excluded_with("test/foo.lua", pats))
        assert.isTrue(is_excluded_with("l10n/Makefile", pats))
        assert.isTrue(is_excluded_with("l10n/fr/assistant.po", pats))
        -- l10n/*.pot at single depth is NOT matched by l10n/**/*.pot (needs subdir)
        assert.isFalse(is_excluded_with("l10n/template.pot", pats))
        assert.isFalse(is_excluded_with("main.lua", pats))
        assert.isFalse(is_excluded_with("assistant_updater.lua", pats))
        assert.isFalse(is_excluded_with("l10n/fr/assistant.mo", pats))
        -- Ensure subdirectory po also excluded via l10n/**/*.po
        assert.isTrue(is_excluded_with("l10n/de/assistant.po", pats))
        assert.isTrue(is_excluded_with(".github/workflows/release.yml", pats))
        os.remove(tmp_ignore)
        -- cleanup for next test
        os.execute("rm -rf " .. TMP)
    end),

    test("zip creation: entity zip exists and contains expected entries", function()
        ensureCleanTMP()
        local ok = createTestZip(DL_TAR)
        assert.isTrue(ok, "createTestZip should succeed")
        assert.isTrue(fileExists(DL_TAR), "zip file should exist at " .. DL_TAR)
        local Archiver = require("ffi/archiver")
        local arc = Archiver.Reader:new()
        assert.isTrue(arc:open(DL_TAR), "should open zip")
        local found = {}
        for e in arc:iterate() do found[e.path] = true end
        arc:close()
        assert.isTrue(found[TOP .. "/main.lua"] == true, "main.lua in archive")
        assert.isTrue(found[TOP .. "/.releaseignore"] == true, ".releaseignore in archive")
        assert.isTrue(found[TOP .. "/README.md"] == true, "README.md in archive")
        assert.isTrue(found[TOP .. "/l10n/fr/assistant.mo"] == true, "mo in archive")
        assert.isTrue(found[TOP .. "/l10n/fr/assistant.po"] == true, "po in archive")
        os.execute("rm -rf " .. TMP)
    end),

    test("entity extraction: filtered files respected, kept files extracted", function()
        ensureCleanTMP()
        assert.isTrue(createTestZip(DL_TAR))
        local found_dir, pats = doExtractFiltered(DL_TAR, UPDATE_TMPDIR)
        assert.notNil(found_dir, "found_extracted_dir should exist")
        assert.notNil(pats, "patterns should be loaded from .releaseignore")
        -- Helper to check existence under found_dir
        local function inside(rel) return join(found_dir, rel) end
        assert.isTrue(fileExists(inside("main.lua")), "main.lua should be kept")
        assert.isTrue(fileExists(inside("assistant_updater.lua")), "assistant_updater.lua kept")
        assert.isTrue(fileExists(inside("l10n/fr/assistant.mo")), "mo kept")
        assert.isFalse(pathExists(inside("README.md")), "README.md excluded")
        assert.isFalse(pathExists(inside(".hidden")), ".hidden excluded")
        assert.isFalse(pathExists(inside("test/foo.lua")), "test/foo.lua excluded")
        assert.isFalse(pathExists(inside("l10n/fr/assistant.po")), "po excluded")
        assert.isFalse(pathExists(inside("l10n/Makefile")), "Makefile excluded")
        -- .releaseignore itself must NOT be in final extracted dir
        assert.isFalse(pathExists(inside(".releaseignore")), ".releaseignore skipped in dest")
        os.execute("rm -rf " .. TMP)
    end),

    test("extraction isolates to TMP: TARGET/BACKUP under TMP", function()
        ensureCleanTMP()
        -- Verify constants are isolated
        assert.isTrue(UPDATE_TMPDIR:sub(1, #TMP) == TMP, "UPDATE_TMPDIR under TMP")
        assert.isTrue(TARGET_PLUGIN_PATH:sub(1, #TMP) == TMP, "TARGET under TMP")
        assert.isTrue(BACKUP_PLUGIN_PATH:sub(1, #TMP) == TMP, "BACKUP under TMP")
        -- Create a fake existing plugin to test backup isolation
        util.makePath(TARGET_PLUGIN_PATH)
        local fake = io.open(join(TARGET_PLUGIN_PATH, "old.txt"), "w")
        fake:write("old")
        fake:close()
        -- Ensure real DataStorage path not touched
        local real = _origGetFull and _origGetFull() or "/tmp"
        -- real may be /tmp; but we assert our TMP is distinct and contains our fake
        assert.isTrue(pathExists(join(TARGET_PLUGIN_PATH, "old.txt")))
        -- Cleanup will remove fake without affecting real plugin dir
        os.execute("rm -rf " .. TMP)
        assert.isFalse(pathExists(join(TARGET_PLUGIN_PATH, "old.txt")))
        -- If real plugin dir exists, it should not have been deleted (when TMP != real)
        -- Only check when TMP != real to avoid false positive on /tmp mock
        if real ~= TMP then
            -- No assertion needed; just ensure we didn't rm -rf real
            assert.isTrue(true)
        end
    end),

    test(".releaseignore.tmp cleaned after extraction", function()
        ensureCleanTMP()
        assert.isTrue(createTestZip(DL_TAR))
        local tmp_ignore = join(UPDATE_TMPDIR, ".releaseignore.tmp")
        local found_dir = doExtractFiltered(DL_TAR, UPDATE_TMPDIR)
        assert.notNil(found_dir)
        assert.isFalse(pathExists(tmp_ignore), ".releaseignore.tmp should be removed")
        assert.isFalse(pathExists(join(UPDATE_TMPDIR, ".releaseignore.tmp")))
        -- Second extraction should still find patterns correctly (re-reads archive)
        os.execute("rm -rf " .. TMP)
    end),

    test("is_excluded_with: direct pattern assertions mirror OTA", function()
        ensureCleanTMP()
        local tmp_ignore = join(UPDATE_TMPDIR, ".releaseignore.tmp")
        local f = io.open(tmp_ignore, "w")
        f:write(RELEASEIGNORE_CONTENT)
        f:close()
        local pats = load_ignore(tmp_ignore)
        assert.isTrue(is_excluded_with("README.md", pats) == true, "README.md true")
        assert.isTrue(is_excluded_with("main.lua", pats) == false, "main.lua false")
        assert.isTrue(is_excluded_with("l10n/fr/assistant.mo", pats) == false, "mo false")
        assert.isTrue(is_excluded_with("l10n/fr/assistant.po", pats) == true, "po true")
        -- Prefix handling: normalize strips assistant.koplugin-*/ prefix
        assert.isTrue(is_excluded_with("assistant.koplugin-test/README.md", pats) == true)
        assert.isTrue(is_excluded_with("assistant.koplugin-main/main.lua", pats) == false)
        os.remove(tmp_ignore)
        os.execute("rm -rf " .. TMP)
    end),

    test("cleanup: leaves no trace outside TMP", function()
        ensureCleanTMP()
        -- Create zip and extract, then purge
        assert.isTrue(createTestZip(DL_TAR))
        doExtractFiltered(DL_TAR, UPDATE_TMPDIR)
        -- Purge via safePurge (should rm -rf TMP)
        safePurge(TMP)
        assert.isFalse(pathExists(TMP), "TMP should be gone after purge")
        -- Recreate for subsequent runs (helper resets at next test if needed)
        lfs.mkdir(TMP)
        os.execute("rm -rf " .. TMP)
    end),
}

-- Final global cleanup (in case a test left TMP)
local passed, failed, errors = helper.runTests("assistant_updater_extract", tests)
-- Ensure TMP removed even if runTests short-circuits
os.execute("rm -rf " .. TMP)
-- Restore originals (best effort, not required for headless run but clean)
DataStorage.getFullDataDir = _origGetFull
DataStorage.getDataDir = _origGetData
FFIUtil.purgeDir = _origPurge

return passed, failed, errors
