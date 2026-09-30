-- test_filemanager_bookinfo.lua
-- Runtime tests for the FileManager long-press AI row in main.lua:
-- getDocumentInfoForFile (metadata resolution without opening the document),
-- _buildFileDialogAIRow (one row, two buttons, gates, callbacks),
-- _registerFileDialogButtons / _removeFileDialogButtons (paired row id), and
-- the onAskAI*ForFile / onAskAIBookInfo entry points.
--
-- main.lua does not load headless on its own: its require chain walks into the
-- reader UI, the document cache, the network manager and the settings modules,
-- all of which probe globals the suite does not set up. The shim below supplies
-- exactly that environment and nothing else -- the plugin code under test runs
-- unmodified. Everything it touches is snapshotted and put back at the end of
-- the file, so the shared test process is not poisoned for the rest of the suite.
local helper = require("test.helper")
local assert = helper.assert

--------------------------------------------------------------------------------
-- Environment snapshot
--------------------------------------------------------------------------------

local REAL_PRELOAD = package.preload

-- Loading main.lua drags in a large slice of the KOReader frontend, so the
-- whole module table is snapshotted: whatever the load chain adds is removed
-- again afterwards.
local PRE_LOADED = {}
for name, mod in pairs(package.loaded) do PRE_LOADED[name] = mod end

local PRE_PRELOAD = {}
for name, factory in pairs(REAL_PRELOAD) do PRE_PRELOAD[name] = factory end

local PRE_GLOBALS = {}
for _, name in ipairs({ "G_reader_settings", "G_defaults" }) do
    PRE_GLOBALS[name] = { rawget(_G, name), rawget(_G, name) ~= nil }
end

--------------------------------------------------------------------------------
-- Environment shim
--------------------------------------------------------------------------------

-- DocCache and DocSettings both resolve paths under DataStorage at load time.
local data_dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/assistant_fm_test"
os.execute("mkdir -p '" .. data_dir .. "/cache'")

-- helper.lua stubs many widget namespaces as bare {} tables, but real KOReader
-- modules subclass them with :extend (and subclass the result again). Hand
-- every stubbed table a class implementation so those modules load.
local function extend_from(parent)
    return function(_, sub)
        local o = setmetatable({}, { __index = parent })
        for k, v in pairs(sub or {}) do o[k] = v end
        if type(o.new) ~= "function" then
            o.new = function(_, opts)
                opts = opts or {}
                return setmetatable(opts, { __index = o })
            end
        end
        o._class = o
        return o
    end
end

-- Adding :extend/:new to a module table mutates shared state, so every table
-- touched is recorded and the added fields removed again on cleanup.
local PATCHED = {}

