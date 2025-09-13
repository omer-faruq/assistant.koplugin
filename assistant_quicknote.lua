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

function QuickNote:createNoteInputDialog(callback, highlighted_text)
  self.input_dialog = InputDialog:new {
    title = _("Take Quick Notes"),
    input = "",
    input_hint = _("Write quick notes here"),
    input_type = "text",
    input_height = 6,
    allow_newline = true,
    input_multiline = true,
    text_height = math.floor(10 * Device.screen:scaleBySize(20)),
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
          if not note_text or (note_text == "" and not (highlighted_text and highlighted_text ~= "")) then
            UIManager:show(InfoMessage:new{
              text = _("Please enter a note before saving."),
              timeout = 3
            })
            return
          end
          callback(note_text)
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
    end,
    dismiss_callback = function()
      if self.input_dialog then
        UIManager:close(self.input_dialog)
        self.input_dialog = nil
      end
    end
  }

  -- Show the dialog
  UIManager:show(self.input_dialog)
end

function QuickNote:show()
  self:createNoteInputDialog(function(note_text)
    self:saveNote(note_text)
  end, nil)
end

function QuickNote:getPageInfo(ui)
  local page_number = nil
  local percentage = 0
  local total_pages = nil
  local chapter_title = nil
  if ui.highlight.selected_text and ui.highlight.selected_text.pos0 then
    if ui.paging then
      page_number = ui.highlight.selected_text.pos0.page
    else
      -- For rolling mode, we could get page number using document:getPageFromXPointer
      page_number = ui.document:getPageFromXPointer(ui.highlight.selected_text.pos0)
    end
    
    total_pages = ui.document.info.number_of_pages
    if page_number and total_pages and total_pages ~= 0 then
      percentage = math.floor((page_number / total_pages) * 100 + 0.5)
    end
    
    if ui.toc and page_number then
      chapter_title = ui.toc:getTocTitleByPage(page_number)
    end
  end

  local page_info = ""
  if page_number and total_pages then
    page_info = string.format(" (Page %s - %s%%)", page_number, percentage)
  elseif page_number then
    page_info = string.format(" (Page %s)", page_number)
  end

  if chapter_title then
    page_info = page_info .. " - " .. chapter_title
  end

  return page_info
end

function QuickNote:saveToNotebookFile(log_entry)
  local success, err = pcall(function()
    local notebookfile = self.assistant.ui.bookinfo:getNotebookFile(self.assistant.ui.doc_settings)
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

    if notebookfile and not notebookfile:find("%.md$") then
      notebookfile = notebookfile:gsub("%.[^.]*$", ".md")
      if not notebookfile:find("%.md$") then
        notebookfile = notebookfile .. ".md"
      end
      self.assistant.ui.doc_settings:saveSetting("notebook_file", notebookfile)
    end

    if notebookfile then
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
    logger.warn("Assistant: Error during notebook save:", err)
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Notebook save failed. Continuing..."),
      timeout = 3,
    })
  end
end

function QuickNote:saveNote(note_text, highlighted_text)
  if not note_text then
    self:createNoteInputDialog(function(input_note)
      self:saveNote(input_note, highlighted_text)
    end, highlighted_text)
    return
  end

  local timestamp = os.date("%Y-%m-%d %H:%M:%S")

  local page_info = self:getPageInfo(self.assistant.ui)
  local processed_note = note_text:gsub("\n", "\n\n")

  local processed_highlighted = ""
  if highlighted_text and highlighted_text ~= "" then
    processed_highlighted = "> " .. highlighted_text:gsub("\n", "\n\n> ")
  end
  local log_entry
  if processed_highlighted ~= "" and processed_note ~= "" then
    log_entry = string.format("# [%s]%s\n## Quick Note\n\n__Highlighted text:__ \n%s\n\n### ⮞ User: \n\n%s\n\n", timestamp, page_info, processed_highlighted, processed_note)
  elseif processed_note == "" then
    log_entry = string.format("# [%s]%s\n## Quick Note\n\n__Highlighted text:__ \n%s\n\n", timestamp, page_info, processed_highlighted)
  else
    log_entry = string.format("# [%s]\n## Quick Note\n\n### ⮞ User: \n\n%s\n\n", timestamp, processed_note)
  end

  self:saveToNotebookFile(log_entry)

  UIManager:show(InfoMessage:new{
    text = _("Quick note saved successfully"),
    timeout = 2
  })
end

return QuickNote
