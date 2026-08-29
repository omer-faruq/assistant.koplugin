-- test_notebook.lua
-- Tests for the pure helper functions exported from assistant_notebook.lua:
--   getFolderBasename
--
-- Filesystem-dependent functions (getFolder, list, ...) are not tested headlessly.
local helper = require("test.helper")
local assert = helper.assert
local Notebook = require("assistant_notebook")

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {

    -- =========================================================================
    -- getFolderBasename
    -- =========================================================================

    test("getFolderBasename: nil returns nil", function()
        assert.equal(Notebook.getFolderBasename(nil), nil)
    end),

    test("getFolderBasename: empty string returns nil", function()
        assert.equal(Notebook.getFolderBasename(""), nil)
    end),

    test("getFolderBasename: absolute path returns last segment", function()
        assert.equal(Notebook.getFolderBasename("/home/user/books/general_notebooks"), "general_notebooks")
    end),

    test("getFolderBasename: trailing slash is ignored", function()
        assert.equal(Notebook.getFolderBasename("/home/user/books/general_notebooks/"), "general_notebooks")
    end),

    test("getFolderBasename: multiple trailing slashes are ignored", function()
        assert.equal(Notebook.getFolderBasename("/home/user/books/general_notebooks//"), "general_notebooks")
    end),

    test("getFolderBasename: relative path returns last segment", function()
        assert.equal(Notebook.getFolderBasename("books/notebooks"), "notebooks")
    end),

    test("getFolderBasename: bare name returned as-is", function()
        assert.equal(Notebook.getFolderBasename("notebooks"), "notebooks")
    end),

    test("getFolderBasename: root path falls back to full path", function()
        assert.equal(Notebook.getFolderBasename("/"), "/")
    end),
}

return helper.runTests("assistant_notebook.lua", tests)
