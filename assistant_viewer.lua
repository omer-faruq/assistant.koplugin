--[[--
Displays some text in a scrollable view.

@usage
    local chatgptviewer = ChatGPTViewer:new{
        title = _("I can scroll!"),
        text = _("I'll need to be longer than this example to scroll."),
    }
    UIManager:show(chatgptviewer)
]]
local BD = require("ui/bidi")
local DocUtils = require("assistant_doc_utils")
local TextUtils = require("assistant_text_utils")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local logger = require("logger")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local koutil = require("util")
local _ = require("assistant_gettext")
local InfoMessage = require("ui/widget/infomessage")
local Screen = Device.screen
local MD = require("assistant_mdparser")
local Prompts = require("assistant_prompts")
local ViewerCSS = require("assistant_css")
local Notebook = require("assistant_notebook")
local CheckButton = require("ui/widget/checkbutton")

-- Inject scroll page method for ScrollHtmlWidget
ScrollHtmlWidget.scrollToPage = function(self, page_num)
  if page_num > self.htmlbox_widget.page_count then
    page_num = self.htmlbox_widget.page_count 
  end
  self.htmlbox_widget:setPageNumber(page_num)
  self:_updateScrollBar()
  self.htmlbox_widget:freeBb()
  self.htmlbox_widget:_render()
  if self.dialog.movable and self.dialog.movable.alpha then
      self.dialog.movable.alpha = nil
      UIManager:setDirty(self.dialog, function()
          return "partial", self.dialog.movable.dimen
      end)
  else
      UIManager:setDirty(self.dialog, function()
          return "partial", self.dimen
      end)
  end
end

-- Viewer CSS lives in assistant_css.lua (shared with the notebook viewer);
-- _buildCSS() below is a thin wrapper resolving the display switches.

local ChatGPTViewer = InputContainer:extend {
  title = nil,
  text = nil,
  width = nil,
  height = nil,
  buttons_table = nil,

  title_face = nil,               -- use default from TitleBar
  title_multilines = nil,         -- see TitleBar for details
  title_shrink_font_to_fit = nil, -- see TitleBar for details
  text_padding = Size.padding.large,
  text_margin = Size.margin.small,
  button_padding = Size.padding.default,
  -- Bottom row with Close, Find buttons. Also added when no caller's buttons defined.
  add_default_buttons = nil,
  default_hold_callback = nil,   -- on each default button
  find_centered_lines_count = 5, -- line with find results to be not far from the center

  onAskQuestion = nil, -- callback when the Ask Another Question button is pressed
  input_dialog = nil,
  disable_add_note = false, -- when true, do not show the Add Note button
}

-- Global variables
local active_chatgpt_viewer = nil

