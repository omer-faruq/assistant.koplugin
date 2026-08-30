local T = require("ffi/util").template
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local _ = require("assistant_gettext")
local ASUtils = require("assistant_utils")

local M = {}

local GENERAL_NOTEBOOKS_DIR = "general_notebooks"
local LEGACY_NOTEBOOK_FILENAME = "general_notebook.md"
local ACTIVE_NOTEBOOK_SETTING = "active_general_notebook"
local MULTI_NOTEBOOK_SETTING = "use_multiple_general_notebooks"
local FOLDER_SETTING = "general_notebooks_folder"

local function joinPath(parent, child)
    if not parent or parent == "" then
        return nil
    end
    if parent:sub(-1) == "/" then
        return parent .. child
    end
    return parent .. "/" .. child
end

local function getCurrentBaseDirectory(assistant)
    local default_folder = assistant:confGetFeature("default_folder_for_logs")
    if default_folder and default_folder ~= ""
        and lfs.attributes(default_folder, "mode") == "directory" then
        return default_folder
    end

    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir and home_dir ~= ""
        and lfs.attributes(home_dir, "mode") == "directory" then
        return home_dir
    end

    if assistant and assistant.ui then
        if assistant.ui.file_chooser and assistant.ui.file_chooser.path then
            return assistant.ui.file_chooser.path
        end
        if assistant.ui.getLastDirFile then
            return assistant.ui:getLastDirFile()
        end
    end

    return nil
end

local function getMode(path)
    if not path then
        return nil
    end
    return lfs.attributes(path, "mode")
end

local function isDirectory(path)
    return getMode(path) == "directory"
end

local function isFile(path)
    return getMode(path) == "file"
end

local function displayName(filename)
    return filename:gsub("%.[mM][dD]$", "")
end

local function makeEntry(path, filename, legacy)
    local attr = lfs.attributes(path)
    return {
        name = displayName(filename),
        filename = filename,
        path = path,
        mtime = attr and attr.modification or 0,
        legacy = legacy == true,
    }
end

local function validateStoredFilename(filename)
    if type(filename) ~= "string" or filename == "" then
        return false
    end
    if filename:find("[/\\]") or filename:find("..", 1, true) then
        return false
    end
    return filename:lower():sub(-3) == ".md"
end

function M.isEnabled(assistant)
    return assistant
        and assistant.settings
        and assistant.settings:readSetting(MULTI_NOTEBOOK_SETTING, false)
        or false
end

function M.getLegacyPath(assistant)
    local target_dir = getCurrentBaseDirectory(assistant)
    return target_dir and joinPath(target_dir, LEGACY_NOTEBOOK_FILENAME) or nil
end

function M.getGeneralNotebookFilePath(assistant)
    if M.isEnabled(assistant) then
        local notebook, err, warning = M.getActive(assistant)
        if notebook then
            return notebook.path, warning or err
        end
        return M.getLegacyPath(assistant), warning or err
    end
    return M.getLegacyPath(assistant)
end

-- Returns the notebooks folder chosen in Settings, if any.
function M.getConfiguredFolder(assistant)
    local folder = assistant and assistant.settings
        and assistant.settings:readSetting(FOLDER_SETTING)
        or nil
    if folder and folder ~= "" then
        return folder
    end
end

-- Returns the last path segment of a folder, for compact menu display.
-- Falls back to the full path when no segment can be extracted.
function M.getFolderBasename(folder)
    if not folder or folder == "" then
        return nil
    end
    local _, name = util.splitFilePathName(folder)
    if name == "" and folder:sub(-1) == "/" then
        -- trailing slash: split again without it
        local trimmed = folder:gsub("/+$", "")
        _, name = util.splitFilePathName(trimmed)
    end
    if name == "" then
        return folder
    end
    return name
end

-- Returns: folder, error, warning.
-- A configured notebooks folder must already exist. If it does not,
-- the default general_notebooks subfolder is used instead and a warning is returned.
function M.getFolder(assistant, for_write)
    local configured_folder = M.getConfiguredFolder(assistant)
    local warning

    if configured_folder and configured_folder ~= "" then
        if isDirectory(configured_folder) then
            return configured_folder, nil, nil
        end
        warning = T(_("Configured notebooks folder is not accessible: %1"), configured_folder)
    end

    local base_dir = getCurrentBaseDirectory(assistant)
    if not base_dir then
        return nil, _("No base folder is available for notebooks."), warning
    end

    local folder = joinPath(base_dir, GENERAL_NOTEBOOKS_DIR)
    local mode = getMode(folder)
    if mode == "directory" then
        return folder, nil, warning
    end
    if mode ~= nil then
        return nil, T(_("Notebooks path is not a directory: %1"), folder), warning
    end

    if not for_write then
        return folder, nil, warning
    end

    local ok, err = lfs.mkdir(folder)
    if not ok and not isDirectory(folder) then
        return nil, T(_("Could not create notebooks folder: %1"), tostring(err)), warning
    end

    return folder, nil, warning
