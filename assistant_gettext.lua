--[[--
Isolated gettext shim for assistant.koplugin (scheme B).

This module does NOT use require("gettext") (which returns KOReader's singleton
instance); instead it dofile's KOReader's frontend/gettext.lua so we get a fresh,
independent GetText instance. We then point it at the plugin's own l10n directory
and textdomain ("assistant"), while still falling back to the legacy
"koreader" domain for migration of old koreader.mo / koreader.po files.

We reuse KOReader's MO parser verbatim — no duplicated PO/MO logic here.
--]]

-- Locate KOReader's gettext.lua without relying on the singleton require.
-- Note: do NOT use DataStorage:getDataDir() here. It returns the writable data
-- dir (XDG_CONFIG_HOME / KO_HOME / etc.), which diverges from the install dir
-- under MULTIUSER / AppImage / Flatpak. KOReader always launches with cwd ==
-- install root and sets package.path = "frontend/?.lua;...", so
-- package.searchpath is the canonical, install-type-agnostic resolver.
local function findGettextPath()
    local p = package.searchpath("gettext", package.path)
    if p then return p end
    -- Fallback for standalone luajit / tests without setupkoenv: absolute via lfs.
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.currentdir then
        local c = lfs.currentdir() .. "/frontend/gettext.lua"
        local f = io.open(c, "r")
        if f then f:close(); return c end
    end
    local f = io.open("frontend/gettext.lua", "r")
    if f then f:close(); return "frontend/gettext.lua" end
    return nil
end

-- Minimal no-op fallback so the plugin never crashes if gettext is missing.
local function makeStub()
    local s = {
        current_lang = "C",
        translation = {},
        context = {},
        dirname = "",
        textdomain = "assistant",
        getPlural = function(n) return n ~= 1 and 1 or 0 end,
        changeLang = function() return false end,
        ngettext = function(m, mp, n) return n ~= 1 and mp or m end,
        pgettext = function(_, m) return m end,
        npgettext = function(_, m, mp, n) return n ~= 1 and mp or m end,
    }
    return setmetatable(s, { __call = function(self, m) return m end })
end

local path = findGettextPath()
if not path then
    -- gettext.lua not found anywhere; fall back to the no-op stub.
    GetText = makeStub()
else
    -- KOReader's gettext.lua does ffi.cdef("struct mo_header ...") at load.
    -- If KOReader has already required("gettext"), a second dofile would
    -- hit "attempt to redefine 'mo_header'". Wrap ffi.cdef to ignore
    -- redefinition so we can get a fresh isolated GetText instance.
    local ffi_ok, ffi = pcall(require, "ffi")
    local orig_cdef
    if ffi_ok and ffi and ffi.cdef then
        orig_cdef = ffi.cdef
        ffi.cdef = function(s)
            local ok, err = pcall(orig_cdef, s)
            if not ok and not tostring(err):find("redefine") then
                error(err)
            end
        end
    end
    local ok, gt = pcall(dofile, path)
    if ffi_ok and orig_cdef then
        ffi.cdef = orig_cdef
    end
    if not ok or not gt then
        GetText = makeStub()
    else
        GetText = gt
    end
end

if GetText.changeLang then
    -- Capture the original (MO-based) changeLang before shadowing it.
    local orig_changeLang = GetText.changeLang
    local function hasTranslations()
        return next(GetText.translation) ~= nil or next(GetText.context) ~= nil
    end
    -- Try the new "assistant" domain first, then fall back to legacy "koreader".
    -- KOReader's changeLang returns nil on success and false on failure, so we
    -- must not rely on its truthiness; instead inspect whether translations
    -- were actually loaded.
    GetText.changeLang = function(new_lang)
        -- Normalize: strip encoding suffix (zh_CN.utf8 -> zh_CN) and handle
        -- en_US:en style. Upstream's `:sub(1, find("%.")` mishandles nil, so
        -- do it safely here before delegating.
        if new_lang and new_lang ~= "" then
            new_lang = new_lang:match("^[^.:]+") or new_lang
            -- keep underscore part, drop after dot/colon
            new_lang = new_lang:match("^[^.]+") or new_lang
            new_lang = new_lang:match("^[^:]+") or new_lang
        end
        -- Try the new "assistant" domain first.
        GetText.textdomain = "assistant"
        orig_changeLang(new_lang)
        if hasTranslations() then
            GetText.textdomain = "assistant"
            return true
        end
        -- Reset and retry with the legacy "koreader" domain as a fallback.
        GetText.context = {}
        GetText.translation = {}
        GetText.textdomain = "koreader"
        orig_changeLang(new_lang)
        local hasLegacy = hasTranslations()
        GetText.textdomain = "assistant"
        return hasLegacy and true or false
    end
end

-- Derive l10n dir from this file's location (install dir), not DataStorage.
-- DataStorage:getDataDir() is the writable data dir (MULTIUSER / AppImage),
-- which does NOT contain the plugin's l10n. The plugin lives alongside this file.
-- This must stay self-contained: requiring assistant_utils here would create a
-- circular require (utils -> gettext -> utils) that breaks any module loaded
-- before main.lua has finished (e.g. assistant_exttools).
-- self-contained plugin dir (no utils require to avoid cycle)
local plugin_dir
do
  local info = debug.getinfo(1, "S")
  local src = info and info.source and info.source:match("^@(.+)$") or "assistant_gettext.lua"
  plugin_dir = src:match("(.*/)") or ""
  plugin_dir = plugin_dir:gsub("/$", "")
  if plugin_dir == "" then
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then
      plugin_dir = DataStorage:getDataDir() .. "/plugins/assistant.koplugin"
    else
      plugin_dir = "."
    end
  end
end
GetText.dirname = plugin_dir .. "/l10n"
GetText.plugin_dir = plugin_dir
GetText.textdomain = "assistant"

-- Sync to KOReader's active UI language (optional in case gettext is absent).
local g_ok, kogt = pcall(require, "gettext")
if g_ok and kogt and kogt.current_lang then
    GetText.changeLang(kogt.current_lang)
end

return GetText
