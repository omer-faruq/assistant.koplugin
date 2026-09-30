-- test_notebook.lua
-- Tests for the helper functions exported from assistant_notebook.lua:
-- getFolderBasename, bookNotebookFilename, getFolder,
-- getBookModeNotebookPath, getLegacyPath, getActiveDisplayName. The
-- filesystem-dependent ones run against unique tmp directories.
local helper = require("test.helper")
local assert = helper.assert
local lfs = require("libs/libkoreader-lfs")
local Notebook = require("assistant_notebook")

-- Unique per run, so a leftover directory or a parallel run cannot collide
-- with a half-created one from a previous failure.
local tmp_seq = 0
local function tmp_dir(label)
    tmp_seq = tmp_seq + 1
    local tag = tostring({}):match("0x%x+") or tostring(os.time())
    return (os.getenv("TMPDIR") or "/tmp")
        .. "/assistant_notebook_" .. label .. "_" .. tag .. "_" .. tmp_seq
end

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
        assert.equal(Notebook.getFolderBasename("/home/user/books/ai_notes"), "ai_notes")
    end),

    test("getFolderBasename: trailing slash is ignored", function()
        assert.equal(Notebook.getFolderBasename("/home/user/books/ai_notes/"), "ai_notes")
    end),

    test("getFolderBasename: multiple trailing slashes are ignored", function()
        assert.equal(Notebook.getFolderBasename("/home/user/books/ai_notes//"), "ai_notes")
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

    -- =========================================================================
    -- getFolder with a configured folder (headless-safe tmp dirs)
    -- =========================================================================

    test("getFolder: missing configured folder is created for write only", function()
        local base = tmp_dir("folder")
        local for_write = base .. "/notes"
        local for_read = base .. "/read_only"

        local fake_write = {
            settings = {
                readSetting = function() return for_write end,
            },
        }
        local folder, err = Notebook.getFolder(fake_write, true)
        assert.equal(folder, for_write)
        assert.isTrue(err == nil, "no error expected, got: " .. tostring(err))
        assert.equal(lfs.attributes(for_write, "mode"), "directory")

        -- Reads must not create a missing configured folder: they fall back
        -- to the default folder instead. The config stub points the default
        -- base at the existing tmp dir so no device globals are needed.
        local fake_read = {
            settings = {
                readSetting = function() return for_read end,
            },
            config = {
                getFeature = function(_, key)
                    if key == "default_folder_for_logs" then return base end
                    return nil
                end,
            },
        }
        local read_folder, read_err, read_warning = Notebook.getFolder(fake_read, false)
        assert.isTrue(read_folder ~= for_read, "reads must not use a missing configured folder")
        assert.isTrue(lfs.attributes(for_read, "mode") == nil, "reads must not create directories")
        assert.isTrue(read_warning ~= nil, "fallback must warn, got err: " .. tostring(read_err))

        assert.isTrue(lfs.rmdir(for_write))
        assert.isTrue(lfs.rmdir(base))
    end),

    -- =========================================================================
    -- getBookModeNotebookPath (headless, tmp dirs)
    -- =========================================================================

    test("getBookModeNotebookPath: multi enabled wins and persists setting", function()
        local base = tmp_dir("bookmode_multi")
        local folder = base .. "/ai_notes"
        assert.isTrue(lfs.mkdir(base))

        local saved = {}
        local doc_settings = {
            readSetting = function(_, key)
                if key == "doc_path" then return "/books/Dune.epub" end
                return nil
            end,
            saveSetting = function(_, key, value)
                saved[key] = value
            end,
        }
        local assistant = {
            settings = {
                readSetting = function(_, key)
                    if key == "use_multiple_general_notebooks" then return true end
                    if key == "general_notebooks_folder" then return folder end
                    return nil
                end,
            },
            config = {
                -- Even with a default folder set, multi-notebook must win.
                getFeature = function(_, key)
                    if key == "default_folder_for_logs" then return "/some/other_logs" end
                    return nil
                end,
            },
            ui = {
                doc_settings = doc_settings,
                document = { file = "/books/Dune.epub" },
                bookinfo = {
                    getNotebookFile = function()
                        return "/books/Dune.sdr/metadata.lua"
                    end,
                },
            },
        }

        local path, err = Notebook.getBookModeNotebookPath(assistant)
        assert.equal(path, folder .. "/Dune.md")
        assert.isTrue(err == nil, "no error expected, got: " .. tostring(err))
        assert.equal(saved["notebook_file"], folder .. "/Dune.md")
        assert.equal(lfs.attributes(folder, "mode"), "directory")

        assert.isTrue(lfs.rmdir(folder))
        assert.isTrue(lfs.rmdir(base))
    end),

    test("getBookModeNotebookPath: multi disabled uses legacy sidecar default", function()
        local saved = {}
        local doc_settings = {
            readSetting = function() return nil end,
            saveSetting = function(_, key, value)
                saved[key] = value
            end,
        }
        local assistant = {
            settings = {
                readSetting = function() return nil end,
            },
            config = {
                getFeature = function() return nil end,
            },
            ui = {
                doc_settings = doc_settings,
                document = { file = "/books/Dune.epub" },
                bookinfo = {
                    getNotebookFile = function()
                        return "/books/Dune.sdr/metadata.lua"
                    end,
                },
            },
        }

        local path, err = Notebook.getBookModeNotebookPath(assistant)
        assert.isTrue(err == nil, "no error expected, got: " .. tostring(err))
        assert.equal(path, "/books/Dune.sdr/metadata.md")
        assert.equal(saved["notebook_file"], "/books/Dune.sdr/metadata.md")
    end),

    test("getBookModeNotebookPath: without doc_settings returns nil plus error", function()
        local assistant = {
            settings = {
                readSetting = function() return true end,
            },
            config = {
                getFeature = function() return nil end,
            },
            ui = {},
        }
        local path, err = Notebook.getBookModeNotebookPath(assistant)
        assert.equal(path, nil)
        assert.notNil(err)
    end),

    -- =========================================================================
    -- Defaults: legacy path and display name use AI Notes
    -- =========================================================================

    test("defaults: legacy path is ai_notes.md with AI Notes display name", function()
        local base = tmp_dir("defaults")
        assert.isTrue(lfs.mkdir(base))
        local assistant = {
            settings = {
                readSetting = function() return nil end,
            },
            config = {
                getFeature = function(_, key)
                    if key == "default_folder_for_logs" then return base end
                    return nil
                end,
            },
        }
        assert.equal(Notebook.getLegacyPath(assistant), base .. "/ai_notes.md")
        assert.equal(Notebook.getActiveDisplayName(assistant), "AI Notes")
        assert.isTrue(lfs.rmdir(base))
    end),
}

return helper.runTests("assistant_notebook.lua", tests)
