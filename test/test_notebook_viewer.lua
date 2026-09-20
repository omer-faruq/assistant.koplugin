-- test_notebook_viewer.lua
-- Tests for assistant_notebook.NotebookViewer (TextViewer subclass for
-- notebooks, defined at the tail of assistant_notebook.lua).
-- UI behavior is not asserted headlessly: the upstream TextViewer is
-- stubbed, and only module shape, render-path selection, the missing-file
-- guard in openFile, and the main.lua wiring are checked.
local helper = require("test.helper")
local assert = helper.assert

local MODULES = {
    "assistant_notebook",
    "assistant_mdparser",
    "ui/widget/textviewer",
}

local saved_preload = {}
local saved_loaded = {}
for mod_idx, modname in ipairs(MODULES) do
    saved_preload[modname] = package.preload[modname]
    saved_loaded[modname] = package.loaded[modname]
end

-- Upstream stand-in: extend plus a faithful minimal init mirroring
-- TextViewer:init (format resolve, txt/html branch, outer css built from
-- the justified/monospace flags, scroll widget holding body/css for
-- setContent). Enough to replay open/toggle/Plain-text flows headlessly.
local TextViewerStub = {}
function TextViewerStub:extend(fields)
    local class = {}
    for key, val in pairs(fields or {}) do
        class[key] = val
    end
    setmetatable(class, { __index = TextViewerStub })
    return class
end
function TextViewerStub:init(reinit)
    self._stub_init_reinit = reinit
    local util = require("util")
    self.text_format = self.text_format
        or (self.file and string.lower(util.getFileNameSuffix(self.file))) or ""
    self.is_txt = self.force_txt or not self.html_text_formats[self.text_format]
    if self.is_txt then
        return
    end
    local css = "body{margin:0;line-height:1.3;"
        .. (self.justified and "text-align: justify;" or "")
        .. (self.monospace_font and "font-family: monospace;" or "") .. "}"
    local box = { _content = {} }
    function box:setContent(body, css_arg)
        self._content.body = body
        self._content.css = css_arg
    end
    local scroll = {
        css = css,
        html_body = "BODY",
        default_font_size = 20,
        is_xhtml = false,
        htmlbox_widget = box,
        _updateScrollBar = function() end,
    }
    self.scroll_widget = scroll
    self.box_widget = box
    box:setContent(scroll.html_body, scroll.css)
end
TextViewerStub.html_text_formats = { html = true, htm = true, md = true }

