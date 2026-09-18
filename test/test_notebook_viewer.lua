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

-- Minimal upstream stand-in: only extend/init, which is all the subclass
-- module touches at load time.
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
        assert.isTrue(type(NotebookViewer.TABLE_CSS) == "string", "must carry table css")
        assert_contains(NotebookViewer.TABLE_CSS, "border-collapse", "table css must collapse borders")
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
        NotebookViewer.openFile("/definitely/not/a/real_notebook.md")
    end),

    test("main.lua views notebooks through Notebook.openNotebookFile", function()
        local src = read_source("main.lua")
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, "Notebook.openNotebookFile(notebookfile)",
            "View callback must open notebooks via the thin wrapper")
        local nb_src = read_source("assistant_notebook.lua")
        assert.notNil(nb_src, "could not read assistant_notebook.lua")
        assert_contains(nb_src, "function M.openNotebookFile(file)",
            "notebook module must expose the thin wrapper")
        assert_contains(nb_src, "M.NotebookViewer.openFile(file)",
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
