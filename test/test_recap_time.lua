-- test_recap_time.lua
-- Runtime tests for the recap last-read-time source in assistant_hooks:
-- setupRecap must derive the elapsed time from KOReader's read history, then
-- from the sidecar metadata mtime, and never from the document's atime.
-- Read history, DocSettings, lfs and ReaderUI are faked; the require
-- environment is restored for the rest of the suite.
local helper = require("test.helper")
local assert = helper.assert

local MODULES = { "assistant_hooks", "ui/widget/textviewer" }

local saved_preload = {}
local saved_loaded = {}
for mod_idx, modname in ipairs(MODULES) do
    saved_preload[modname] = package.preload[modname]
    saved_loaded[modname] = package.loaded[modname]
    package.loaded[modname] = nil
    package.preload[modname] = nil
end

-- UIManager/ConfirmBox must capture the real lfs before fakes are installed.
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local ffiutil = require("ffi/util")
-- Warm the remaining non-faked header deps so their transitive lfs stays real.
require("ui/widget/infomessage")
require("ui/trapper")
require("logger")
require("util")
require("assistant_gettext")
require("assistant_doc_utils")
require("assistant_net_utils")

-- assistant_hooks captures ReadHistory/DocSettings/lfs at load time, so the
-- fakes must be installed before requiring it (but after the real UI modules
-- above, or their transitive lfs would be poisoned).
local fake_readerui = {
    doShowReader = function() return "orig-result" end,
}
local fake_history = {
    hist = {},
    getIndexByFile = function(self, item_file)
        for i, v in ipairs(self.hist) do
            if item_file == v.file then return i end
        end
    end,
}
local sidecar_path = nil
local sidecar_mtime = nil
local open_settings = nil
local fake_docsettings = {
    findSidecarFile = function(_, _file) return sidecar_path end,
    open = function(_, _file) return open_settings end,
}
local real_lfs = require("libs/libkoreader-lfs")
local fake_lfs = setmetatable(
    { attributes = function(_path, _field) return sidecar_mtime end },
    { __index = real_lfs })

local DYNAMIC = {
    "apps/reader/readerui",
    "readhistory",
    "docsettings",
    "libs/libkoreader-lfs",
}
local saved_dynamic = {}
for dyn_idx, name in ipairs(DYNAMIC) do
    saved_dynamic[name] = { loaded = package.loaded[name], preload = package.preload[name] }
end
package.loaded["apps/reader/readerui"] = fake_readerui
package.loaded["readhistory"] = fake_history
package.loaded["docsettings"] = fake_docsettings
package.loaded["libs/libkoreader-lfs"] = fake_lfs

-- assistant_hooks requires TextViewer at load time; a bare stub is enough.
package.preload["ui/widget/textviewer"] = function() return {} end

local Hooks = require("assistant_hooks")

-- Stub the already-loaded UI modules (same tables the hooks captured).
local saved_show = UIManager.show
local saved_confirmbox_new = ConfirmBox.new
ConfirmBox.new = function(_, opts) return opts end
local shown_widgets = {}
UIManager.show = function(_, widget) table.insert(shown_widgets, widget) end

local tmp_dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/assistant_recap_test"
os.execute("mkdir -p '" .. tmp_dir .. "'")

local function book_file(name)
    return tmp_dir .. "/" .. name
end

local function touch(name)
    local path = book_file(name)
    local handle = io.open(path, "w")
    if not handle then error("cannot create fixture " .. path) end
    handle:write("x")
    handle:close()
    return path
end

-- A sidecar stand-in: percent_finished is read by the recap gate.
local function make_open(percent)
    return {
        readSetting = function(_, key, default)
            if key == "percent_finished" then return percent end
            return default
        end,
        child = function()
            return { readSetting = function(_, _key, default) return default end }
        end,
    }
end

local HOURS = 3600

local function reset_state()
    fake_history.hist = {}
    sidecar_path = nil
    sidecar_mtime = nil
    open_settings = make_open(0.5)
    shown_widgets = {}
end

local function call_do_show_reader(file)
    return fake_readerui.doShowReader(nil, file, nil, nil)
end

local function test(name, fn)
    return { name = name, fn = fn }
end

Hooks.setupRecap({})

local tests = {
    test("history time wins over the sidecar mtime", function()
        reset_state()
        local file = touch("history_wins.epub")
        fake_history.hist = { { file = ffiutil.realpath(file), time = os.time() - 40 * HOURS } }
        -- A recent sidecar mtime would suppress the recap if it were used.
        sidecar_path = file .. "/metadata.epub.lua"
        sidecar_mtime = os.time() - 1 * HOURS
        call_do_show_reader(file)
        assert.equal(#shown_widgets, 1, "an old history time must trigger the recap")
    end),

    test("history deleted (dim) entry matches by original path", function()
        reset_state()
        local file = book_file("deleted.epub")
        fake_history.hist = { { file = file, time = os.time() - 40 * HOURS, dim = true } }
        call_do_show_reader(file)
        assert.equal(#shown_widgets, 1, "a dim history entry must still supply the time")
    end),

    test("missing history falls back to the sidecar mtime", function()
        reset_state()
        local file = touch("fallback.epub")
        sidecar_path = file .. "/metadata.epub.lua"
        sidecar_mtime = os.time() - 40 * HOURS
        call_do_show_reader(file)
        assert.equal(#shown_widgets, 1, "an old sidecar mtime must trigger the recap")
    end),

    test("recent sidecar mtime does not trigger the recap", function()
        reset_state()
        local file = touch("recent.epub")
        sidecar_path = file .. "/metadata.epub.lua"
        sidecar_mtime = os.time() - 1 * HOURS
        call_do_show_reader(file)
        assert.equal(#shown_widgets, 0, "a recent read must not trigger the recap")
    end),

    test("no history and no sidecar does not trigger the recap", function()
        reset_state()
        local file = touch("unknown.epub")
        call_do_show_reader(file)
        assert.equal(#shown_widgets, 0, "without a time source the recap must stay silent")
    end),

    test("a future timestamp clamps to zero and does not trigger", function()
        reset_state()
        local file = touch("future.epub")
        fake_history.hist = { { file = ffiutil.realpath(file), time = os.time() + 10 * HOURS } }
        call_do_show_reader(file)
        assert.equal(#shown_widgets, 0, "a future timestamp must not trigger the recap")
    end),
}

local result = helper.runTests("recap_time", tests)

-- Restore the require and stub environment for the rest of the suite.
UIManager.show = saved_show
ConfirmBox.new = saved_confirmbox_new
for _, name in ipairs(DYNAMIC) do
    package.loaded[name] = saved_dynamic[name].loaded
    package.preload[name] = saved_dynamic[name].preload
end
for mod_idx, modname in ipairs(MODULES) do
    package.loaded[modname] = saved_loaded[modname]
    package.preload[modname] = saved_preload[modname]
end

return result
