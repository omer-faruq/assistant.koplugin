-- test_bookdesc.lua
-- Tests for assistant_hooks (Translate (AI) bottom button on the upstream
-- Book Description popup): patch shape, description resolution, empty-state
-- delegation, and the translate callback chain. Upstream modules are faked;
-- the require environment is restored for the rest of the suite.
local helper = require("test.helper")
local assert = helper.assert

local MODULES = {
    "assistant_hooks",
    "ui/widget/textviewer",
    "apps/filemanager/filemanagerbookinfo",
}

local saved_preload = {}
local saved_loaded = {}
for mod_idx, modname in ipairs(MODULES) do
    saved_preload[modname] = package.preload[modname]
    saved_loaded[modname] = package.loaded[modname]
    package.loaded[modname] = nil
    package.preload[modname] = nil
end

-- Captures TextViewer:new opts instead of building a real widget.
local shown_viewers = {}
local FakeTextViewer = {}
function FakeTextViewer:new(opts)
    table.insert(shown_viewers, opts)
    return opts
end
package.preload["ui/widget/textviewer"] = function() return FakeTextViewer end

-- Minimal upstream stand-in: the wrapped method, prop titles, and the
-- metadata lookup used for resolution.
local orig_calls = {}
local FakeBookInfo = {
    prop_text = { description = "Description:" },
    _props = {},
}
function FakeBookInfo:getDocProps(file)
    return self._props or {}
end
function FakeBookInfo:onShowBookDescription(description, file)
    table.insert(orig_calls, { description = description, file = file })
    return "orig-result"
end
package.preload["apps/filemanager/filemanagerbookinfo"] = function() return FakeBookInfo end

local Hooks = require("assistant_hooks")

local runprompts = {}
local fake_assistant = {
    configured = true,
    dialog = { runPrompt = function(self, text, prompt_id)
        table.insert(runprompts, { text = text, prompt_id = prompt_id })
    end },
}
function fake_assistant:isConfigured()
    return self.configured
end
fake_assistant.assistant_dialog = fake_assistant.dialog

local UIManager = require("ui/uimanager")
local saved_show = UIManager.show
local shown_widgets = {}
UIManager.show = function(self, widget)
    table.insert(shown_widgets, widget)
end

local function reset_state()
    -- All fakes close over these locals, so reassigning resets every hook.
    shown_viewers = {}
    orig_calls = {}
    runprompts = {}
    shown_widgets = {}
    FakeBookInfo._props = {}
    FakeBookInfo.document = nil
    FakeBookInfo.ui = nil
    fake_assistant.configured = true
    fake_assistant.assistant_dialog = fake_assistant.dialog
end

local function setup_once()
    Hooks.setupBookDescription(fake_assistant)
end

local function get_translate_button(viewer_opts)
    assert.notNil(viewer_opts.buttons_table, "viewer must carry custom buttons")
    local row = viewer_opts.buttons_table[1]
    assert.notNil(row, "first button row must exist")
    local btn = row[1]
    assert.notNil(btn, "translate button must exist")
    assert.equal(btn.text, "Translate (AI)", "button text must match")
    return btn
end

-- runWhenOnlineFast reaches for the real network stack, so swap in a
-- pass-through around the callback invocation only, then restore.
local function tap_button(btn)
    local netutils = package.loaded["assistant_net_utils"]
    local saved_run_when_online = netutils.runWhenOnlineFast
    netutils.runWhenOnlineFast = function(callback) callback() end
    local ok, err = pcall(btn.callback)
    netutils.runWhenOnlineFast = saved_run_when_online
    if not ok then error(err) end
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    if not f then return nil end
    local src = f:read("*a")
    f:close()
    return src
end

local function assert_contains(src, needle, msg)
    assert.isTrue(src:find(needle, 1, true) ~= nil, msg or ("missing: " .. needle))
end

