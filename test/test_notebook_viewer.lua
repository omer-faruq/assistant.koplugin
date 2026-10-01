-- test_notebook_viewer.lua
-- Tests for assistant_notebook.NotebookViewer (TextViewer subclass for
-- notebooks, defined at the tail of assistant_notebook.lua).
-- Headless-safe: the upstream TextViewer is replaced by a stand-in that only
-- hands the subclass a scroll widget with an empty CSS channel, so the rules
-- observed afterwards are the ones NotebookViewer itself injected. What is
-- exercised at runtime: the plugin Markdown render path, the html/plain-text
-- round trip across reinit, and the shared-viewer CSS injection driven by the
-- resolved display switches. Module shape and main.lua wiring are not pinned
-- here.
local helper = require("test.helper")
local assert = helper.assert
local SharedCSS = require("assistant_css")

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

-- Upstream stand-in: extend plus the one thing NotebookViewer:init needs from
-- TextViewer:init -- a scroll widget with an empty CSS channel and a content
-- sink. The channel starts empty on purpose, so every rule read back after an
-- init is one the subclass injected.
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
    self._stub_reinit = reinit
    local box = { _content = {} }
    function box:setContent(body, css_arg)
        self._content.body = body
        self._content.css = css_arg
    end
    self.scroll_widget = {
        css = "",
        html_body = self.text or "",
        htmlbox_widget = box,
    }
    self.box_widget = box
end

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

-- A viewer instance with just the fields the real init reads.
local function make_instance(fields)
    local NotebookViewer = require("assistant_notebook").NotebookViewer
    local inst = {
        file = "notes.md",
        text = "# md",
        text_type = "file_content",
        justified = false,
        monospace_font = false,
        force_txt = nil,
        text_format = nil,
    }
    for key, val in pairs(fields or {}) do
        inst[key] = val
    end
    return setmetatable(inst, { __index = NotebookViewer })
end

local function injected_css(inst)
    local scroll = inst.scroll_widget
    local content = scroll and scroll.htmlbox_widget and scroll.htmlbox_widget._content
    return (content and content.css) or ""
end

local table_parser = setmetatable({ _is_hoedown = true }, {
    __call = function(_, text) return "<table>" .. text .. "</table>" end,
})

