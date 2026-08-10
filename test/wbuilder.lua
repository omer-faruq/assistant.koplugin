-- UI test framework for assistant.koplugin
-- Usage: require("test/wbuilder") from test scripts run via test/runui.sh
--
-- Bootstraps KOReader's UI framework (SDL, UIManager, etc.) and adds the
-- project root to package.path so plugin modules can be loaded.
-- Returns key modules for use in test scripts.

require("setupkoenv")

-- ── Bootstrap KOReader UI framework (mirrors upstream tools/wbuilder.lua) ──

G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
local _ = require("gettext")

-- read settings and check for language override
-- has to be done before requiring other files because they might call gettext on load
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")

local lang_locale = G_reader_settings:readSetting("language")
if lang_locale then
    _.changeLang(lang_locale)
end

-- Ensure SDL window dimensions are set before Device init reads them.
-- The SDL device reads sdl_window from G_reader_settings; if missing, init fails.
local sdl_win = G_reader_settings:readSetting("sdl_window")
if not sdl_win or type(sdl_win) ~= "table" or not sdl_win.width then
    sdl_win = { width = 600, height = 800, left = 0, top = 0 }
    G_reader_settings:saveSetting("sdl_window", sdl_win)
    pcall(G_reader_settings.flush, G_reader_settings)
end

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local DEBUG = require("dbg")
DEBUG:turnOn()

-- ── Add project root to Lua search path ──

-- Determine project root relative to this script
local project_root
local script_path = debug.getinfo(1, "S").source:sub(2) -- strip leading @
if script_path:match("^/") then
    project_root = script_path:match("^(.*)/test/wbuilder%.lua$")
end

if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

-- Override _ with our plugin's gettext so widgets use our translations
local plugin_gettext = require("assistant_gettext")
_ = plugin_gettext

return {
    UIManager = UIManager,
    Screen = Screen,
    DEBUG = DEBUG,
}