local tests = {
    test("setup wraps the method once", function()
        reset_state()
        setup_once()
        assert.isTrue(FakeBookInfo._assistant_bookdesc_translate_patched == true,
            "sentinel must be set on the shared class")
        local first = FakeBookInfo.onShowBookDescription
        setup_once()
        assert.isTrue(FakeBookInfo.onShowBookDescription == first,
            "second setup must not double-wrap")
    end),

    test("explicit description shows a viewer with the translate button", function()
        reset_state()
        setup_once()
        FakeBookInfo:onShowBookDescription("<p>A tale of <b>wonder</b>.</p>", nil)
        assert.equal(#shown_viewers, 1, "one viewer must be shown")
        local viewer = shown_viewers[1]
        assert.equal(viewer.title, "Description:", "title must reuse the upstream prop text")
        assert.equal(viewer.text_type, "book_info", "text type must match upstream")
        assert.isTrue(viewer.add_default_buttons == true,
            "upstream Find/Close rows must be kept")
        assert.isTrue(viewer.text:find("<p>") == nil,
            "description must be plain text, not raw HTML")
        assert.isTrue(viewer.text:find("wonder") ~= nil,
            "description content must survive")
        get_translate_button(viewer)
        assert.equal(#orig_calls, 0, "original must not run when a description exists")
    end),

    test("nil description resolves from file props", function()
        reset_state()
        setup_once()
        FakeBookInfo._props = { description = "From file props" }
        FakeBookInfo:onShowBookDescription(nil, "book.epub")
        assert.equal(#shown_viewers, 1, "viewer must be shown")
        assert.isTrue(shown_viewers[1].text:find("From file props") ~= nil,
            "file metadata description must be used")
        assert.equal(#orig_calls, 0, "original must not run")
    end),

    test("nil description resolves from the open document", function()
        reset_state()
        setup_once()
        FakeBookInfo.document = true
        FakeBookInfo.ui = { doc_props = { description = "Open book desc" } }
        FakeBookInfo:onShowBookDescription(nil, nil)
        assert.equal(#shown_viewers, 1, "viewer must be shown")
        assert.isTrue(shown_viewers[1].text:find("Open book desc") ~= nil,
            "open document description must be used")
    end),

    test("missing description delegates to the original", function()
        reset_state()
        setup_once()
        local ret = FakeBookInfo:onShowBookDescription(nil, "book.epub")
        assert.equal(#shown_viewers, 0, "no viewer must be built")
        assert.equal(#orig_calls, 1, "original must run for the empty state")
        assert.equal(orig_calls[1].file, "book.epub", "original must see the file")
        assert.equal(ret, "orig-result", "original return value must pass through")
    end),

    test("translate button runs the translate prompt on plain text", function()
        reset_state()
        setup_once()
        FakeBookInfo:onShowBookDescription("<p>A tale of <b>wonder</b>.</p>", nil)
        local btn = get_translate_button(shown_viewers[1])
        tap_button(btn)
        assert.equal(#runprompts, 1, "translate must run once")
        assert.equal(runprompts[1].prompt_id, "translate", "must use the translate prompt")
        assert.isTrue(runprompts[1].text:find("<p>") == nil,
            "prompt must receive plain text, not raw HTML")
        assert.isTrue(runprompts[1].text:find("wonder") ~= nil,
            "prompt must receive the description")
    end),

    test("translate button no-ops without provider setup", function()
        reset_state()
        setup_once()
        FakeBookInfo:onShowBookDescription("Some description", nil)
        local btn = get_translate_button(shown_viewers[1])
        fake_assistant.configured = false
        tap_button(btn)
        assert.equal(#runprompts, 0, "nothing must run when unconfigured")
    end),

    test("translate button no-ops without a dialog instance", function()
        reset_state()
        setup_once()
        FakeBookInfo:onShowBookDescription("Some description", nil)
        local btn = get_translate_button(shown_viewers[1])
        fake_assistant.assistant_dialog = nil
        tap_button(btn)
        assert.equal(#runprompts, 0, "nothing must run without assistant_dialog")
    end),

    test("hold shows an explanatory InfoMessage", function()
        reset_state()
        setup_once()
        FakeBookInfo:onShowBookDescription("Some description", nil)
        local btn = get_translate_button(shown_viewers[1])
        btn.hold_callback()
        -- The description viewer itself also passes through UIManager:show,
        -- so the hold notice is the last widget shown.
        assert.isTrue(#shown_widgets >= 2, "hold must show a notice")
        local notice = shown_widgets[#shown_widgets]
        assert.isTrue(notice.text:find("Translates") ~= nil,
            "hold notice must explain the button")
    end),

    test("main.lua delegates all KOReader patches to the hooks module", function()
        local src = read_source("main.lua")
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, 'require("assistant_hooks")',
            "main.lua must require the hooks module")
        assert_contains(src, "Hooks.setupBookDescription(self)",
            "init must run the book description hook")
        local init_pos = src:find("function Assistant:init", 1, true)
        local setup_pos = src:find("Hooks.setupBookDescription(self)", 1, true)
        assert.isTrue(setup_pos > init_pos, "setup must run inside init")
        local ret_pos = src:find("if not next(self.config:getProviderSettings()) then return end", 1, true)
        assert.isTrue(setup_pos < ret_pos, "setup must run before the provider early-return")
        assert_contains(src, "Hooks.syncTranslateOverride(self)",
            "translation patch must be delegated to hooks")
        assert_contains(src, "Hooks.setupRecap(self)",
            "recap patch must be delegated to hooks")
        assert_contains(src, "Hooks.setupMenuOrder()",
            "menu order mutation must be delegated to hooks")
        assert.isTrue(src:find('table.insert(require("ui/elements/reader_menu_order")', 1, true) == nil,
            "reader menu order mutation must not remain in main.lua")
        assert.isTrue(src:find('table.insert(require("ui/elements/filemanager_menu_order")', 1, true) == nil,
            "file manager menu order mutation must not remain in main.lua")
        assert.isTrue(src:find("function Assistant:syncTranslateOverride", 1, true) == nil,
            "translation monkey patch must not remain in main.lua")
        assert.isTrue(src:find("function Assistant:_hookRecap", 1, true) == nil,
            "recap monkey patch must not remain in main.lua")
    end),

    test("hooks module owns the Translator and ReaderUI patches", function()
        local src = read_source("assistant_hooks.lua")
        assert.notNil(src, "could not read assistant_hooks.lua")
        assert_contains(src, "function M.syncTranslateOverride",
            "hooks must expose the translation patch")
        assert_contains(src, "function M.setupRecap",
            "hooks must expose the recap patch")
        assert_contains(src, 'require("ui/translator")',
            "hooks must own the Translator require")
        assert_contains(src, 'require("apps/reader/readerui")',
            "hooks must own the ReaderUI require")
        assert_contains(src, "function M.setupMenuOrder",
            "hooks must expose the menu order patch")
    end),
}

local result = helper.runTests("hooks", tests)

-- Restore the require environment for the rest of the suite.
UIManager.show = saved_show
for mod_idx, modname in ipairs(MODULES) do
    package.loaded[modname] = nil
    package.preload[modname] = saved_preload[modname]
    if saved_loaded[modname] ~= nil then
        package.loaded[modname] = saved_loaded[modname]
    end
end

return result