local tests = {
    test("renderMarkdown uses hoedown output", function()
        reset_modules(table_parser)
        local NotebookViewer = require("assistant_notebook").NotebookViewer
        assert.notNil(NotebookViewer, "assistant_notebook must expose NotebookViewer")
        local html = NotebookViewer.renderMarkdown("| a |\n|---|\n| b |")
        assert.notNil(html, "hoedown output must be used")
        assert.isTrue(html:find("<table>", 1, true) ~= nil, "rendered html must keep tables")
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

    test("openFile shows nothing for a missing file", function()
        reset_modules(table_parser)
        local UIManager = require("ui/uimanager")
        local NotebookViewer = require("assistant_notebook").NotebookViewer
        assert.notNil(NotebookViewer, "assistant_notebook must expose NotebookViewer")
        local shown = 0
        local saved_show = UIManager.show
        UIManager.show = function() shown = shown + 1 end
        local ok, err = pcall(NotebookViewer.openFile, nil, "/definitely/not/a/real_notebook.md")
        UIManager.show = saved_show
        assert.isTrue(ok, "a missing file must not throw: " .. tostring(err))
        assert.equal(shown, 0, "no viewer may be built for a missing file")
    end),

    test("init renders the markdown source and injects the shared viewer CSS", function()
        reset_modules(table_parser)
        local inst = make_instance()
        inst:init(nil)
        -- The rendered html replaces the source in the shown text.
        assert.isTrue(inst.text:find("<table>", 1, true) ~= nil,
            "the page must show the rendered html, not the raw markdown")
        assert.equal(inst.text_format, "html", "the rendered text must be handed on as html")
        -- What landed in the channel is exactly the shared viewer stylesheet.
        assert.equal(injected_css(inst), SharedCSS.build({}),
            "the notebook viewer must inject the shared viewer CSS")
        -- Plain-text toggle: the source comes back and the html-only rules go.
        inst.force_txt = true
        inst:init(true)
        assert.equal(inst.text, "# md", "plain-text must show the markdown source")
        assert.equal(injected_css(inst), "", "plain-text mode must not get the html stylesheet")
        -- Back to html: the source is re-rendered, not the previous html.
        inst.force_txt = false
        inst:init(true)
        assert.isTrue(inst.text:find("<table>", 1, true) ~= nil,
            "leaving plain-text mode must re-render the source")
        assert.equal(injected_css(inst), SharedCSS.build({}), "the stylesheet must be re-injected")
    end),

    test("display switches follow the modes resolved from the passed-in assistant", function()
        reset_modules(table_parser)
        local stored = { response_direction = "rtl", response_justified = true }
        local inst = make_instance({ _assistant = {
            ui_language_is_rtl = false,
            settings = {
                readSetting = function(_, key, default)
                    if stored[key] ~= nil then return stored[key] end
                    return default
                end,
            },
        } })
        inst:init(nil)
        local opts = inst:_displayOpts()
        assert.equal(opts.mode, "rtl", "response_direction must resolve to its stored mode")
        assert.isTrue(opts.justified, "response_justified must resolve to justified")
        inst.scroll_widget.css = "" -- measure one injection from a clean channel
        inst:_injectTableCSS()
        assert.equal(injected_css(inst), SharedCSS.build({ justified = true }),
            "the injected rules must match the resolved switches")
        -- The upstream Justify toggle ORs into the same switch.
        inst.justified = true
        stored.response_justified = nil
        assert.isTrue(inst:_displayOpts().justified, "the viewer Justify toggle must hold justification")
        -- With the mode unset, the UI language direction decides.
        stored.response_direction = nil
        inst._assistant.ui_language_is_rtl = true
        assert.equal(inst:_displayOpts().mode, "auto", "an rtl UI locale must start on auto")
        -- An explicit ltr wins over the RTL UI locale.
        stored.response_direction = "ltr"
        assert.equal(inst:_displayOpts().mode, "ltr", "an explicit ltr must resolve to ltr")
        -- An explicit auto is stored state too, and it wins the other way.
        stored.response_direction = "auto"
        inst._assistant.ui_language_is_rtl = false
        assert.equal(inst:_displayOpts().mode, "auto", "an explicit auto must survive a non-rtl locale")
        -- Unset with a non-rtl locale: the pipeline stays out of the way.
        stored.response_direction = nil
        assert.equal(inst:_displayOpts().mode, "ltr", "a non-rtl UI locale must start on ltr")
        -- A value the UI never writes is ignored, not passed through.
        stored.response_direction = "sideways"
        stored.response_is_rtl = true
        assert.equal(inst:_displayOpts().mode, "auto",
            "an unknown stored mode must fall through to the legacy switch")
        stored.response_direction = nil
        -- A legacy boolean still reads: true handled the RTL reply per block.
        stored.response_is_rtl = true
        assert.equal(inst:_displayOpts().mode, "auto", "a legacy true must resolve to auto")
        stored.response_is_rtl = false
        assert.equal(inst:_displayOpts().mode, "ltr", "a legacy false must resolve to ltr")
        -- No assistant at all: the base stylesheet, no crash.
        inst.justified = false
        inst._assistant = nil
        local bare = inst:_displayOpts()
        assert.equal(bare.mode, "ltr", "no assistant means no pipeline")
        assert.isFalse(bare.justified, "no assistant means no justification")
        inst.scroll_widget.css = ""
        inst:_injectTableCSS()
        assert.equal(injected_css(inst), SharedCSS.build({}),
            "a viewer without an assistant must still get the base rules")
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