local function reset_modules(parser_fake)
    for mod_idx, modname in ipairs(MODULES) do
        package.loaded[modname] = nil
        package.preload[modname] = nil
    end
    package.preload["ui/widget/textviewer"] = function() return TextViewerStub end
    if parser_fake then
        package.preload["assistant_mdparser"] = function() return parser_fake end
    end
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
    test("module loads as a TextViewer subclass", function()
        reset_modules(setmetatable({ _is_hoedown = true }, {
            __call = function(_, text) return "<p>" .. text .. "</p>" end,
        }))
        local NotebookViewer = require("assistant_notebook").NotebookViewer
        assert.notNil(NotebookViewer, "assistant_notebook must expose NotebookViewer")
        assert.isTrue(NotebookViewer.init ~= TextViewerStub.init, "must override init")
        assert.isTrue(type(NotebookViewer.openFile) == "function", "must provide openFile")
        assert.isTrue(type(NotebookViewer.renderMarkdown) == "function", "must provide renderMarkdown")
        assert.isTrue(NotebookViewer.TABLE_CSS == nil, "must not keep an independent table css field")
        assert.isTrue(type(NotebookViewer._resolveCSSOpts) == "function", "must resolve css switches")
    end),

    test("renderMarkdown uses hoedown output", function()
        reset_modules(setmetatable({ _is_hoedown = true }, {
            __call = function(_, text) return "<table>" .. text .. "</table>" end,
        }))
        local NotebookViewer = require("assistant_notebook").NotebookViewer
        assert.notNil(NotebookViewer, "assistant_notebook must expose NotebookViewer")
        local html = NotebookViewer.renderMarkdown("| a |\n|---|\n| b |")
        assert.notNil(html, "hoedown output must be used")
        assert_contains(html, "<table>", "rendered html must keep tables")
    end),

    test("renderMarkdown falls back without hoedown", function()
        -- Pure-Lua backend: plain function without _is_hoedown.
        reset_modules(function(text) return "<p>" .. text .. "</p>" end)
        local NotebookViewer = require("assistant_notebook").NotebookViewer
        assert.notNil(NotebookViewer, "assistant_notebook must expose NotebookViewer")
        assert.equal(NotebookViewer.renderMarkdown("# Hi"), nil, "must decline so callers keep the native path")
    end),

    test("renderMarkdown returns nil when hoedown fails", function()
        reset_modules(setmetatable({ _is_hoedown = true }, {
            __call = function() error("boom") end,
        }))
        local NotebookViewer = require("assistant_notebook").NotebookViewer
        assert.notNil(NotebookViewer, "assistant_notebook must expose NotebookViewer")
        assert.equal(NotebookViewer.renderMarkdown("# Hi"), nil, "must not propagate render errors")
    end),

    test("openFile guards missing files", function()
        reset_modules(setmetatable({ _is_hoedown = true }, {
            __call = function(_, text) return text end,
        }))
        local NotebookViewer = require("assistant_notebook").NotebookViewer
        assert.notNil(NotebookViewer, "assistant_notebook must expose NotebookViewer")
        -- Real lfs: attributes is nil, so no UI module is touched.
        NotebookViewer.openFile(nil, "/definitely/not/a/real_notebook.md")
    end),

    test("justify toggle keeps table css across reinit", function()
        reset_modules(setmetatable({ _is_hoedown = true }, {
            __call = function(_, text) return "<table><tr><td>" .. text .. "</td></tr></table>" end,
        }))
        local NotebookViewer = require("assistant_notebook").NotebookViewer
        local inst = setmetatable({
            file = "notes.md",
            text = "# md",
            text_type = "file_content",
            justified = false,
            monospace_font = false,
            force_txt = nil,
            text_format = nil,
        }, { __index = NotebookViewer })
        local function injected_css()
            return inst.scroll_widget.htmlbox_widget._content.css or ""
        end
        -- Open: no justify fragment, table css present.
        NotebookViewer.init(inst, nil)
        assert.notMatches(injected_css(), "text%-align: justify", "open must not justify by default")
        assert.matches(injected_css(), "border%-collapse", "open must inject table css")
        -- Hamburger Justify toggle: reinit must keep both fragments.
        inst.justified = true
        NotebookViewer.init(inst, true)
        assert.matches(injected_css(), "text%-align: justify", "toggle must survive table css injection")
        assert.matches(injected_css(), "border%-collapse", "toggle must keep table css")
        assert.isFalse(inst.is_txt, "toggle must stay in html mode")
        -- Toggle off: justify fragment gone, table css stays.
        inst.justified = false
        NotebookViewer.init(inst, true)
        assert.notMatches(injected_css(), "text%-align: justify", "toggle-off must drop justify")
        assert.matches(injected_css(), "border%-collapse", "toggle-off must keep table css")
        -- Plain-text roundtrip restores the md source without crashing.
        inst.force_txt = true
        NotebookViewer.init(inst, true)
        assert.isTrue(inst.is_txt, "plain-text must switch to txt mode")
        assert.equal(inst.text, "# md", "plain-text must show the md source")
        inst.force_txt = false
        NotebookViewer.init(inst, true)
        assert.isFalse(inst.is_txt, "must return to html mode")
        assert.matches(injected_css(), "border%-collapse", "return must re-inject table css")
    end),

    test("css switches resolve from the passed-in assistant", function()
        reset_modules(setmetatable({ _is_hoedown = true }, {
            __call = function(_, text) return "<table><tr><td>" .. text .. "</td></tr></table>" end,
        }))
        local NotebookViewer = require("assistant_notebook").NotebookViewer
        local stored = { response_is_rtl = true, response_justified = true }
        local fake_assistant = {
            ui_language_is_rtl = false,
            settings = {
                readSetting = function(_, key, default)
                    if stored[key] ~= nil then return stored[key] end
                    return default
                end,
            },
        }
        local inst = setmetatable({
            file = "notes.md",
            text = "# md",
            text_type = "file_content",
            justified = false,
            monospace_font = false,
            force_txt = nil,
            text_format = nil,
            _assistant = fake_assistant,
        }, { __index = NotebookViewer })
        local function injected_css()
            return inst.scroll_widget.htmlbox_widget._content.css or ""
        end
        NotebookViewer.init(inst, nil)
        assert.matches(injected_css(), "direction: rtl", "response_is_rtl must inject the rtl fragment")
        assert.matches(injected_css(), "text%-align: justify", "response_justified must inject the justify fragment")
        assert.matches(injected_css(), "border%-collapse", "shared base must keep table rules")
        -- Switches off: fragments gone, base stays.
        stored.response_is_rtl = nil
        stored.response_justified = nil
        NotebookViewer.init(inst, true)
        assert.notMatches(injected_css(), "direction: rtl", "rtl fragment must drop with the switch off")
        assert.notMatches(injected_css(), "text%-align: justify", "justify fragment must drop with the switch off")
        assert.matches(injected_css(), "border%-collapse", "shared base must keep table rules")
        -- UI locale RTL applies when the response switch is off.
        fake_assistant.ui_language_is_rtl = true
        NotebookViewer.init(inst, true)
        assert.matches(injected_css(), "direction: rtl", "ui language rtl must inject the rtl fragment")
        -- No assistant at all: safe degrade, no crash.
        inst._assistant = nil
        fake_assistant.ui_language_is_rtl = false
        NotebookViewer.init(inst, true)
        assert.notMatches(injected_css(), "direction: rtl", "must degrade without an assistant")
        assert.matches(injected_css(), "border%-collapse", "must keep table rules without an assistant")
    end),

    test("main.lua views notebooks through Notebook.openNotebookFile", function()
        local src = read_source("main.lua")
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, "Notebook.openNotebookFile(self, notebookfile)",
            "View callback must open notebooks via the thin wrapper with assistant")
        local nb_src = read_source("assistant_notebook.lua")
        assert.notNil(nb_src, "could not read assistant_notebook.lua")
        assert_contains(nb_src, "function M.openNotebookFile(assistant, file)",
            "notebook module must expose the thin wrapper")
        assert_contains(nb_src, "M.NotebookViewer.openFile(assistant, file)",
            "thin wrapper must forward to the viewer class")
    end),
}

local result = helper.runTests("notebook_viewer", tests)

-- Restore the require environment for the rest of the suite.
for mod_idx, modname in ipairs(MODULES) do
    package.loaded[modname] = nil
    package.preload[modname] = saved_preload[modname]
    if saved_loaded[modname] ~= nil then
        package.loaded[modname] = saved_loaded[modname]
    end
end

return result