local function patch_class(mod)
    if type(mod) ~= "table" then return mod end
    local added_extend = false
    local added_new = false
    if type(mod.extend) ~= "function" then
        mod.extend = extend_from(mod)
        added_extend = true
    end
    if type(mod.new) ~= "function" then
        mod.new = function(_, opts)
            opts = opts or {}
            return setmetatable(opts, { __index = mod })
        end
        added_new = true
    end
    if added_extend or added_new then
        PATCHED[#PATCHED + 1] = { mod = mod, extend = added_extend, new = added_new }
    end
    return mod
end

package.preload = setmetatable({}, {
    __index = function(_, name)
        local factory = REAL_PRELOAD[name]
        if not factory then return nil end
        return function(...)
            local args = table.pack(...)
            return patch_class(factory(table.unpack(args, 1, args.n)))
        end
    end,
    __newindex = function(_, name, factory) REAL_PRELOAD[name] = factory end,
})

-- Modules an earlier test file already required never reach the wrapper above:
-- require() hands back the cached table as is. Patch those too, otherwise a
-- bare helper stub is passed to a real KOReader module that subclasses it.
for _, mod in pairs(package.loaded) do patch_class(mod) end


-- Stand-in for the layout constants real widget modules index at load time:
-- any key answers with another permissive table, and any call answers 0.
local function permissive()
    return setmetatable({}, {
        __index = function() return permissive() end,
        __call = function() return 0 end,
    })
end

-- require() consults package.loaded before package.preload, so a preload shim
-- only takes effect once the cached module is dropped. An earlier test file
-- may already have pulled the module in (helper.lua installs stubs for most of
-- them), so the cache has to be cleared here, not just on a clean run. Both
-- tables were snapshotted above, so the original entries come back on cleanup.
local function shim(name, factory)
    package.loaded[name] = nil
    package.preload[name] = factory
end

local fake_font_sizes = {}
for size = 10, 40, 2 do fake_font_sizes[#fake_font_sizes + 1] = size end

-- Both are read at load time by the creoptions / doccache chain.
G_reader_settings = require("luasettings"):open(data_dir .. "/reader.lua")
G_defaults = {
    readSetting = function(_, key)
        if key == "DCREREADER_CONFIG_FONT_SIZES" then return fake_font_sizes end
        return 0
    end,
    saveSetting = function() end,
    delSetting = function() end,
}

-- The dispatcher builds its action table from Device at load time; the plugin
-- itself only needs the screen metrics.
local fake_device = {
    model = "kobo",
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        getSize = function() return { x = 0, y = 0, w = 600, h = 800 } end,
        getDPI = function() return 160 end,
        scaleByDPI = function(_, value) return value end,
        scaleBySize = function(_, value) return value end,
        isColorEnabled = function() return true end,
        refresh = function() end,
    },
    defaultFontSize = 20,
}
setmetatable(fake_device, {
    __index = function(_, key)
        if key == "getPowerDevice" then
            return function() return { fl_max = 100, fl_warmth_max = 100 } end
        end
        return function() end
    end,
})
shim("device", function() return fake_device end)

package.loaded["logger"] = {
    levels = { trace = 1, dbg = 2, info = 3, warn = 4, err = 5 },
    setLevel = function() end,
    dbg = function() end,
    info = function() end,
    warn = function() end,
    err = function() end,
}

shim("datastorage", function()
    return setmetatable({}, {
        __index = function() return function() return data_dir end end,
    })
end)

shim("ffi/blitbuffer", function() return permissive() end)

shim("ui/size", function()
    local Size = permissive()
    Size.line_height = 20
    return Size
end)

shim("ui/network/manager", function()
    return {
        isWifiOn = function() return true end,
        runWhenOnline = function(_, callback) callback() end,
        promptWifiOn = function(_, callback) callback() end,
    }
end)

-- DocCache reads the canvas size off the singleton at load time.
shim("document/canvascontext", function()
    return {
        is_color_rendering_enabled = false,
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
    }
end)

-- main.lua subclasses InputContainer, so that stub has to be a real class.
shim("ui/widget/container/inputcontainer", function()
    local InputContainer = {}
    function InputContainer:new(opts)
        opts = opts or {}
        setmetatable(opts, self)
        self.__index = self
        opts._class = self
        return opts
    end
    function InputContainer:extend(sub) return extend_from(self)(self, sub) end
    return InputContainer
end)

--------------------------------------------------------------------------------
-- Load main.lua, then swap in per-test fakes for the modules its helpers read
--------------------------------------------------------------------------------

local Assistant = require("main")

-- BookList cache: getDocumentInfoForFile and onAskAIRecapForFile both read it.
local booklist_info = nil
package.loaded["ui/widget/booklist"] = {
    getBookInfo = function() return booklist_info end,
}

-- DocumentRegistry: the row gates on hasProvider, and the metadata helper
-- must never open the document.
local document_registry = {
    hasProvider = function() return true end,
    open = function() error("getDocumentInfoForFile must never open the document") end,
}
package.loaded["document/documentregistry"] = document_registry

-- Sidecar DocSettings: returns whatever the current test set up.
local sidecar = nil
package.loaded["docsettings"] = {
    open = function() return sidecar end,
}

local FILEMANAGER_WIDGETS = {
    "apps/filemanager/filemanager",
    "apps/filemanager/filemanagerhistory",
    "apps/filemanager/filemanagercollection",
    "apps/filemanager/filemanagerfilesearcher",
}
local file_dialog_widgets = {}
for idx, modname in ipairs(FILEMANAGER_WIDGETS) do
    file_dialog_widgets[idx] = { name = modname }
    package.loaded[modname] = file_dialog_widgets[idx]
end

-- Row registration bookkeeping. main.lua calls the FileManager helpers as
-- plain functions with the browser widget as the first argument, so the fakes
-- mirror upstream: the row id is a per-widget dedup key.
local added_rows = {}
local removed_rows = {}
file_dialog_widgets[1].addFileDialogButtons = function(widget, row_id, row_func)
    widget.file_dialog_added_buttons = widget.file_dialog_added_buttons or { index = {} }
    if widget.file_dialog_added_buttons.index[row_id] == nil then
        table.insert(widget.file_dialog_added_buttons, row_func)
        widget.file_dialog_added_buttons.index[row_id] = #widget.file_dialog_added_buttons
    end
    table.insert(added_rows, { widget = widget, row_id = row_id, row_func = row_func })
end
file_dialog_widgets[1].removeFileDialogButtons = function(widget, row_id)
    local index = widget.file_dialog_added_buttons
        and widget.file_dialog_added_buttons.index[row_id]
    if index ~= nil then
        table.remove(widget.file_dialog_added_buttons, index)
        if #widget.file_dialog_added_buttons == 0 then
            widget.file_dialog_added_buttons = nil
        else
            widget.file_dialog_added_buttons.index[row_id] = nil
        end
    end
    table.insert(removed_rows, { widget = widget, row_id = row_id })
end

-- Feature dialog invocations.
local feature_runs = {}
package.loaded["assistant_featuredialog"] = setmetatable({}, {
    __call = function(_, assistant, feature, title, authors, percent, extra, notebook_path)
        table.insert(feature_runs, {
            feature = feature, title = title, authors = authors,
            percent = percent, extra = extra, notebook_path = notebook_path,
        })
    end,
})

local shown_widgets = {}
local UIManager = require("ui/uimanager")
UIManager.show = function(_, widget) table.insert(shown_widgets, widget) end

--------------------------------------------------------------------------------
-- Instance and fixtures
--------------------------------------------------------------------------------

local tmp_dir = data_dir .. "/books"
os.execute("mkdir -p '" .. tmp_dir .. "'")

-- A minimal Assistant instance. The FileManager entry points only need a
-- loaded config/handler pair (for isConfigured) and ui; the network gate and
-- the trapper already run the callback inline under helper.lua.
local function configured()
    return {
        config = { getLoadError = function() return nil end },
        querier = { handler = {} },
    }
end

local instance = setmetatable(configured(), { __index = Assistant })
instance.ui = {}

local function reset_state()
    booklist_info = nil
    sidecar = nil
    document_registry.hasProvider = function() return true end
    added_rows = {}
    removed_rows = {}
    feature_runs = {}
    shown_widgets = {}
    instance.ui = {}
    instance.settings = nil
    local ready = configured()
    instance.config = ready.config
    instance.querier = ready.querier
    for _, widget in ipairs(file_dialog_widgets) do
        widget.file_dialog_added_buttons = nil
    end
end

-- A sidecar stand-in: values are read through readSetting/child exactly as
-- the real DocSettings exposes them.
local function make_sidecar(props, percent)
    local values = { percent_finished = percent }
    return {
        readSetting = function(_, key) return values[key] end,
        child = function()
            return { readSetting = function(_, key) return props[key] end }
        end,
    }
end

local function book_file(name)
    return tmp_dir .. "/" .. name
end

local function touch(name)
    local path = book_file(name)
    local handle = io.open(path, "w")
    if not handle then error("cannot create fixture " .. path) end
    handle:write("x")
    handle:close()
    return path
end

local function test(name, fn)
    return { name = name, fn = fn }
end

--------------------------------------------------------------------------------
-- getDocumentInfoForFile: metadata resolution, never opening the document
--------------------------------------------------------------------------------

local tests = {
    test("long-press props win over the file metadata", function()
        reset_state()
        instance.ui.bookinfo = {
            getDocProps = function() error("must not be consulted when props are complete") end,
        }
        local info = instance:getDocumentInfoForFile("book.epub",
            { title = "From Dialog", authors = "Dialog Author" })
        assert.equal(info.title, "From Dialog", "long-press title must win")
        assert.equal(info.authors, "Dialog Author", "long-press author must win")
    end),

    test("book info props fill the gaps left by long-press", function()
        reset_state()
        local props_args = nil
        instance.ui.bookinfo = {
            getDocProps = function(_, file, doc, no_open)
                props_args = { file = file, doc = doc, no_open = no_open }
                return { title = "File Title", authors = { "Ann", "Bo" } }
            end,
        }
        local info = instance:getDocumentInfoForFile("book.epub", { title = "From Dialog" })
        assert.equal(info.title, "From Dialog", "the supplied title stays")
        assert.equal(info.authors, "Ann, Bo", "missing authors come from the file props")
        assert.notNil(props_args, "book info must be consulted for the missing field")
        assert.equal(props_args.file, "book.epub", "book info must see the file")
        assert.equal(props_args.doc, nil, "book info must not be given a document")
        assert.isTrue(props_args.no_open == true,
            "book info must be read without opening the document")
    end),

    test("display_title is the fallback title", function()
        reset_state()
        instance.ui.bookinfo = {
            getDocProps = function() return { display_title = "Shown Title" } end,
        }
        local info = instance:getDocumentInfoForFile("book.epub", nil)
        assert.equal(info.title, "Shown Title", "display_title must be used when title is absent")
    end),

    test("sidecar props are the last metadata source before the file name", function()
        reset_state()
        instance.ui.bookinfo = { getDocProps = function() return {} end }
        sidecar = make_sidecar({ title = "Sidecar Title", authors = "Sidecar Author" }, 0.25)
        local info = instance:getDocumentInfoForFile("book.epub", nil)
        assert.equal(info.title, "Sidecar Title", "sidecar title must be used")
        assert.equal(info.authors, "Sidecar Author", "sidecar author must be used")
        assert.equal(info.percent_finished, 0.25, "sidecar progress must be used")
    end),

    test("the file name is the final title fallback", function()
        reset_state()
        local info = instance:getDocumentInfoForFile("/books/My Great Novel.epub", nil)
        assert.equal(info.title, "My Great Novel", "title must fall back to the file name")
        assert.equal(info.authors, "Unknown Author", "author must have a default")
        assert.equal(info.percent_finished, 0, "progress must default to zero")
    end),

    test("an unresolvable title falls back to the raw path", function()
        reset_state()
        local saved = package.loaded["apps/filemanager/filemanagerutil"]
        package.loaded["apps/filemanager/filemanagerutil"] = {
            splitFileNameType = function() return nil end,
        }
        local info = instance:getDocumentInfoForFile("/books/weird", nil)
        assert.equal(info.title, "/books/weird", "title must fall back to the file path")
        package.loaded["apps/filemanager/filemanagerutil"] = saved
    end),

    test("BookList progress wins over the sidecar", function()
        reset_state()
        booklist_info = { percent_finished = 0.7 }
        sidecar = make_sidecar({}, 0.25)
        local info = instance:getDocumentInfoForFile("book.epub", nil)
        assert.equal(info.percent_finished, 0.7, "the BookList cache is the progress source")
    end),

    test("a non-numeric BookList progress falls back to the sidecar", function()
        reset_state()
        booklist_info = { percent_finished = "unknown" }
        sidecar = make_sidecar({}, 0.25)
        local info = instance:getDocumentInfoForFile("book.epub", nil)
        assert.equal(info.percent_finished, 0.25,
            "sidecar progress must be used when the cache has no number")
    end),

    test("a missing sidecar is not an error", function()
        reset_state()
        local info = instance:getDocumentInfoForFile("/books/Nothing Here.epub", nil)
        assert.equal(info.title, "Nothing Here", "metadata still resolves without a sidecar")
        assert.equal(info.percent_finished, 0, "progress defaults to zero without a sidecar")
    end),
}

--------------------------------------------------------------------------------
-- _buildFileDialogAIRow: the two buttons on one row
--------------------------------------------------------------------------------

table.insert(tests, test("a directory gets no AI row", function()
    reset_state()
    local row = instance:_buildFileDialogAIRow(tmp_dir, false, nil)
    assert.isTrue(row == nil, "a directory must not produce a row")
end))

table.insert(tests, test("a non-string target gets no AI row", function()
    reset_state()
    local row = instance:_buildFileDialogAIRow(nil, true, nil)
    assert.isTrue(row == nil, "a missing file must not produce a row")
end))

table.insert(tests, test("a file without a document provider gets no AI row", function()
    reset_state()
    document_registry.hasProvider = function() return false end
    local row = instance:_buildFileDialogAIRow(touch("plain.txt"), true, nil)
    assert.isTrue(row == nil, "an unsupported file must not produce a row")
end))

table.insert(tests, test("a readable book produces two buttons in one row", function()
    reset_state()
    local path = touch("Row Book.epub")
    local row = instance:_buildFileDialogAIRow(path, true, { title = "Row Book" })
    assert.notNil(row, "a supported existing file must produce a row")
    assert.equal(#row, 2, "both AI buttons must share the one row")
    for idx = 1, 2 do
        assert.notNil(row[idx].callback, "button " .. idx .. " must have a callback")
        assert.isTrue(row[idx].enabled == true, "button " .. idx .. " must be enabled")
        assert.isTrue(type(row[idx].text) == "string" and row[idx].text ~= "",
            "button " .. idx .. " must be labelled")
    end
    assert.isTrue(row[1].text ~= row[2].text, "the two buttons must be distinct")
end))

table.insert(tests, test("a deleted file keeps a disabled row", function()
    reset_state()
    local row = instance:_buildFileDialogAIRow(book_file("gone.epub"), true, nil)
    assert.notNil(row, "a deleted file must still show the row")
    assert.equal(#row, 2, "both buttons stay visible")
    for idx = 1, 2 do
        assert.isFalse(row[idx].enabled, "button " .. idx .. " must be disabled for a missing file")
    end
end))

table.insert(tests, test("each button closes the dialogs before running its action", function()
    reset_state()
    local path = touch("Callback Book.epub")
    local row = instance:_buildFileDialogAIRow(path, true, { title = "Callback Book" })
    local events = {}
    instance._closeFileDialogs = function() table.insert(events, "close") end
    instance.onAskAIBookInfoForFile = function(_, file) table.insert(events, "book_info:" .. file) end
    instance.onAskAIRecapForFile = function(_, file) table.insert(events, "recap:" .. file) end

    row[1].callback()
    assert.equal(#events, 2, "the book info button must run both steps")
    assert.equal(events[1], "close", "the file dialog must close first")
    assert.equal(events[2], "book_info:" .. path, "book info must run for the file")

    events = {}
    row[2].callback()
    assert.equal(events[1], "close", "the file dialog must close first")
    assert.equal(events[2], "recap:" .. path, "recap must run for the file")

    instance._closeFileDialogs = nil
    instance.onAskAIBookInfoForFile = nil
    instance.onAskAIRecapForFile = nil
end))

table.insert(tests, test("the row builder closes every browser file dialog", function()
    reset_state()
    for _, widget in ipairs(file_dialog_widgets) do
        widget.getMenuInstance = function() return { file_dialog = {} } end
    end
    local closed = 0
    local saved_close = UIManager.close
    UIManager.close = function() closed = closed + 1 end
    instance:_closeFileDialogs()
    UIManager.close = saved_close
    for _, widget in ipairs(file_dialog_widgets) do widget.getMenuInstance = nil end
    assert.equal(closed, #file_dialog_widgets, "every browser file dialog must be closed")
end))

--------------------------------------------------------------------------------
-- Registration pairing
--------------------------------------------------------------------------------

table.insert(tests, test("registration and removal use one row id on every browser", function()
    reset_state()
    instance:_registerFileDialogButtons()
    assert.equal(#added_rows, #file_dialog_widgets, "every browser widget must be registered")
    local row_id = added_rows[1].row_id
    assert.notNil(row_id, "a row id is required")
    for idx, entry in ipairs(added_rows) do
        assert.equal(entry.widget, file_dialog_widgets[idx], "each browser must get its own row")
        assert.equal(entry.row_id, row_id,
            "every browser must use the same row id so the buttons stay on one line")
    end

    instance:_removeFileDialogButtons()
    assert.equal(#removed_rows, #file_dialog_widgets, "every browser must be unregistered")
    for idx, entry in ipairs(removed_rows) do
        assert.equal(entry.widget, file_dialog_widgets[idx], "removal must match the browser")
        assert.equal(entry.row_id, row_id, "removal must use the id the row was added with")
    end
    for _, widget in ipairs(file_dialog_widgets) do
        assert.isTrue(widget.file_dialog_added_buttons == nil,
            "the " .. widget.name .. " row must be gone after removal")
    end
end))

table.insert(tests, test("re-registering the same id adds no second row", function()
    reset_state()
    instance:_registerFileDialogButtons()
    instance:_registerFileDialogButtons()
    for _, widget in ipairs(file_dialog_widgets) do
        assert.equal(#widget.file_dialog_added_buttons, 1,
            "the " .. widget.name .. " row must not be duplicated")
    end
    instance:_removeFileDialogButtons()
    assert.equal(#removed_rows, #file_dialog_widgets, "one removal per browser")
end))

table.insert(tests, test("the registered row_func builds the same row", function()
    reset_state()
    instance:_registerFileDialogButtons()
    local path = touch("Registered Book.epub")
    local row = added_rows[1].row_func(path, true, { title = "Registered Book" })
    assert.equal(#row, 2, "the registered callback must build both buttons")
    local direct = instance:_buildFileDialogAIRow(path, true, { title = "Registered Book" })
    assert.equal(row[1].text, direct[1].text, "registered and direct rows must match")
    assert.equal(row[2].text, direct[2].text, "registered and direct rows must match")
end))

table.insert(tests, test("registration is a no-op without the file manager module", function()
    reset_state()
    shim("apps/filemanager/filemanager", function() error("unavailable") end)
    local ok, err = pcall(function()
        instance:_registerFileDialogButtons()
        instance:_removeFileDialogButtons()
    end)
    package.loaded["apps/filemanager/filemanager"] = file_dialog_widgets[1]
    assert.isTrue(ok, "a missing file manager module must not raise: " .. tostring(err))
    assert.equal(#added_rows, 0, "nothing may be registered")
end))

--------------------------------------------------------------------------------
-- Entry points
--------------------------------------------------------------------------------

table.insert(tests, test("book info for a file runs the feature dialog with the file metadata", function()
    reset_state()
    instance.getDocumentInfoForFile = function()
        return { title = "Resolved Title", authors = "Resolved Author", percent_finished = 0.42 }
    end
    local returned = instance:onAskAIBookInfoForFile("/books/Resolved.epub", nil)
    assert.isTrue(returned == true, "the action must report that it handled the event")
    assert.equal(#feature_runs, 1, "the feature dialog must run once")
    assert.equal(feature_runs[1].feature, "book_info", "the book_info feature must run")
    assert.equal(feature_runs[1].title, "Resolved Title", "the resolved title must reach the dialog")
    assert.equal(feature_runs[1].authors, "Resolved Author", "the resolved author must reach the dialog")
    assert.equal(feature_runs[1].percent, 0.42, "the resolved progress must reach the dialog")
    assert.isTrue(feature_runs[1].notebook_path == nil,
        "without multi-notebook there is no per-book path")
    instance.getDocumentInfoForFile = nil
end))

table.insert(tests, test("book info for a file uses the per-book notebook when enabled", function()
    reset_state()
    local wanted = data_dir .. "/notebooks/resolved.md"
    os.execute("mkdir -p '" .. data_dir .. "/notebooks'")
    instance.settings = {
        readSetting = function(_, key)
            if key == "use_multiple_general_notebooks" then return true end
            if key == "general_notebooks_folder" then return data_dir .. "/notebooks" end
        end,
    }
    local asked_for = nil
    local Notebook = require("assistant_notebook")
    local saved = Notebook.getBookNotebookPath
    Notebook.getBookNotebookPath = function(_, file)
        asked_for = file
        return wanted
    end
    instance.getDocumentInfoForFile = function()
        return { title = "T", authors = "A", percent_finished = 0 }
    end
    instance:onAskAIBookInfoForFile("/books/resolved.epub", nil)
    Notebook.getBookNotebookPath = saved
    instance.getDocumentInfoForFile = nil
    instance.settings = nil
    assert.equal(asked_for, "/books/resolved.epub", "the path must be resolved for the book")
    assert.equal(#feature_runs, 1, "the feature dialog must still run once")
    assert.equal(feature_runs[1].notebook_path, wanted, "the per-book path must reach the dialog")
end))

table.insert(tests, test("recap refuses a book that was never opened", function()
    reset_state()
    instance.getDocumentInfoForFile = function()
        return { title = "Unread", authors = "A", percent_finished = 0 }
    end
    local returned = instance:onAskAIRecapForFile("/books/unread.epub", nil)
    assert.isTrue(returned == true, "the action must report that it handled the event")
    assert.equal(#feature_runs, 0, "recap must not run for an unopened book")
    assert.equal(#shown_widgets, 1, "the user must be told why nothing happened")
    assert.notNil(shown_widgets[1].text, "the notice must carry text")
    assert.matches(shown_widgets[1].text, "open this book",
        "the notice must ask the reader to open the book")
    instance.getDocumentInfoForFile = nil
end))

table.insert(tests, test("recap gates on the BookList cache, not the sidecar", function()
    reset_state()
    instance.getDocumentInfoForFile = function()
        return { title = "Sidecar Progress", authors = "A", percent_finished = 0.25 }
    end
    booklist_info = { been_opened = true, percent_finished = 0.8 }
    instance:onAskAIRecapForFile("/books/opened.epub", nil)
    instance.getDocumentInfoForFile = nil
    assert.equal(#feature_runs, 1, "recap must run for an opened book")
    assert.equal(feature_runs[1].feature, "recap", "the recap feature must run")
    assert.equal(feature_runs[1].percent, 0.8, "the BookList cache must supply the progress")
end))

table.insert(tests, test("recap infers been_opened from the progress when the cache is silent", function()
    reset_state()
    instance.getDocumentInfoForFile = function()
        return { title = "T", authors = "A", percent_finished = 0.3 }
    end
    booklist_info = {}
    instance:onAskAIRecapForFile("/books/partly.epub", nil)
    instance.getDocumentInfoForFile = nil
    assert.equal(#feature_runs, 1, "a book with progress must be recapable")
    assert.equal(feature_runs[1].percent, 0.3, "the file progress must be used")
end))

table.insert(tests, test("a never-opened cache entry blocks recap despite file progress", function()
    reset_state()
    instance.getDocumentInfoForFile = function()
        return { title = "T", authors = "A", percent_finished = 0.6 }
    end
    booklist_info = { been_opened = false, percent_finished = 0 }
    instance:onAskAIRecapForFile("/books/unread2.epub", nil)
    instance.getDocumentInfoForFile = nil
    assert.equal(#feature_runs, 0, "been_opened = false must block the recap")
    assert.equal(#shown_widgets, 1, "the reader must be told why")
end))

table.insert(tests, test("nothing runs without a provider", function()
    reset_state()
    instance.config = nil
    instance.querier = nil
    instance:onAskAIBookInfoForFile("/books/x.epub", nil)
    instance:onAskAIRecapForFile("/books/x.epub", nil)
    assert.equal(#feature_runs, 0, "no feature may run unconfigured")
    assert.equal(#shown_widgets, 2, "each action must report the missing provider")
end))

table.insert(tests, test("book info with no open document points at the file manager", function()
    reset_state()
    instance.ui = {}
    local returned = instance:onAskAIBookInfo()
    assert.isTrue(returned == true, "the action must report that it handled the event")
    assert.equal(#feature_runs, 0, "nothing may run without a document")
    assert.equal(#shown_widgets, 1, "the reader must be told where to go instead")
    assert.notNil(shown_widgets[1].text, "the notice must carry text")
    assert.isTrue(shown_widgets[1].text:lower():find("file manager") ~= nil,
        "the notice must name the file manager")
end))

table.insert(tests, test("book info with an open document reads it", function()
    reset_state()
    sidecar = make_sidecar({ title = "Open Title", authors = "Open Author" }, 0.6)
    instance.ui = {
        document = {
            file = "/books/open.epub",
            getProps = function() error("the sidecar must supply the metadata") end,
        },
    }
    local returned = instance:onAskAIBookInfo()
    assert.isTrue(returned == true, "the action must report that it handled the event")
    assert.equal(#shown_widgets, 0, "no notice is needed with a document open")
    assert.equal(#feature_runs, 1, "the feature dialog must run once")
    assert.equal(feature_runs[1].feature, "book_info", "the book_info feature must run")
    assert.equal(feature_runs[1].title, "Open Title", "the open document's title must be used")
    assert.equal(feature_runs[1].authors, "Open Author", "the open document's author must be used")
    assert.equal(feature_runs[1].percent, 0.6, "the open document's progress must be used")
end))

--------------------------------------------------------------------------------
-- Run, then restore the require environment for the rest of the suite
--------------------------------------------------------------------------------

local result = helper.runTests("assistant_filemanager_bookinfo", tests)

UIManager.show = function() end
package.preload = REAL_PRELOAD
for name in pairs(package.loaded) do
    if PRE_LOADED[name] == nil then package.loaded[name] = nil end
end
for name, mod in pairs(PRE_LOADED) do
    package.loaded[name] = mod
end
for _, patched in ipairs(PATCHED) do
    if patched.extend then patched.mod.extend = nil end
    if patched.new then patched.mod.new = nil end
end
for name in pairs(REAL_PRELOAD) do
    if PRE_PRELOAD[name] == nil then REAL_PRELOAD[name] = nil end
end
for name, factory in pairs(PRE_PRELOAD) do
    REAL_PRELOAD[name] = factory
end
for name, saved in pairs(PRE_GLOBALS) do
    if saved[2] then
        _G[name] = saved[1]
    else
        _G[name] = nil
    end
end

return result
