-- assistant_quicknote.lua
-- Module for quick notes functionality

local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local T = require("ffi/util").template
local util = require("util")
local _ = require("assistant_gettext")

local QuickNote = {}

function QuickNote:new(assistant)
  local o = {
    assistant = assistant,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

function QuickNote:show()
  -- Prevent multiple dialogs
  if self.input_dialog and self.input_dialog.dialog_open then
    return
  end

  -- Create input dialog
  self.input_dialog = InputDialog:new {
    title = _("Take Quick Notes"),
    input = "",
    input_hint = _("Write quick notes here"),
    input_type = "text",
    input_height = 6,
    allow_newline = true,
    input_multiline = true,
    text_height = math.floor(10 * Device.screen:scaleBySize(20)), -- about 10 lines of text
    width = Device.screen:getWidth() * 0.8,
    height = Device.screen:getHeight() * 0.4,
    buttons = {{
      {
        text = _("Cancel"),
        id = "cancel",
        callback = function()
          if self.input_dialog then
            UIManager:close(self.input_dialog)
            self.input_dialog = nil
          end
        end
      },
      {
        text = _("Save"),
        is_enter_default = true,
        callback = function()
          local note_text = self.input_dialog:getInputText()
          if not note_text or note_text == "" then
            UIManager:show(InfoMessage:new{
              text = _("Please enter a note before saving."),
              timeout = 3
            })
            return
          end
          self:saveNote(note_text)
          UIManager:close(self.input_dialog)
          self.input_dialog = nil
        end
      }
    }},
    close_callback = function()
      if self.input_dialog then
        UIManager:close(self.input_dialog)
        self.input_dialog = nil
      end
    end
  }

  -- Show the dialog
  UIManager:show(self.input_dialog)
end

function QuickNote:saveNote(note_text)
  local success, err = pcall(function()
    -- Get notebook file path
    local notebookfile = self.assistant.ui.bookinfo:getNotebookFile(self.assistant.ui.doc_settings)

    -- Check if default_folder_for_logs is configured and try to use it
    local default_folder = util.tableGetValue(self.assistant.CONFIGURATION, "features", "default_folder_for_logs")
    if default_folder and default_folder ~= "" then
      if not notebookfile:find("^" .. default_folder:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")) then
        if not util.pathExists(default_folder) then
          UIManager:show(InfoMessage:new{
              icon = "notice-warning",
              text = T(_("Cannot access default folder for logs: %1\nUsing original location."), default_folder),
              timeout = 5,
            })
        else
          local original_filename = notebookfile:match("([^/\\]+)$")
          if original_filename then
            original_filename = original_filename:gsub("%.[^.]*$", ".md")
          else
            local doc_path = self.assistant.ui.document.file
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

          self.assistant.ui.doc_settings:saveSetting("notebook_file", new_notebookfile)

          notebookfile = new_notebookfile
        end
      end
    end

    -- Ensure the notebook file has .md extension
    if notebookfile and not notebookfile:find("%.md$") then
      notebookfile = notebookfile:gsub("%.[^.]*$", ".md")
      if not notebookfile:find("%.md$") then
        notebookfile = notebookfile .. ".md"
      end
      self.assistant.ui.doc_settings:saveSetting("notebook_file", notebookfile)
    end

    if notebookfile then
      -- Get current timestamp
      local timestamp = os.date("%Y-%m-%d %H:%M:%S")

      -- Process note_text to ensure proper line breaks in Markdown
      local processed_note = note_text:gsub("\n", "\n\n")

      -- Prepare log entry with specific structure for quick notes
      local log_entry = string.format("# [%s]\n## Quick Note\n\n### ⮞ User: \n\n%s\n\n", timestamp, processed_note)

      -- Append to notebook file
      local file = io.open(notebookfile, "a")
      if file then
        file:write(log_entry)
        file:close()
      else
        logger.warn("Assistant: Could not open notebook file:", notebookfile)
      end
    end
  end)

  if not success then
    logger.warn("Assistant: Error during quick note save:", err)
    -- Show warning to user but don't crash
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Quick note save failed. Continuing..."),
      timeout = 3,
    })
  else
    UIManager:show(InfoMessage:new{
      text = _("Quick note saved successfully"),
      timeout = 2
    })
  end
end

return QuickNote
