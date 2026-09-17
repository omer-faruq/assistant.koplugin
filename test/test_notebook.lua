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

    -- =========================================================================
    -- bookNotebookFilename (pure, headless-safe)
    -- =========================================================================

    test("bookNotebookFilename: swaps book suffix for .md", function()
        assert.equal(Notebook.bookNotebookFilename("/books/Dune.epub", "Untitled"), "Dune.md")
    end),

    test("bookNotebookFilename: keeps dotted stems, uses last suffix", function()
        assert.equal(Notebook.bookNotebookFilename("/books/a.b.pdf", "Untitled"), "a.b.md")
    end),

    test("bookNotebookFilename: suffix-less file gains .md", function()
        assert.equal(Notebook.bookNotebookFilename("/books/README", "Untitled"), "README.md")
    end),

    test("bookNotebookFilename: backslash separators work", function()
        assert.equal(Notebook.bookNotebookFilename("C:\\books\\Dune.mobi", "Untitled"), "Dune.md")
    end),

    test("bookNotebookFilename: empty or missing path falls back", function()
        assert.equal(Notebook.bookNotebookFilename("", "Untitled"), "Untitled.md")
        assert.equal(Notebook.bookNotebookFilename(nil, "Untitled"), "Untitled.md")
    end),
}

return helper.runTests("assistant_notebook.lua", tests)
