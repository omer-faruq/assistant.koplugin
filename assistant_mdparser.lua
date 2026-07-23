-- markdown parser wrapper module
-- This module provides a simple interface to use hoedown (C binding of full features markdown)
-- or the pure Lua implementation of markdown.lua (building on KOReader)
local Parser = nil

local logger = require("logger")
local DataStorage = require("datastorage")
local Device = require("device")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local plugin_lib_dir = DataStorage:getDataDir() .. "/plugins/assistant.koplugin/lib"
local LibHoedown = nil

-- Kindle stock firmware historically ships soft-float; hardfp devices expose
-- /lib/ld-linux-armhf.so.3 (same heuristic used by KOReader's kindle/device.lua).
local function isHardFP()
    return util.pathExists("/lib/ld-linux-armhf.so.3")
end

-- Map the running device to a subdirectory of lib/ containing a compatible
-- libhoedown.so.3. libhoedown has very few dependencies, so a single ARM
-- soft-float build (arm_kindle) works on virtually any EABI5 environment,
-- and the arm_kobo (hardfp) build loads on aarch64-linux hosts too.
local function get_platform_libdir()
    if Device:isDesktop() or Device:isEmulator() then
        return "x86_64"
    elseif Device:isKobo() then
        return "arm_kobo"
    elseif Device:isKindle() then
        return isHardFP() and "arm_kobo" or "arm_kindle"
    elseif Device:isPocketBook() then
        return "arm_kindle"
    elseif Device:isAndroid() and util.stringStartsWith(jit.arch, "arm") then
        return (jit.arch == "arm64") and "android_arm64" or "android_armv7a"
    end
    return nil
end

-- On Android, plugins may live on external storage where dlopen() is not
-- allowed. Stage the .so into the app's internal plugins dir and return the
-- new path. Returns nil on failure.
local function stage_android_library(source_path)
    local ok, android = pcall(require, "android")
    if not ok or not android or not util.fileExists(source_path) then
        return nil
    end

    local _, filename = util.splitFilePathName(source_path)
    local target_dir = android.dir .. "/plugins/assistant.koplugin/lib"
    local target_path = target_dir .. "/" .. filename

    local mk_ok, mk_err = util.makePath(target_dir)
    if not mk_ok then
        logger.warn("Assistant: failed to create staging directory", mk_err)
        return nil
    end

    local src_attr = lfs.attributes(source_path)
    local dst_attr = lfs.attributes(target_path)
    local needs_copy = not (src_attr and dst_attr
        and src_attr.size == dst_attr.size
        and src_attr.modification == dst_attr.modification)

    if needs_copy then
        local copy_err = ffiutil.copyFile(source_path, target_path)
        if copy_err then
            logger.warn("Assistant: failed to stage Android library", copy_err)
            return nil
        end
    end

    return target_path
end

-- check if hoedown is natively available
-- mostly it's unavailable on KOReader, but available on some other platforms
local ok, _lib = pcall(ffi.loadlib, "hoedown", 3)
if ok then LibHoedown = _lib end

-- check if hoedown is available in the plugin directory
-- in order to use native hoedown, a "lib" directory containing per-platform
-- "libhoedown.so.3" files and resty-hoedown should be present in the plugin
-- directory, see documents for more details
if not LibHoedown then
    local libdir = get_platform_libdir()
    if libdir then
        local so_path = plugin_lib_dir .. "/" .. libdir .. "/libhoedown.so.3"
        if Device:isAndroid() then
            so_path = stage_android_library(so_path)
        end
        if so_path then
            local load_ok, lib_or_err = pcall(ffi.load, so_path)
            if load_ok then
                LibHoedown = lib_or_err
                logger.info("Assistant: loaded libhoedown from lib/" .. libdir)
            else
                logger.warn("Assistant: failed to load libhoedown.so.3", lib_or_err)
            end
        end
    else
        logger.info("Assistant: no prebuilt libhoedown.so.3 for this platform")
    end
end

if LibHoedown then
    -- hook the C binding of hoedown to the resty.hoedown library
    package.preload["resty.hoedown.library"] = function()
        return LibHoedown
    end

    -- load the resty.hoedown library from the plugin's libs directory
    package.path = string.format("%s;%s/?.lua", package.path, plugin_lib_dir)
    local ok, hoedownMD = pcall(require, "resty.hoedown")
    if ok then
        Parser = function (text)
            return hoedownMD(text, {
                rendered    = "html",
                nesting     = 1,
                extensions  = {
                    "space_headers", "tables", "fenced_code", "footnotes", "autolink", "strikethrough",
                    "underline", "highlight", "quote", "superscript", "math", "math_explicit",
                },
            })
        end
        logger.info("Using hoedown (C binding) for markdown parsing")
    end
end

-- Post-processor: convert pipe-table <p> blocks that luamd passes through
-- verbatim into proper <table> HTML that CRE can render.
-- Safe for hoedown too: hoedown already emits <table> tags, so no <p>|...|</p>
-- blocks will match and this becomes a no-op.
local function render_tables(html)
    return (html:gsub("<p>([%s%S]-)</p>", function(block)
        if not block:match("^%s*|") then
            return nil
        end

        local rows = {}
        for line in block:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                rows[#rows + 1] = trimmed
            end
        end

        if #rows < 3 then return nil end

        if not rows[2]:match("^|?[%s%-:|]+|$") then return nil end

        local out = { "<table>" }

        for i, row in ipairs(rows) do
            if i == 2 then
                -- skip separator row
            else
                local tag = (i == 1) and "th" or "td"
                local inner = row:match("^|?(.+)|?$") or ""
                out[#out + 1] = "<tr>"
                for cell in (inner .. "|"):gmatch("(.-)|") do
                    local c = cell:match("^%s*(.-)%s*$")
                    if c ~= "" then
                        out[#out + 1] = string.format("<%s>%s</%s>", tag, c, tag)
                    end
                end
                out[#out + 1] = "</tr>"
            end
        end

        out[#out + 1] = "</table>"
        return table.concat(out)
    end))
end

-- fallback to pure Lua implementation
if not Parser then
    local puremd = require("apps/filemanager/lib/md")
    Parser = function(text)
        return render_tables(puremd(text))
    end
    logger.info("Using markdown.lua (puremd) for markdown parsing")
end

return Parser