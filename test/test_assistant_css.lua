-- test_assistant_css.lua
-- Guards the shared viewer CSS module (assistant_css.lua): a single BASE
-- (table rules included) built by build(), RTL/justify fragments attaching
-- only when switched on, and both viewers building from that same BASE
-- (ChatGPTViewer via ViewerCSS.build, NotebookViewer via SharedCSS.build).
-- Headless-safe: the module is pure Lua with no KOReader requires; wiring
-- is asserted on shipped sources.
local helper = require("test.helper")
local assert = helper.assert

local CSS = require("assistant_css")

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local viewer_src = read_source("assistant_viewer.lua")
local nb_src = read_source("assistant_notebook.lua")
local main_src = read_source("main.lua")

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("module surface: only build", function()
        assert.isTrue(type(CSS.build) == "function", "module must export build")
        assert.isTrue(CSS.TABLE_CSS == nil, "no independent table css export")
        assert.isTrue(CSS.build_notebook_append == nil, "no notebook append builder")
    end),

    test("build: default keeps base, labels and table rules", function()
        local css = CSS.build()
        assert.matches(css, '@page', "base @page block missing")
        assert.matches(css, '%.assistant%-label %s*{', ".assistant-label rule missing")
        assert.matches(css, 'border%-collapse', "table rules missing")
        assert.matches(css, 'code%.language%-reasoning', "reasoning-only rule missing")
        assert.notMatches(css, 'direction: rtl', "rtl must stay off by default")
        assert.notMatches(css, 'text%-align: justify', "justify must stay off by default")
    end),

    test("build: explicit false opts equal the default", function()
        assert.equal(CSS.build({ rtl = false, justified = false }), CSS.build())
    end),

    test("build: rtl and justify attach only when on", function()
        assert.matches(CSS.build({ rtl = true }), 'direction: rtl', "rtl fragment missing")
        assert.notMatches(CSS.build({ rtl = true }), 'text%-align: justify', "justify must not ride along with rtl")
        assert.matches(CSS.build({ justified = true }), 'text%-align: justify', "justify fragment missing")
        assert.notMatches(CSS.build({ justified = true }), 'direction: rtl', "rtl must not ride along with justify")
        local both = CSS.build({ rtl = true, justified = true })
        assert.matches(both, 'direction: rtl', "rtl fragment missing with both on")
        assert.matches(both, 'text%-align: justify', "justify fragment missing with both on")
    end),

    test("both viewers build from the same base", function()
        assert.isTrue(viewer_src:find('require("assistant_css")', 1, true) ~= nil,
            "viewer must require the shared css module")
        assert.isTrue(viewer_src:find("local VIEWER_CSS", 1, true) == nil,
            "viewer must not keep a local css fork")
        assert.isTrue(viewer_src:find("ViewerCSS.build(", 1, true) ~= nil,
            "viewer must build from the shared module")
        assert.isTrue(nb_src:find('require("assistant_css")', 1, true) ~= nil,
            "notebook must require the shared css module")
        assert.isTrue(nb_src:find("TABLE_CSS", 1, true) == nil,
            "notebook must not keep an independent table css")
        assert.isTrue(nb_src:find("build_notebook_append", 1, true) == nil,
            "notebook must not use a separate append builder")
        assert.isTrue(nb_src:find("SharedCSS.build(", 1, true) ~= nil,
            "notebook injection must build from the same shared base")
        assert.isTrue(nb_src:find("LuaSettings", 1, true) == nil,
            "notebook must not read the settings file directly")
        assert.isTrue(nb_src:find("function M.openNotebookFile(assistant, file)", 1, true) ~= nil,
            "wrapper must take assistant first")
        assert.isTrue(main_src:find("Notebook.openNotebookFile(self, notebookfile)", 1, true) ~= nil,
            "main must pass assistant through")
    end),
}

return helper.runTests("assistant_css", tests)