end

-- Returns: notebooks, error, warning.
function M.list(assistant)
    local notebooks = {}
    local legacy_path = M.getLegacyPath(assistant)
    local legacy_entry

    if legacy_path and isFile(legacy_path) then
        legacy_entry = makeEntry(legacy_path, LEGACY_NOTEBOOK_FILENAME, true)
    end

    local folder, err, warning = M.getFolder(assistant, false)
    if folder and isDirectory(folder) then
        local ok, iter, dir_obj = pcall(lfs.dir, folder)
        if ok and iter then
            for filename in iter, dir_obj do
                if filename ~= "." and filename ~= ".." and filename:lower():sub(-3) == ".md" then
                    local path = joinPath(folder, filename)
                    if path ~= legacy_path and isFile(path) then
                        notebooks[#notebooks + 1] = makeEntry(path, filename, false)
                    end
                end
            end
        elseif not err then
            err = T(_("Could not list notebooks folder: %1"), folder)
        end
    end

    table.sort(notebooks, function(a, b)
        if a.mtime == b.mtime then
            return a.name:lower() < b.name:lower()
        end
        return a.mtime > b.mtime
    end)

    if legacy_entry then
        table.insert(notebooks, 1, legacy_entry)
    end

    return notebooks, err, warning
end

-- Returns: notebook, error, warning.
function M.getActive(assistant)
    local filename = assistant
        and assistant.settings
        and assistant.settings:readSetting(ACTIVE_NOTEBOOK_SETTING)
        or nil

    local folder_err
    local folder_warning
    if filename and validateStoredFilename(filename) then
        local folder
        folder, folder_err, folder_warning = M.getFolder(assistant, false)
        if folder then
            local path = joinPath(folder, filename)
            if isFile(path) then
                return makeEntry(path, filename, false), nil, folder_warning
            end
        end
    end

    -- Do not clear a missing active notebook here. A configured or synced folder
    -- may be temporarily unavailable; falling back must not destroy the sticky choice.
    local legacy_path = M.getLegacyPath(assistant)
    if not legacy_path then
        return nil, folder_err or _("No path is available for the legacy notebook."), folder_warning
    end
    return makeEntry(legacy_path, LEGACY_NOTEBOOK_FILENAME, true), folder_err, folder_warning
end

function M.setActive(assistant, notebook)
    if not assistant or not assistant.settings then
        return nil, _("Assistant settings are not available.")
    end
    if type(notebook) ~= "table" then
        return nil, _("Invalid notebook entry.")
    end

    if notebook.legacy then
        assistant.settings:delSetting(ACTIVE_NOTEBOOK_SETTING)
        assistant.updated = true
        return true
    end

    if not validateStoredFilename(notebook.filename) then
        return nil, _("Invalid notebook filename.")
    end

    assistant.settings:saveSetting(ACTIVE_NOTEBOOK_SETTING, notebook.filename)
    assistant.updated = true
    return true
end

local function isReservedFilenameStem(stem)
    local upper = stem:upper()
    return upper == "CON"
        or upper == "PRN"
        or upper == "AUX"
        or upper == "NUL"
        or upper:match("^COM[1-9]$") ~= nil
        or upper:match("^LPT[1-9]$") ~= nil
end

-- Returns a normalized Markdown filename or nil plus an error.
function M.normalizeName(name)
    if type(name) ~= "string" then
        return nil, _("Notebook name must be text.")
    end

    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or name == "." or name == ".." then
        return nil, _("Notebook name cannot be empty.")
    end
    if name:find("[/\\]") then
        return nil, _("Notebook name cannot contain path separators.")
    end
    if name:find("..", 1, true) then
        return nil, _("Notebook name cannot contain '..'.")
    end
    if name:find('[<>:"|%?%*]') or name:find("[%z\1-\31]") then
        return nil, _("Notebook name contains characters that are not supported by the filesystem.")
    end
    if name:match("[%.%s]$") and name:lower():sub(-3) ~= ".md" then
        return nil, _("Notebook name cannot end with a space or dot.")
    end

    if name:lower():sub(-3) == ".md" then
        name = name:sub(1, -4) .. ".md"
    else
        name = name .. ".md"
    end

    local stem = name:sub(1, -4)
    if stem == "" then
        return nil, _("Notebook name cannot be empty.")
    end

    -- FAT/Windows reserved device names remain reserved even when followed
    -- by another extension, e.g. CON.txt or COM1.notes.
    local device_name = stem:match("^([^%.]+)") or stem
    if isReservedFilenameStem(device_name) then
        return nil, _("Notebook name is reserved by the filesystem.")
    end

    return name
end

-- Returns: notebook, error, warning.
function M.create(assistant, name)
    local filename, name_err = M.normalizeName(name)
    if not filename then
        return nil, name_err, nil
    end

    local folder, folder_err, warning = M.getFolder(assistant, true)
    if not folder then
        return nil, folder_err, warning
    end

    local path = joinPath(folder, filename)
    local mode = getMode(path)
    if mode and mode ~= "file" then
        return nil, T(_("Notebook path is not a file: %1"), path), warning
    end

    if not mode then
        local file, open_err = io.open(path, "a")
        if not file then
            return nil, T(_("Could not create notebook: %1"), tostring(open_err)), warning
        end
        file:close()
    end

    local notebook = makeEntry(path, filename, false)
    local ok, setting_err = M.setActive(assistant, notebook)
    if not ok then
        return nil, setting_err, warning
    end

    return notebook, nil, warning
end


local function showMessage(text, is_warning)
    if not text or text == "" then
        return
    end
    UIManager:show(InfoMessage:new{
        icon = is_warning and "notice-warning" or nil,
        text = text,
        timeout = 5,
    })
end

function M.saveToNotebookFile(assistant, log_entry)
    local success, saved_path, save_err, used_fallback = pcall(function()
        local notebookfile = assistant.ui.bookinfo:getNotebookFile(assistant.ui.doc_settings)
        local default_folder = assistant:confGetFeature("default_folder_for_logs")
        if assistant.ui.doc_settings then
            if default_folder and default_folder ~= "" then
                if not notebookfile:find("^" .. default_folder:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")) then
                    if not util.pathExists(default_folder) then
                        UIManager:show(InfoMessage:new{
                            icon = "notice-warning",
                            text = ASUtils.bold_format(
                                T(_("<b>Cannot access default folder for logs: %1</b>\nUsing original location."), default_folder)
                            ),
                            timeout = 5,
                        })
                    else
                        local original_filename = notebookfile:match("([^/\\]+)$")
                        if original_filename then
                            original_filename = original_filename:gsub("%.[^.]*$", ".md")
                        else
                            local doc_path = assistant.ui.document.file
                            if doc_path then
                                local doc_filename = doc_path:match("([^/\\]+)$")
                                if doc_filename then
                                    original_filename = doc_filename..".md"
                                else
                                    original_filename = "notebook.md"
                                end
                            else
                                original_filename = "notebook.md"
                            end
                        end
                        local new_notebookfile = default_folder .. "/" .. original_filename

                        assistant.ui.doc_settings:saveSetting("notebook_file", new_notebookfile)

                        notebookfile = new_notebookfile
                    end
                end
            end

            if notebookfile and not notebookfile:find("%.md$") then
                notebookfile = notebookfile:gsub("%.[^.]*$", ".md")
                if not notebookfile:find("%.md$") then
                    notebookfile = notebookfile .. ".md"
                end
                assistant.ui.doc_settings:saveSetting("notebook_file", notebookfile)
            end
        else
            local general_warning
            notebookfile, general_warning = M.getGeneralNotebookFilePath(assistant)
            if general_warning then
                logger.warn("Assistant: General notebook warning:", general_warning)
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = general_warning,
                    timeout = 5,
                })
            end
        end

        if not notebookfile then
            return nil, _("Notebook path is unavailable."), false
        end

        local file, open_err = io.open(notebookfile, "a")
        local fallback_used = false

        -- Multi-notebook is optional. If the selected destination cannot be
        -- opened for append, fall back to the legacy general_notebook.md so the
        -- conversation is not lost.
        if not file and not assistant.ui.doc_settings and M.isEnabled(assistant) then
            local failed_path = notebookfile
            local legacy_path = M.getLegacyPath(assistant)

            if legacy_path and legacy_path ~= failed_path then
                logger.warn(
                    "Assistant: Could not open general notebook:",
                    failed_path,
                    open_err,
                    "- falling back to:",
                    legacy_path
                )

                notebookfile = legacy_path
                file, open_err = io.open(notebookfile, "a")
                fallback_used = file ~= nil
            end
        end

        if not file then
            logger.warn("Assistant: Could not open notebook file:", notebookfile, open_err)
            return nil, open_err or _("Could not open notebook file."), false
        end

        local write_ok, write_err = file:write(log_entry)
        local close_ok, close_err = file:close()
        if not write_ok then
            logger.warn("Assistant: Could not write notebook file:", notebookfile, write_err)
            return nil, write_err or _("Could not write notebook file."), false
        end
        if close_ok == nil then
            logger.warn("Assistant: Could not close notebook file:", notebookfile, close_err)
            return nil, close_err or _("Could not close notebook file."), false
        end

        if fallback_used then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(
                    _("Could not save to the selected notebook.\nSaved to: %1"),
                    "general_notebook"
                ),
                timeout = 5,
            })
        end

        return notebookfile, nil, fallback_used
    end)

    if not success then
        logger.warn("Assistant: Error during notebook save:", saved_path)
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Notebook save failed. Continuing..."),
            timeout = 3,
        })
        return nil, saved_path, false
    end

    -- Preserve book-mode behavior, but make general-mode failures visible.
    if not saved_path and not assistant.ui.doc_settings then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Notebook save failed. Continuing..."),
            timeout = 3,
        })
    end

    return saved_path, save_err, used_fallback == true
