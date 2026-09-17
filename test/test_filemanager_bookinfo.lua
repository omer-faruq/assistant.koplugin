-- test_filemanager_bookinfo.lua
-- Static guard for the FileManager long-press "Book Info (AI)" wiring in
-- main.lua: registration/removal pairing, gettext/ASCII button text, metadata
-- helper priorities, and the nil-document guard on onAskAIBookInfo.
--
-- The helper lives on the plugin object in main.lua, which cannot be required
-- headless (widget constructors), so -- like test_gettext_ascii_msgids.lua and
-- test_gettext_loop_shadow.lua -- this file asserts on source text instead.
local helper = require("test.helper")
local assert = helper.assert

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_main()
    local f = io.open(project_root .. "main.lua", "r")
    if not f then return nil end
    local src = f:read("*a")
    f:close()
    return src
end

local function read_file(name)
    local f = io.open(project_root .. name, "r")
    if not f then return nil end
    local src = f:read("*a")
    f:close()
    return src
end

-- Plain-substring assertion (no pattern magic).
local function assert_contains(src, needle, msg)
    assert.isTrue(src:find(needle, 1, true) ~= nil, msg or ("missing: " .. needle))
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("single row id is registered and removed with the same id", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, 'FM_AI_ROW_ID = "assistant_ai"',
            "row id constant must be assistant_ai")
        assert_contains(src, "addFileDialogButtons(widget, FM_AI_ROW_ID",
            "both buttons must share one row id for a single line")
        assert_contains(src, "removeFileDialogButtons(widget, FM_AI_ROW_ID",
            "single row id must be removed with the same id")
        assert.isTrue(src:find("FM_BOOK_INFO_ROW_ID", 1, true) == nil,
            "legacy book info row id must be gone")
        assert.isTrue(src:find("FM_RECAP_ROW_ID", 1, true) == nil,
            "legacy recap row id must be gone")
    end),

    test("both buttons are built in one row", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, "function Assistant:_buildFileDialogAIRow",
            "combined row builder must exist")
        local start = src:find("function Assistant:_buildFileDialogAIRow", 1, true)
        local stop = src:find("function Assistant:_closeFileDialogs", 1, true)
        assert.notNil(stop, "_closeFileDialogs must exist")
        local body = src:sub(start, stop)
        assert_contains(body, '_("Book Info (AI)")',
            "combined row must contain the book info button")
        assert_contains(body, '_("Recap (AI)")',
            "combined row must contain the recap button")
        assert_contains(body, "if not is_file then return nil",
            "directories must return nil (no row)")
        assert_contains(body, "DocumentRegistry:hasProvider(file)",
            "files without a document provider must return nil (no row)")
    end),

    test("button label is gettext-wrapped ASCII Title Case with (AI) suffix", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, '_("Book Info (AI)")',
            'button text must be _("Book Info (AI)")')
    end),

    test("row hides for dirs, disables for deleted files", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, "function Assistant:_buildFileDialogAIRow",
            "row builder must exist")
        assert_contains(src, "if not is_file then return nil",
            "directories must return nil (no row)")
        assert_contains(src, "local enabled = koutil.pathExists(file)",
            "deleted files must disable the buttons instead of hiding them")
        assert_contains(src, "enabled = enabled",
            "both buttons must carry the enabled flag")
        assert_contains(src, "DocumentRegistry:hasProvider(file)",
            "files without a document provider must return nil (no row)")
    end),

    test("file metadata helper prefers props over opening the document", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        local start = src:find("function Assistant:getDocumentInfoForFile", 1, true)
        assert.notNil(start, "getDocumentInfoForFile must exist")
        local stop = src:find("function Assistant:_buildFileDialogAIRow", 1, true)
        assert.notNil(stop, "row builder must follow the helper")
        assert.isTrue(stop > start, "helper must precede the row builder")
        local body = src:sub(start, stop)
        assert_contains(body, ", file, nil, true)",
            "helper must read metadata without opening the document")
        assert_contains(body, "splitFileNameType",
            "helper must fall back to the file name")
        assert_contains(body, "percent_finished",
            "helper must read progress from the sidecar settings")
        assert.isTrue(body:find("openDocument", 1, true) == nil,
            "helper must never open the document")
    end),

    test("callback closes the dialog before running book_info", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        local start = src:find("function Assistant:_buildFileDialogAIRow", 1, true)
        assert.notNil(start, "combined row builder must exist")
        local stop = src:find("function Assistant:_closeFileDialogs", 1, true)
        assert.notNil(stop, "_closeFileDialogs must exist")
        local body = src:sub(start, stop)
        local close_pos = body:find("_closeFileDialogs", 1, true)
        local run_pos = body:find("onAskAIBookInfoForFile", 1, true)
        assert.notNil(close_pos, "callback must close the file dialog")
        assert.notNil(run_pos, "callback must run book_info for the file")
        assert.isTrue(close_pos < run_pos, "dialog must close before book_info runs")
    end),

    test("init registers on the FileManager side, onClose removes", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, "self:_registerFileDialogButtons()",
            "init must register the file dialog button")
        local close_fn = src:find("function Assistant:onClose", 1, true)
        assert.notNil(close_fn, "onClose must exist for paired removal")
        assert_contains(src:sub(close_fn, close_fn + 200), "self:_removeFileDialogButtons()",
            "onClose must remove the file dialog button")
    end),

    test("onAskAIBookInfo guards a nil open document", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        local start = src:find("function Assistant:onAskAIBookInfo(", 1, true)
        assert.notNil(start, "onAskAIBookInfo must exist")
        local stop = src:find("function Assistant:onAskAIBookInfoForFile", 1, true)
        assert.notNil(stop, "file variant must exist")
        local body = src:sub(start, stop)
        assert_contains(body, 'tableGetValue(self, "ui", "document")',
            "onAskAIBookInfo must guard a nil open document")
        assert_contains(body, "No book is open.",
            "nil document must show an InfoMessage instead of crashing")
    end),

    test("recap shares the single AI row with no legacy ids", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, 'FM_AI_ROW_ID = "assistant_ai"',
            "single AI row id constant must be assistant_ai")
        assert_contains(src, "addFileDialogButtons(widget, FM_AI_ROW_ID",
            "both buttons must be registered with the single row id")
        assert.isTrue(src:find("FM_RECAP_ROW_ID", 1, true) == nil,
            "legacy recap row id must be gone")
        assert.isTrue(src:find("FM_BOOK_INFO_ROW_ID", 1, true) == nil,
            "legacy book info row id must be gone")
    end),

    test("recap button label is gettext-wrapped ASCII Title Case with (AI) suffix", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, '_("Recap (AI)")',
            'recap button text must be _("Recap (AI)")')
    end),

    test("recap row is gated on is_file and a document provider", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        local start = src:find("function Assistant:_buildFileDialogAIRow", 1, true)
        assert.notNil(start, "combined row builder must exist")
        local stop = src:find("function Assistant:_closeFileDialogs", 1, true)
        assert.notNil(stop, "_closeFileDialogs must exist")
        local body = src:sub(start, stop)
        assert_contains(body, "if not is_file then return nil",
            "recap directories must return nil (no row)")
        assert_contains(body, "DocumentRegistry:hasProvider(file)",
            "recap files without a document provider must return nil (no row)")
        assert_contains(body, "onAskAIRecapForFile",
            "recap callback must run recap for the file")
        local close_pos = body:find("_closeFileDialogs", 1, true)
        local run_pos = body:find("onAskAIRecapForFile", 1, true)
        assert.notNil(close_pos, "recap callback must close the file dialog")
        assert.isTrue(close_pos < run_pos, "recap dialog must close before recap runs")
    end),

    test("recap for file gates on been_opened and progress with InfoMessage", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        local start = src:find("function Assistant:onAskAIRecapForFile", 1, true)
        assert.notNil(start, "onAskAIRecapForFile must exist")
        local body = src:sub(start, start + 2500)
        assert_contains(body, "getDocumentInfoForFile",
            "recap must reuse getDocumentInfoForFile for title/authors/percent")
        assert_contains(body, "getBookInfo",
            "recap must read BookList.getBookInfo for been_opened and progress")
        assert_contains(body, "been_opened",
            "recap must gate on been_opened")
        assert_contains(body, "before requesting a recap",
            "unopened books must show an InfoMessage instead of running")
        assert_contains(body, "InfoMessage:new",
            "unopened books must show an InfoMessage instead of running")
        assert_contains(body, 'showFeatureDialog(self, "recap"',
            "recap must run the recap feature dialog once gated")
    end),

    test("progress prefers the BookList cache over sidecar settings", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        local start = src:find("function Assistant:getDocumentInfoForFile", 1, true)
        assert.notNil(start, "getDocumentInfoForFile must exist")
        local stop = src:find("function Assistant:_buildFileDialogAIRow", 1, true)
        assert.notNil(stop, "row builder must follow the helper")
        local body = src:sub(start, stop)
        assert_contains(body, "getBookInfo",
            "helper must prefer the BookList progress cache")
        assert_contains(body, "percent_finished",
            "helper must keep the sidecar fallback")
    end),

    test("ForFile entries resolve a per-book notebook path", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        local start = src:find("function Assistant:onAskAIBookInfoForFile", 1, true)
        assert.notNil(start, "onAskAIBookInfoForFile must exist")
        local stop = src:find("function Assistant:onAskAIRecapForFile", 1, true)
        assert.notNil(stop, "onAskAIRecapForFile must exist")
        local body = src:sub(start, stop)
        assert_contains(body, "getBookNotebookPath",
            "book info for file must resolve a per-book notebook path")
        assert_contains(body, "Notebook.isEnabled",
            "per-book path must only apply in multi-notebook mode")
        local recap = src:sub(stop, stop + 2500)
        assert_contains(recap, "getBookNotebookPath",
            "recap for file must resolve a per-book notebook path")
    end),

    test("featuredialog accepts a notebook path for the viewer", function()
        local src = read_file("assistant_featuredialog.lua")
        assert.notNil(src, "could not read assistant_featuredialog.lua")
        assert_contains(src, "message_history, notebook_path",
            "showFeatureDialog must accept a notebook path")
        assert_contains(src, "notebook_path = notebook_path",
            "notebook path must reach ChatGPTViewer")
    end),

    test("viewer saves through its notebook path", function()
        local src = read_file("assistant_viewer.lua")
        assert.notNil(src, "could not read assistant_viewer.lua")
        assert_contains(src, "saveToNotebookFile(self.assistant, log_entry, self.notebook_path)",
            "viewer save must pass its notebook path")
        assert_contains(src, "self.notebook_path = nil",
            "explicit picker choice must clear the per-book path")
        assert_contains(src, "notebook_path:match(",
            "multi-notebook subtitle must prefer the per-book basename")
    end),

    test("main menu notebook picks first in FM multi-notebook mode", function()
        local src = read_main()
        assert.notNil(src, "could not read main.lua")
        assert_contains(src, "showNotebookFileDialog",
            "notebook file dialog must be a reusable local function")
        assert_contains(src, 'title = _("Notebooks")',
            "FM multi-notebook menu must open the notebook picker")
        assert_contains(src, "showNotebookFileDialog(notebook.path, false, false)",
            "picked notebook must reuse the file dialog without Switch")
    end),
}

return helper.runTests("assistant_filemanager_bookinfo", tests)