function ChatGPTViewer:init()
  -- calculate window dimension
  self.align = "center"
  self.region = Geom:new {
    x = 0, y = 0,
    w = Screen:getWidth(),
    h = Screen:getHeight(),
  }
  self.width = self.width or Screen:getWidth() - Screen:scaleBySize(30)
  self.height = self.height or Screen:getHeight() - Screen:scaleBySize(30)

  self._find_next = false
  self._find_next_button = false
  self._old_virtual_line_num = 1

  if Device:hasKeys() then
    self.key_events.Close = { { Device.input.group.Back } }
  end

  if Device:isTouchDevice() then
    local range = Geom:new {
      x = 0, y = 0,
      w = Screen:getWidth(),
      h = Screen:getHeight(),
    }
    self.ges_events = {
      TapClose = {
        GestureRange:new {
          ges = "tap",
          range = range,
        },
      },
      Swipe = {
        GestureRange:new {
          ges = "swipe",
          range = range,
        },
      },
      MultiSwipe = {
        GestureRange:new {
          ges = "multiswipe",
          range = range,
        },
      },
      -- Allow selection of one or more words (see textboxwidget.lua):
      HoldStartText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldPanText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldReleaseText = {
        GestureRange:new {
          ges = "hold_release",
          range = range,
        },
        -- callback function when HoldReleaseText is handled as args
        args = function(text, hold_duration, start_idx, end_idx, to_source_index_func)
          self:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
        end
      },
      -- These will be forwarded to MovableContainer after some checks
      ForwardingTouch = { GestureRange:new { ges = "touch", range = range, }, },
      ForwardingPan = { GestureRange:new { ges = "pan", range = range, }, },
      ForwardingPanRelease = { GestureRange:new { ges = "pan_release", range = range, }, },
    }
  end

  -- If another ChatGPTViewer is open, close it
  if active_chatgpt_viewer and active_chatgpt_viewer ~= self then
    UIManager:close(active_chatgpt_viewer)
  end
  
  active_chatgpt_viewer = self

  local is_multi_general =
      not self.assistant.ui.doc_settings and Notebook.isEnabled(self.assistant)
  local notebook_subtitle = nil
  if is_multi_general then
      if type(self.notebook_path) == "string" and self.notebook_path ~= "" then
          local basename = self.notebook_path:match("([^/\\]+)$") or self.notebook_path
          basename = basename:gsub("%.[mM][dD]$", "")
          notebook_subtitle = basename ~= "" and basename
              or Notebook.getActiveDisplayName(self.assistant, 24)
      else
          notebook_subtitle = Notebook.getActiveDisplayName(self.assistant, 24)
      end
  end
  if notebook_subtitle then
      notebook_subtitle = "✎ " .. notebook_subtitle
  end

  self.titlebar = TitleBar:new {
    width = self.width,
    align = "left",
    with_bottom_line = true,
    title = "Assistant: " .. (self.title or ""),
    subtitle = notebook_subtitle,
    title_face = self.title_face,
    title_multilines = self.title_multilines,
    title_shrink_font_to_fit = self.title_shrink_font_to_fit,
    close_callback = function() self:onClose() end,
    close_hold_callback = function() self:HoldClose() end,
    left_icon = "appbar.menu",
    left_icon_tap_callback = function()
      self:onShowMenu()
    end,
    show_parent = self,
  }

  -- Callback to enable/disable buttons, for at-top/at-bottom feedback
  local prev_at_top = false -- Buttons were created enabled
  local prev_at_bottom = false
  local function button_update(id, enable)
    local button = self.button_table:getButtonById(id)
    if button then
      if enable then
        button:enable()
      else
        button:disable()
      end
      button:refresh()
    end
  end
  self._buttons_scroll_callback = function(low, high)
    if prev_at_top and low > 0 then
      button_update("top", true)
      prev_at_top = false
    elseif not prev_at_top and low <= 0 then
      button_update("top", false)
      prev_at_top = true
    end
    if prev_at_bottom and high < 1 then
      button_update("bottom", true)
      prev_at_bottom = false
    elseif not prev_at_bottom and high >= 1 then
      button_update("bottom", false)
      prev_at_bottom = true
    end
  end

  -- buttons
  local default_buttons = {}
  
  -- Only add Ask Another Question button if showAskQuestion is true
  if self.onAskQuestion then
    table.insert(default_buttons, {
      -- @translators button text, keep it short, like: Ask Another
      text = _("Ask Another Question"),
      id = "ask_another_question",
      callback = function()
        self:askAnotherQuestion()
      end,
    })
  end
  
  -- Add the rest of the default buttons
  table.insert(default_buttons, {
    text = "⇱",
    id = "top",
    callback = function()
      self.scroll_text_w:scrollToRatio(0)
    end,
    hold_callback = self.default_hold_callback,
    allow_hold_when_disabled = true,
  })
  
  table.insert(default_buttons, {
    text = "⇲",
    id = "bottom",
    callback = function()
      self.scroll_text_w:scrollToRatio(1)
    end,
    hold_callback = self.default_hold_callback,
    allow_hold_when_disabled = true,
  })
  
  table.insert(default_buttons, {
    text = _("Close"),
    id = "close",
    callback = function()
      self:onClose()
    end,
    hold_callback = self.default_hold_callback,
  })
  
  local buttons = self.buttons_table or {}
  if self.add_default_buttons or not self.buttons_table then
    table.insert(buttons, default_buttons)
  end
  
  -- Add a copy button to the bottom button row
  local copy_button = {
      text = _("Copy"),
      callback = function()
          if self.text and self.text ~= "" then
              Device.input.setClipboardText(self.text)
              UIManager:show(InfoMessage:new{
                  text = _("Text copied to the clipboard"),
                  timeout = 3,
              })
          end
      end
  }
  
  -- Insert the buttons into the existing buttons, 
  -- to keep close button on the right, insert into the second-to-last position
  table.insert(buttons[#buttons], #(buttons[#buttons]), copy_button)
  
  -- Add a button to add notes
  local function createAddNoteButton(self)
      return {
          text = _("Add Note"),
          callback = function()
              -- Check if ui is available in self
              local ui = self.ui
              if not ui or not ui.highlight then
                  UIManager:show(InfoMessage:new{
                      icon = "notice-warning",
                      text = _("Highlight functionality not available"),
                      timeout = 2
                  })
                  return
              end
              
              if not self.text or self.text == "" then
                  UIManager:show(InfoMessage:new{
                      icon = "notice-warning",
                      text = _("No text to add as note"),
                      timeout = 2
                  })
                  return
              end
              
              -- Get the selected text
              local selected_text = self.highlighted_text or ""
              
              -- Remove the selected text from the full text with multiple strategies
              local note_text = self.text
              
              -- First, try to remove only if the selected text is after "Highlighted text: "
              local highlighted_start, highlighted_end = note_text:find('Highlighted text: "([^"]*)"')
              if highlighted_start then
                  local highlighted_part = note_text:sub(highlighted_start, highlighted_end)
                  local selected_text_in_highlight = highlighted_part:match('"([^"]*)"')
                  
                  if selected_text_in_highlight == selected_text then
                      note_text = note_text:gsub('Highlighted text: "' .. selected_text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. '"', "")
                  end
              end
              
              -- Trim whitespace
              note_text = note_text:gsub("^%s+", ""):gsub("%s+$", "")
                            
              if note_text == "" then
                  UIManager:show(InfoMessage:new{
                      icon = "notice-warning",
                      text = _("No text left to add as note"),
                      timeout = 2
                  })
                  return
              end
              
              local index = ui.highlight:saveHighlight(true)
              local a = ui.annotation.annotations[index]
              a.note = note_text
              ui:handleEvent(Event:new("AnnotationsModified", 
                                      { a, nb_highlights_added = -1, nb_notes_added = 1 }))
              
              UIManager:show(InfoMessage:new{
                  text = _("Note added successfully"),
                  timeout = 2
              })
          end
      }
  end
  
  -- Only add Add Note button if ui context is available and not disabled
  if self.ui and not self.disable_add_note then
      local add_note_button = createAddNoteButton(self)
      -- to keep close button on the right, insert into the second-to-last position
      table.insert(buttons[#buttons], #(buttons[#buttons]), add_note_button)
  end

  -- Only add Save button if auto_save_to_notebook is disabled.
  -- In general multi-notebook mode, let the user choose the destination at
  -- save time; otherwise preserve the existing one-click Save behavior.
  if not self.assistant.settings:readSetting("auto_save_to_notebook", false) then
      local save_button = {
          text = _("Save"),
          callback = function()
              if is_multi_general then
                  Notebook.showPicker(self.assistant, {
                      title = _("Save conversation to"),
                      on_select = function(notebook)
                          -- Explicit user choice wins over any per-book
                          -- path: clear it so the save follows active.
                          self.notebook_path = nil
                          local saved_path, _save_err, used_fallback = self:saveToNotebook()

                          if self.titlebar and self.titlebar.setSubTitle then
                              self.titlebar:setSubTitle(
                                  "✎ " .. Notebook.getActiveDisplayName(self.assistant, 24)
                              )
                          end

                          if saved_path and not used_fallback then
                              local saved_name = saved_path:match("([^/\\]+)$") or saved_path
                              saved_name = saved_name:gsub("%.md$", "")
                              UIManager:show(InfoMessage:new{
                                  text = T(_("Saved to: %1"), saved_name),
                                  timeout = 2,
                              })
                          end
                      end,
                  })
                  return
              end

              self:saveToNotebook()
              UIManager:show(InfoMessage:new{
                  text = _("Conversation is saved to AI Notes"),
                  timeout = 2
              })
          end
      }
      -- to keep close button on the right, insert into the second-to-last position
      table.insert(buttons[#buttons], #(buttons[#buttons]), save_button)
  end

  self.button_table = ButtonTable:new {
    width = self.width - 2 * self.button_padding,
    buttons = buttons,
    zero_sep = true,
    show_parent = self,
  }

  local textw_height = self.height - self.titlebar:getHeight() - self.button_table:getSize().h

  self.scroll_text_w = self:_buildScrollWidget(textw_height)

  self.textw = FrameContainer:new {
    padding = self.text_padding,
    margin = self.text_margin,
    bordersize = 0,
    self.scroll_text_w
  }

  self.frame = FrameContainer:new {
    radius = Size.radius.window,
    padding = 0,
    margin = 0,
    background = Blitbuffer.COLOR_WHITE,
    VerticalGroup:new {
      self.titlebar,
      CenterContainer:new {
        dimen = Geom:new {
          w = self.width,
          h = self.textw:getSize().h,
        },
        self.textw,
      },
      CenterContainer:new {
        dimen = Geom:new {
          w = self.width,
          h = self.button_table:getSize().h,
        },
        self.button_table,
      }
    }
  }
  self.movable = MovableContainer:new {
    -- We'll handle these events ourselves, and call appropriate
    -- MovableContainer's methods when we didn't process the event
    ignore_events = {
      -- These have effects over the text widget, and may
      -- or may not be processed by it
      "swipe", "hold", "hold_release", "hold_pan",
      -- These do not have direct effect over the text widget,
      -- but may happen while selecting text: we need to check
      -- a few things before forwarding them
      "touch", "pan", "pan_release",
    },
    self.frame,
  }
  self[1] = WidgetContainer:new {
    align = self.align,
    dimen = self.region,
    self.movable,
  }
end

function ChatGPTViewer:saveToNotebook()
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local highlighted_text_lbl = _("Highlighted text:")
  
  local page_info = DocUtils.getPageInfo(self.ui)

  local title_text = (self.title and self.title or self.ui.document and _("Book Analysis") or _("General Conversation")) .. "\n"
  local text_to_log = self.text or ""
    
  if self.highlighted_text then
    local highlighted_pattern = "^__([^⮞]-)__.-(\n?### ⮞)"
    text_to_log = text_to_log:gsub(highlighted_pattern, "%2", 1)
    
    local processed_highlighted = ""
    if self.highlighted_text and self.highlighted_text ~= "" then
      processed_highlighted = "> " .. self.highlighted_text:gsub("\n", "\n\n> ")
    end
    text_to_log = string.format("__%s__ \n%s\n\n%s\n\n", highlighted_text_lbl, processed_highlighted, text_to_log)
  end
  
  -- Remove suggested question link
  text_to_log = text_to_log:gsub("%[(.-)%]%(%#q:.-%)", "%1") 
  
  local log_entry = string.format("---\n**✎ %s**%s\n## %s\n\n%s\n\n", timestamp, page_info, title_text, text_to_log)
  
  return Notebook.saveToNotebookFile(self.assistant, log_entry, self.notebook_path)
end

function ChatGPTViewer:onCloseWidget()
  -- Reset all history and context
  self.text = ""
  self.message_history = nil
  self.highlighted_text = nil
  
  -- Reset the active window
  if active_chatgpt_viewer == self then
    active_chatgpt_viewer = nil
  end
  
  -- Call InputContainer's default onCloseWidget method
  if InputContainer.onCloseWidget then
    InputContainer.onCloseWidget(self)
  end

  UIManager:setDirty(self, function()
    return "partial", self.frame.dimen
  end)
end

function ChatGPTViewer:askAnotherQuestion(simple_mode)
  -- Prevent multiple dialogs
  if self.input_dialog and self.input_dialog.dialog_open then
    return
  end

  -- Initialize default options
  local default_options = {}
  local use_web_search_checkbox -- ref to the web search CheckButton widget
  
  -- Load additional prompts from configuration if available
  local sorted_prompts = Prompts.getSortedPrompts(function (prompt)
    if prompt.visible == false then
      return false
    end
    -- Exclude stub prompts (dictionary) button in follow up questions
    -- (prompts defined only in configuration.lua may have no `order`)
    if (prompt.order or 1000) < 0 then
      return false
    end
    return true
  end, Prompts.isWebSearchEnabled(self.assistant.settings)) or {}

  local user_prompts = self.assistant.config:getFeature("prompts")
  local merged_prompts = Prompts.getMergedPrompts(user_prompts) or {}
    
  -- Add buttons in sorted order
  for _, tab in ipairs(sorted_prompts) do
    table.insert(default_options, {
      text = tab.text,
      callback = function(dialog)
        if not dialog then return end
        local input_text = dialog:getInputText()
        UIManager:close(dialog)

        -- Special case for Quick Note - save directly instead of asking AI
        if tab.idx == "quick_note" then
          if not self.assistant.quicknote then
            local QuickNote = require("assistant_quicknote")
            self.assistant.quicknote = QuickNote:new(self.assistant)
          end
          self.assistant.quicknote:saveNote(input_text, self.highlighted_text)
          return
        end

        local prompt_config = merged_prompts[tab.idx]
        prompt_config.user_input = input_text
        if self.onAskQuestion then
          self.onAskQuestion(self, prompt_config)
        end
      end
    })
  end
  -- Prepare buttons
  local first_row = {
    {
      text = _("Cancel"),
      id = "close",
      callback = function()
        if self.input_dialog then
          UIManager:close(self.input_dialog)
          self.input_dialog = nil
        end
      end
    },
    {
      text = _("Ask"),
      is_enter_default = true,
      callback = function()
        local question = self.input_dialog:getInputText()
        if not question or question == "" then
          UIManager:show(InfoMessage:new{
            text = _("Enter a question before proceeding."),
            timeout = 3
          })
          return
        end
        if self.assistant.settings:readSetting("auto_copy_asked_question", true) and Device:hasClipboard() then
          Device.input.setClipboardText(question)
        end
        local use_websearch = use_web_search_checkbox and use_web_search_checkbox.checked or false
        UIManager:close(self.input_dialog)
        self.input_dialog = nil
        
        if self.onAskQuestion then
          self.onAskQuestion(self, question, use_websearch) -- question is string (user input)
        end
      end
    }
  }

  local button_rows = {}
  table.insert(button_rows, first_row)
   -- Only add custom buttons if there's highlighted text
  if self.highlighted_text and self.highlighted_text ~= "" and not simple_mode then 
    local prompt_buttons = {}

    -- Add custom prompt buttons
    for _, option in ipairs(default_options) do
      table.insert(prompt_buttons, {
        text = option.text,
        callback = function()
          local dialog = self.input_dialog
          local user_question = dialog:getInputText()
          if user_question ~= "" and self.assistant.settings:readSetting("auto_copy_asked_question", true) and Device:hasClipboard() then
            Device.input.setClipboardText(user_question)
          end
          UIManager:close(dialog)
          self.input_dialog = nil
          option.callback(dialog)
        end
      })
    end

    -- Split buttons into rows (3 buttons per row)
    for i = 1, #prompt_buttons, 3 do
      local row = {}
      for j = 0, 2 do
        if prompt_buttons[i + j] then
          table.insert(row, prompt_buttons[i + j])
        end
      end
      table.insert(button_rows, row)
    end
  end

  -- Create input dialog
  self.input_dialog = InputDialog:new {
    title = _("Ask Another Question"),
    input = "",
    input_hint = _("Type your question here"),
    input_type = "text",
    input_height = 6,
    allow_newline = true,
    input_multiline = true,
    text_height = math.floor( 10 * Screen:scaleBySize(20) ), -- about 10 lines of text
    width = Screen:getWidth() * 0.8,
    height = Screen:getHeight() * 0.4,
    buttons = button_rows,
  }

  -- Add web search checkbox below the input field
  local web_search_available = self.assistant.settings:readSetting("use_websearch", "none") ~= "none"
  local saved_web_search = self.assistant.settings:readSetting("ask_use_websearch", false)
  use_web_search_checkbox = CheckButton:new{
    face = Font:getFace("xx_smallinfofont"),
    text = _("Use web search") .. " 🌐",
    parent = self.input_dialog,
    checked = web_search_available and saved_web_search,
    enabled = web_search_available,
    callback = function()
      self.assistant.settings:saveSetting("ask_use_websearch", use_web_search_checkbox.checked)
      self.assistant.updated = true
    end,
  }
  local vgroup = self.input_dialog.dialog_frame[1]
  table.insert(vgroup, 2, HorizontalGroup:new{
    HorizontalSpan:new{ width = Size.padding.large },
    use_web_search_checkbox,
  })

  -- add close button (top right cross) to input dialog
  self.input_dialog.title_bar.close_callback = function()
    if self.input_dialog then
      UIManager:close(self.input_dialog)
      self.input_dialog = nil
    end
  end
  self.input_dialog.title_bar:init()

  -- Show the dialog
  UIManager:show(self.input_dialog)
end

-- close all active dialog back to the reading UI
function ChatGPTViewer:HoldClose()
  self:onClose()
  if self.assistant.ui.dictionary.dict_window then
    self.assistant.ui.dictionary.dict_window:onClose()
  end
  self.assistant.ui.highlight:onClose()
end

function ChatGPTViewer:onShow()
  UIManager:setDirty(self, function()
    return "partial", self.frame.dimen
  end)
  return true
end

function ChatGPTViewer:onTapClose(arg, ges_ev)
  if self.button_table then
    for _, button_row in ipairs(self.button_table.buttons) do
      for _, button in ipairs(button_row) do
        if button.id == "close" and button.dimen then
          if ges_ev.pos:intersectWith(button.dimen) then
            self:onClose()
            return true
          end
        end
      end
    end
  end
  
  if ges_ev.pos:notIntersectWith(self.frame.dimen) then
    self:onClose()
    return true
  end
  
  return false
end

function ChatGPTViewer:onClose()
  -- Export chat log if enabled
  if self.assistant.settings:readSetting("auto_save_to_notebook", false) then
    self:saveToNotebook()
  end
  
  UIManager:close(self)
  if self.close_callback then self.close_callback() end

  -- clear the text selection when plugin is called without a highlight or dict dialog
  if self.assistant.ui.highlight then
    if not (self.assistant.ui.highlight.highlight_dialog or self.assistant.ui.dictionary.dict_window) then
      self.assistant.ui.highlight:clear()
    end
  end

  return true
end

function ChatGPTViewer:onMultiSwipe(arg, ges_ev)
  -- For consistency with other fullscreen widgets where swipe south can't be
  -- used to close and where we then allow any multiswipe to close, allow any
  -- multiswipe to close this widget too.
  self:onClose()
  return true
end

function ChatGPTViewer:onSwipe(arg, ges)
  if ges.pos:intersectWith(self.textw.dimen) then
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" then
      self.scroll_text_w:scrollText(1)
      return true
    elseif direction == "east" then
      self.scroll_text_w:scrollText(-1)
      return true
    else
      -- trigger a full-screen HQ flashing refresh
      UIManager:setDirty(nil, "full")
      -- a long diagonal swipe may also be used for taking a screenshot,
      -- so let it propagate
      return false
    end
  end
  -- Let our MovableContainer handle swipe outside of text
  return self.movable:onMovableSwipe(arg, ges)
end

-- The following handlers are similar to the ones in DictQuickLookup:
-- we just forward to our MoveableContainer the events that our
-- TextBoxWidget has not handled with text selection.
function ChatGPTViewer:onHoldStartText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  return self.movable:onMovableHold(_, ges)
end

function ChatGPTViewer:onHoldPanText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  -- We only forward it if we did forward the Touch
  if self.movable._touch_pre_pan_was_inside then
    return self.movable:onMovableHoldPan(arg, ges)
  end
end

function ChatGPTViewer:onHoldReleaseText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  return self.movable:onMovableHoldRelease(_, ges)
end

-- These 3 event processors are just used to forward these events
-- to our MovableContainer, under certain conditions, to avoid
-- unwanted moves of the window while we are selecting text in
-- the definition widget.
function ChatGPTViewer:onForwardingTouch(arg, ges)
  -- This Touch may be used as the Hold we don't get (for example,
  -- when we start our Hold on the bottom buttons)
  if not ges.pos:intersectWith(self.textw.dimen) then
    return self.movable:onMovableTouch(arg, ges)
  else
    -- Ensure this is unset, so we can use it to not forward HoldPan
    self.movable._touch_pre_pan_was_inside = false
  end
end

function ChatGPTViewer:onForwardingPan(arg, ges)
  -- We only forward it if we did forward the Touch or are currently moving
  if self.movable._touch_pre_pan_was_inside or self.movable._moving then
    return self.movable:onMovablePan(arg, ges)
  end
end

function ChatGPTViewer:onForwardingPanRelease(arg, ges)
  -- We can forward onMovablePanRelease() does enough checks
  return self.movable:onMovablePanRelease(arg, ges)
end

function ChatGPTViewer:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
  if self.text_selection_callback then
    self.text_selection_callback(text, hold_duration, start_idx, end_idx, to_source_index_func)
    return
  end
  if Device:hasClipboard() then
    -- translator.copyToClipboard(text)
    UIManager:show(Notification:new {
      text = start_idx == end_idx and _("Word copied to clipboard.")
          or _("Selection copied to clipboard."),
    })
  end
end

function ChatGPTViewer:trimMessageHistory()
  if not self.message_history then return end

  --- TODO: context should be compressed, not trimmed
  --- 
  return
end

function ChatGPTViewer:html_link_tapped_callback(link)
  local SUGGESTION_PREFIX = "#q:"
  if link.uri and koutil.stringStartsWith(link.uri, SUGGESTION_PREFIX) then
    self:askAnotherQuestion(true) -- simple_mode
    local question = koutil.urlDecode(link.uri:sub(4)) or ""
    self.input_dialog:setInputText(question, nil, false)
  end
end

function ChatGPTViewer:_buildCSS()
  local rtl = self.assistant.settings:readSetting("response_is_rtl")
           or self.assistant.ui_language_is_rtl
  local justified = self.assistant.settings:readSetting("response_justified", false)
  return ViewerCSS.build({ rtl = rtl, justified = justified })
end

-- Strip the stored ```reasoning fence (with or without the dialog's title
-- label). Raw <think> leftovers are handled separately by strip_think_tags.
local function strip_reasoning_fence(text)
  text = text:gsub('<div class="assistant%-label[^"]*">[^\n]*</div>%s*```reasoning%s*[%s%S]-%s*```%s*%-%-%-%s*', "")
  return text:gsub("```reasoning%s*[%s%S]-%s*```%s*", "")
end

function ChatGPTViewer:_renderMarkdown()
  local source = self.text
  if type(source) == "string" then
    local show = self.assistant.settings:readSetting("show_reasoning", false)
    if not show then
      source = strip_reasoning_fence(source)
    end
    source = TextUtils.strip_think_tags(source, nil, show)
  end
  local html_body, err = MD(source)
  if err then
    logger.warn("ChatGPTViewer: could not generate HTML", err)
    -- Fallback to plain text if HTML generation fails
    html_body = self.text or "Missing text."
  else
    -- Mark #q: links as suggestion rows (tappable blocks), gated on
    -- the follow-up switch; plain links stay inline.
    if self.assistant.settings:readSetting("auto_prompt_suggest", false) then
      html_body = html_body:gsub('<a href="#q:',
          '<a class="suggestion-link" href="#q:')
    end
    -- puremd wraps raw HTML blocks in <p>: unwrap container labels so the
    -- assistant-label CSS applies without paragraph indent (hoedown no-op).
    html_body = html_body:gsub('<p>%s*<div class="(assistant%-label[^"]*)">(.-)</div>%s*</p>', '<div class="%1">%2</div>')
  end
  return html_body
end

-- Build a ScrollHtmlWidget for the current text.
-- @param outer_height total available height (before subtracting text padding/margin)
function ChatGPTViewer:_buildScrollWidget(outer_height)
  return ScrollHtmlWidget:new{
    html_body = self:_renderMarkdown(),
    css = self:_buildCSS(),
    default_font_size = Screen:scaleBySize(
      self.assistant.settings:readSetting("response_font_size") or 20),
    width = self.width - 2 * self.text_padding - 2 * self.text_margin,
    height = outer_height - 2 * self.text_padding - 2 * self.text_margin,
    dialog = self,
    html_link_tapped_callback = function(link)
      self:html_link_tapped_callback(link)
    end,
  }
end

function ChatGPTViewer:update(new_text)
  -- Check if the new text is substantially different from the current text
  if not self.text or #new_text > #self.text then
    -- Update the text
    self.text = new_text

    -- remenber the last page number
    local last_page_num = self.scroll_text_w.htmlbox_widget.page_count

    -- Recreate the ScrollHtmlWidget with the new text
    self.scroll_text_w = self:_buildScrollWidget(self.textw:getSize().h)

    -- Update the frame container with the new scroll widget
    self.textw:clear()
    self.textw[1] = self.scroll_text_w

    self.scroll_text_w:scrollToPage(1)
    UIManager:scheduleIn(0.25, function ()
      -- a delay scroll makes the scroll bar in correct position
      self.scroll_text_w:scrollToPage(last_page_num)
    end)
  end
end

-- Rebuild the scroll widget in place after a display setting changed,
-- keeping the current page (mirrors the rebuild in update()).
function ChatGPTViewer:_refreshScrollWidget()
  local last_page_num = self.scroll_text_w.htmlbox_widget.page_number or 1
  self.scroll_text_w = self:_buildScrollWidget(self.textw:getSize().h)
  self.textw:clear()
  self.textw[1] = self.scroll_text_w
  self.scroll_text_w:scrollToPage(last_page_num)
  -- One-shot toggles get no continuous refreshes (unlike streaming in
  -- update()), so force a repaint like TextViewer:reinit does.
  UIManager:setDirty("all", "partial", self.frame.dimen)
end

-- Left-icon options menu, mirroring TextViewer:onShowMenu (ButtonDialog
-- with text_func/checked_func closures, no manual setText).
function ChatGPTViewer:onShowMenu()
  local dialog
  local buttons = {
    {{
      text_func = function()
        return T(_("Text Size: %1"), self.assistant.settings:readSetting("response_font_size") or 20)
      end,
      align = "left",
      callback = function()
        UIManager:close(dialog)
        local widget = SpinWidget:new{
          title_text = _("Response Text Font Size"),
          value = self.assistant.settings:readSetting("response_font_size") or 20,
          value_min = 12, value_max = 30, default_value = 20,
          callback = function(spin)
            self.assistant.settings:saveSetting("response_font_size", spin.value)
            self.assistant.updated = true
            self:_refreshScrollWidget()
          end,
        }
        UIManager:show(widget)
      end,
    }},
    {{
      text = _("RTL Layout"),
      checked_func = function()
        return self.assistant.settings:readSetting("response_is_rtl")
          or self.assistant.ui_language_is_rtl
      end,
      align = "left",
      callback = function()
        -- Like upstream toggles: keep the menu open (no close), so the
        -- close repaint cannot race the rebuild repaint and ghost the
        -- tapped item on e-ink. The checkmark refreshes with the dialog.
        local rtl = self.assistant.settings:readSetting("response_is_rtl")
          or self.assistant.ui_language_is_rtl
        self.assistant.settings:saveSetting("response_is_rtl", not rtl)
        self.assistant.updated = true
        self:_refreshScrollWidget()
      end,
    }},
    {{
      text = _("Justify"),
      checked_func = function()
        return self.assistant.settings:readSetting("response_justified", false)
      end,
      align = "left",
      callback = function()
        -- Kept open like upstream (see RTL Layout above).
        local justified = self.assistant.settings:readSetting("response_justified", false)
        self.assistant.settings:saveSetting("response_justified", not justified)
        self.assistant.updated = true
        self:_refreshScrollWidget()
      end,
    }},
    {{
      text = _("Show Reasoning"),
      checked_func = function()
        return self.assistant.settings:readSetting("show_reasoning", false)
      end,
      align = "left",
      callback = function()
        -- Kept open like upstream (see RTL Layout above).
        local show = self.assistant.settings:readSetting("show_reasoning", false)
        self.assistant.settings:saveSetting("show_reasoning", not show)
        self.assistant.updated = true
        self:_refreshScrollWidget()
      end,
    }},
    {{
      text = _("Show Follow-up Questions"),
      checked_func = function()
        return self.assistant.settings:readSetting("auto_prompt_suggest", false)
      end,
      align = "left",
      callback = function()
        -- Kept open like upstream (see RTL Layout above). Takes effect
        -- on rebuild via _renderMarkdown's suggestion-link rewrite.
        local show = self.assistant.settings:readSetting("auto_prompt_suggest", false)
        self.assistant.settings:saveSetting("auto_prompt_suggest", not show)
        self.assistant.updated = true
        self:_refreshScrollWidget()
      end,
    }},
    {{
      text = _("Models"),
      align = "left",
      callback = function()
        UIManager:close(dialog)
        self.assistant:showProviderDialog()
      end,
    }},
  }
  dialog = ButtonDialog:new{
    shrink_unneeded_width = true,
    buttons = buttons,
    anchor = function()
      return self.titlebar.left_button.image.dimen
    end,
  }
  UIManager:show(dialog)
end

return ChatGPTViewer