end

function M.getActiveDisplayName(assistant, max_chars)
    local notebook = M.getActive(assistant)
    local name = notebook and notebook.name or displayName(LEGACY_NOTEBOOK_FILENAME)

    if max_chars and max_chars > 1 then
        local chars = util.splitToChars(name)
        if #chars > max_chars then
            return table.concat(chars, "", 1, max_chars - 1) .. "…"
        end
    end

    return name
end

function M.showCreateDialog(assistant, options)
    options = options or {}

    local dialog
    dialog = InputDialog:new{
        title = _("New notebook"),
        input_hint = _("Notebook name"),
        description = _("Create a notebook."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Create"),
                    is_enter_default = true,
                    callback = function()
                        local notebook, err, warning = M.create(
                            assistant,
                            dialog:getInputText()
                        )

                        if warning then
                            showMessage(warning, true)
                        end

                        if not notebook then
                            showMessage(err or _("Could not create notebook."), true)
                            return
                        end

                        UIManager:close(dialog)
                        if options.parent then
                            UIManager:close(options.parent)
                        end
                        if options.on_select then
                            options.on_select(notebook)
                        end
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

function M.showPicker(assistant, options)
    options = options or {}

    local notebooks, err, warning = M.list(assistant)
    if warning then
        showMessage(warning, true)
    end
    if err then
        showMessage(err, true)
    end

    local active = M.getActive(assistant)
    local menu
    local items = {}
    local active_index

    for _, notebook in ipairs(notebooks) do
        local is_active = active
            and notebook.path
            and active.path == notebook.path

        if is_active then
            active_index = #items + 1
        end

        items[#items + 1] = {
            text = (is_active and "✓ " or "") .. notebook.name,
            callback = function()
                local ok, set_err = M.setActive(assistant, notebook)
                if not ok then
                    showMessage(set_err or _("Could not select notebook."), true)
                    return
                end

                UIManager:close(menu)
                if options.on_select then
                    options.on_select(notebook)
                end
            end,
        }
    end

    if #items == 0 then
        items[#items + 1] = {
            text = _("No notebooks yet"),
            enabled = false,
        }
    end

    items[#items + 1] = {
        text = _("New notebook…"),
        callback = function()
            M.showCreateDialog(assistant, {
                parent = menu,
                on_select = options.on_select,
            })
        end,
    }

    if active_index then
        items.current = active_index
    end

    menu = Menu:new{
        title = options.title or _("Notebooks"),
        subtitle = T(
            _("Active: %1"),
            M.getActiveDisplayName(assistant, 24)
        ),
        item_table = items,
    }

    UIManager:show(menu)
    return menu
end

-- Opens KOReader's PathChooser to let the user pick the notebooks folder,
-- storing the chosen path as a setting.
function M.showFolderPicker(assistant, options)
    options = options or {}

    local PathChooser = require("ui/widget/pathchooser")
    local current = M.getConfiguredFolder(assistant)
    local start_path = (current and current ~= "" and current)
        or getCurrentBaseDirectory(assistant)

    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        show_files = false,
        path = start_path,
        onConfirm = function(dir_path)
            assistant.settings:saveSetting(FOLDER_SETTING, dir_path)
            assistant.updated = true
            if options.on_select then
                options.on_select(dir_path)
            end
        end,
    }
    UIManager:show(path_chooser)
    return path_chooser
end

return M
