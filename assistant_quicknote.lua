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
local assistant_utils = require("assistant_utils")

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
    self:saveNote(note_text, nil)
  end, nil)
end

function QuickNote:saveNote(note_text, highlighted_text)
  if not note_text then
    self:createNoteInputDialog(function(input_note)
      self:saveNote(input_note, highlighted_text)
    end, highlighted_text)
    return
  end

  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local highlighted_text_lbl = _("Highlighted text:")
  local user_lbl = _("User:")
  local quick_note_lbl = _("Quick Note")

  local page_info = assistant_utils.getPageInfo(self.assistant.ui)
  local processed_note = note_text:gsub("\n", "\n\n")

  local processed_highlighted = ""
  if highlighted_text and highlighted_text ~= "" then
    processed_highlighted = "> " .. highlighted_text:gsub("\n", "\n\n> ")
  end
  local log_entry
  if processed_highlighted ~= "" and processed_note ~= "" then
    log_entry = string.format("# [%s]%s\n## %s\n\n__%s__ \n%s\n\n### ⮞ %s \n\n%s\n\n", timestamp, page_info, quick_note_lbl, highlighted_text_lbl, processed_highlighted, user_lbl, processed_note)
  elseif processed_note == "" then
    log_entry = string.format("# [%s]%s\n## %s\n\n__%s__ \n%s\n\n", timestamp, page_info, quick_note_lbl, highlighted_text_lbl, processed_highlighted)
  else
    log_entry = string.format("# [%s]\n## %s\n\n### ⮞ %s \n\n%s\n\n", timestamp, quick_note_lbl, user_lbl, processed_note)
  end

  assistant_utils.saveToNotebookFile(self.assistant, log_entry)

  UIManager:show(InfoMessage:new{
    text = _("Quick note saved successfully"),
    timeout = 2
  })
end

return QuickNote
