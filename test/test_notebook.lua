-- test_notebook.lua
-- Tests for the pure helper functions exported from assistant_notebook.lua:
--   getFolderBasename
--
-- Filesystem-dependent functions (getFolder, list, ...) are not tested headlessly.
local helper = require("test.helper")
local assert = helper.assert
local lfs = require("libs/libkoreader-lfs")
local Notebook = require("assistant_notebook")

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
        local base = (os.getenv("TMPDIR") or "/tmp") .. "/assistant_notebook_folder_test"
        local for_write = base .. "/notes"
        local for_read = base .. "/read_only"
        pcall(function() lfs.rmdir(for_write) end)
        pcall(function() lfs.rmdir(for_read) end)
        pcall(function() lfs.rmdir(base) end)

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
        local base = (os.getenv("TMPDIR") or "/tmp") .. "/assistant_bookmode_multi_test"
        local folder = base .. "/ai_notes"
        pcall(function() lfs.rmdir(folder) end)
        pcall(function() lfs.rmdir(base) end)
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
        local base = (os.getenv("TMPDIR") or "/tmp") .. "/assistant_notebook_defaults_test"
        pcall(function() lfs.mkdir(base) end)
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

    -- =========================================================================
    -- Static wiring guards
    -- =========================================================================

    test("wiring: saveToNotebookFile book branch delegates to helper", function()
        local src = read_source("assistant_notebook.lua")
        assert.notNil(src, "could not read assistant_notebook.lua")
        local start = src:find("function M.saveToNotebookFile", 1, true)
        assert.notNil(start, "saveToNotebookFile must exist")
        local stop = src:find("function M.getActiveDisplayName", 1, true)
        assert.notNil(stop, "getActiveDisplayName must follow saveToNotebookFile")
        local body = src:sub(start, stop)
        assert_contains(body, "M.getBookModeNotebookPath",
            "book branch must call getBookModeNotebookPath")
        assert_contains(body, "getNotebookFile",
            "helper failure must degrade to the legacy getNotebookFile path")
    end),

    test("wiring: main menu book branch uses helper with pcall fallback", function()
        local src = read_source("main.lua")
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, "pcall(Notebook.getBookModeNotebookPath",
            "menu book branch must pcall the new helper")
        assert_contains(src, "self.ui.bookinfo:getNotebookFile(self.ui.doc_settings)",
            "menu must keep the legacy fallback")
    end),
}

return helper.runTests("assistant_notebook.lua", tests)
