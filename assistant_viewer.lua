--[[--
Displays some text in a scrollable view.

@usage
    local resultviewer = ResultViewer:new{
        title = _("I can scroll!"),
        text = _("I'll need to be longer than this example to scroll."),
    }
    UIManager:show(resultviewer)
]]
local BD = require("ui/bidi")
local DocUtils = require("assistant_doc_utils")
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
local NetUtils = require("assistant_net_utils")
local Prompts = require("assistant_prompts")
local Trapper = require("ui/trapper")
local ViewerCSS = require("assistant_css")
local Notebook = require("assistant_notebook")
local CheckButton = require("ui/widget/checkbutton")

-- Viewer CSS lives in assistant_css.lua (shared with the notebook viewer);
-- _buildCSS() below is a thin wrapper resolving the display switches.

-- Container divs styled by assistant_css.lua, and the puremd wrapper the
-- viewer strips from around them. The class is captured and checked against
-- CONTAINER_CLASSES so one pass handles every container while leaving any
-- other div (e.g. hoedown's footnotes block) wrapped as the parser emitted it.
local CONTAINER_CLASSES = { ["user-bubble"] = true, ["thought-block"] = true }
local UNWRAP_CONTAINERS = '<p>%s*<div class="([^"]+)">(.-)</div>%s*</p>'

-- Builds the Add Note button for a viewer instance. Placed in the action row
-- (before Close, which always stays rightmost).
local function createAddNoteButton(viewer)
    return {
        text = _("Annotate"),
        callback = function()
            -- Check if ui is available in self
            local ui = viewer.ui
            if not ui or not ui.highlight then
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = _("Highlight functionality not available"),
                    timeout = 2
                })
                return
            end

            if not viewer.text or viewer.text == "" then
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = _("No text to annotate"),
                    timeout = 2
                })
                return
            end

            -- Get the selected text
            local selected_text = viewer.highlighted_text or ""

            -- Remove the selected text from the full text with multiple strategies
            local note_text = viewer.text

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
                    text = _("No text left to annotate"),
                    timeout = 2
                })
                return
            end

            local index = ui.highlight:saveHighlight(true)
            local a = index and ui.annotation and ui.annotation.annotations[index]
            if not a then
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = _("No highlight to annotate"),
                    timeout = 2,
                })
                return
            end
            a.note = note_text
            ui:handleEvent(Event:new("AnnotationsModified",
                                    { a, nb_highlights_added = -1, nb_notes_added = 1 }))

            UIManager:show(InfoMessage:new{
                text = _("Annotation added successfully"),
                timeout = 2
            })
        end,
        hold_callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Attaches the answer as a book note to the current highlight"),
            })
        end
    }
end

local ResultViewer = InputContainer:extend {
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
  -- Two default rows (navigation + actions) are appended when set, or when
  -- no caller-supplied buttons table is given.
  add_default_buttons = nil,
  default_hold_callback = nil,   -- on the Close button
  find_centered_lines_count = 5, -- line with find results to be not far from the center

  onSubmit = nil, -- callback(viewer: ResultViewer, input: table) when the user submits a follow-up
  -- function(viewer) -> string, re-assembles the reply from the caller's
  -- history. Required for a display switch to take effect on the turns that
  -- are already on screen: they were assembled with the previous switch state.
  rebuild_text = nil,
  input_dialog = nil,
  closing = nil, -- set in onClose(): blocks a late selection menu
  is_show_addnote = true, -- when true, show the Add Note button
  minimalist = nil, -- minimalist_mode setting: answer text plus a Close button
  extra_buttons = nil, -- list of ButtonTable button specs {text, id, callback, hold_callback}, appended to the action row before Close
}

-- Open viewers, oldest first; the last entry is the topmost one.
--
-- Viewers nest rather than replace each other: asking a follow-up question
-- about text picked inside a result (the selection menu's Dictionary /
-- Wikipedia) opens its own result window on top of the one it was asked
-- from, and closing it drops back into that conversation. A single shared
-- viewer slot would instead make viewers mutually exclusive and destroy the
-- parent conversation on every recursive query.
--
-- Lifecycle: init() pushes, onCloseWidget() pops (UIManager:close dispatches
-- "CloseWidget" for every close path, including a Close that never came
-- through onClose()).
local viewer_stack = {}

-- @param viewer table the viewer to test
-- @return boolean true when no other viewer is open
local function is_only_viewer(viewer)
  return #viewer_stack == 1 and viewer_stack[1] == viewer
end

-- @param viewer table the viewer to look for
-- @return boolean true when viewer is the topmost one
local function is_topmost_viewer(viewer)
  return viewer_stack[#viewer_stack] == viewer
end

function ResultViewer:init()
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

  -- Minimalist mode (Response Settings): the reply itself is the whole UI, so
  -- the result window keeps a single Close button, drops the Question /
  -- Response / Thought labels (built by the dialogs) and hides reasoning and
  -- follow-up questions. Read once here: the button rows are built in init().
  self.minimalist = self.assistant.settings:readSetting("minimalist_mode", false)

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
        -- callback function when HoldReleaseText is handled as args.
        -- The text widget calls it back with the selection it made; for the
        -- answer text that is the HtmlBoxWidget, which only knows the text
        -- and the hold duration (no character indices, unlike TextBoxWidget).
        args = function(text, hold_duration)
          self:handleTextSelection(text, hold_duration)
        end
      },
      -- These will be forwarded to MovableContainer after some checks
      ForwardingTouch = { GestureRange:new { ges = "touch", range = range, }, },
      ForwardingPan = { GestureRange:new { ges = "pan", range = range, }, },
      ForwardingPanRelease = { GestureRange:new { ges = "pan_release", range = range, }, },
    }
  end

  -- Open on top of whatever is already showing (see viewer_stack); a
  -- recursive query must leave its parent conversation intact.
  if not is_topmost_viewer(self) then
    table.insert(viewer_stack, self)
  end

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

  -- Callback to enable/disable buttons, for at-top/at-bottom feedback.
  -- Minimalist mode has no page buttons, so the callback stays unset.
  if not self.minimalist then
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
        button_update("prev_page", true)
        prev_at_top = false
      elseif not prev_at_top and low <= 0 then
        button_update("prev_page", false)
        prev_at_top = true
      end
      if prev_at_bottom and high < 1 then
        button_update("next_page", true)
        prev_at_bottom = false
      elseif not prev_at_bottom and high >= 1 then
        button_update("next_page", false)
        prev_at_bottom = true
      end
    end
  end

  -- Close is the one button every layout keeps; it stays last in the action
  -- row and alone in the minimalist row.
  local function new_close_button()
    return {
      text = _("Close"),
      id = "close",
      callback = function()
        self:onClose()
      end,
      hold_callback = self.default_hold_callback,
    }
  end

  -- Buttons are laid out in two rows:
  --   Navigation/clipboard: Prev page (◁◁), Find, Copy, Next page (▷▷)
  --   Actions (Close rightmost): Ask Another Question?, Annotate?, Save?,
  --                              caller extra_buttons, Close
  -- Minimalist mode drops the navigation row and the two actions that only
  -- add chrome (Ask Another Question, Save). What it keeps are the actions
  -- that act on the answer itself: Annotate, and caller extra_buttons (the
  -- dictionary viewer contributes Vocabulary Builder there).
  local show_ask = not self.minimalist and self.onSubmit ~= nil
  local show_annotate = self.ui and self.is_show_addnote
  local show_save = not self.minimalist
        and not self.assistant.settings:readSetting("auto_save_to_notebook", false)

  local nav_row
  if not self.minimalist then
    nav_row = {
      {
        text = "◁◁",
        id = "prev_page",
        callback = function()
          self.scroll_text_w:scrollText(-1)
        end,
        hold_callback = function()
          self.scroll_text_w:scrollToRatio(0)
        end,
        allow_hold_when_disabled = true,
      },
      {
        text = _("Find"),
        id = "find",
        -- Tap jumps to the next match while a search is active, hold
        -- reopens the dialog to change the search term.
        callback = function()
          if self._find_next then
            self:findCallback()
          else
            self:findDialog()
          end
        end,
        hold_callback = function()
          if self._find_next then
            self:findDialog()
          else
            if self.default_hold_callback then
              self.default_hold_callback()
            end
          end
        end,
      },
      {
        text = _("Copy"),
        callback = function()
          if self.text and self.text ~= "" then
            Device.input.setClipboardText(self.text)
            UIManager:show(InfoMessage:new{
              text = _("Text copied to the clipboard"),
              timeout = 3,
            })
          end
        end,
      },
      {
        text = "▷▷",
        id = "next_page",
        callback = function()
          self.scroll_text_w:scrollText(1)
        end,
        hold_callback = function()
          self.scroll_text_w:scrollToRatio(1)
        end,
        allow_hold_when_disabled = true,
      },
    }
  end

  local action_row = {}

  -- Only add Ask Another Question button if onSubmit is provided
  if show_ask then
    table.insert(action_row, {
      -- @translators button text, keep it short, like: Ask Another
      text = _("Ask Another Question"),
      id = "ask_another_question",
      callback = function()
        self:askAnotherQuestion()
      end,
    })
  end

  -- Only add Annotate button if ui context is available and not disabled
  if show_annotate then
    table.insert(action_row, createAddNoteButton(self))
  end

  -- Only add Save button if auto_save_to_notebook is disabled.
  -- In general multi-notebook mode, let the user choose the destination at
  -- save time; otherwise preserve the existing one-click Save behavior.
  if show_save then
    table.insert(action_row, {
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
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new{
          text = _("Saves the conversation to AI Notes"),
        })
      end
    })
  end

  -- Caller-supplied extra buttons stay in the action row, in caller order,
  -- right before Close. They never go to the navigation row, and they survive
  -- minimalist mode (the dictionary viewer adds Vocabulary Builder there).
  local extra = self.extra_buttons
  if type(extra) == "table" then
    for i = 1, #extra do
      table.insert(action_row, extra[i])
    end
  end

  -- Close is always the last button, so it sits at the right of the action row.
  table.insert(action_row, new_close_button())

  local buttons = self.buttons_table or {}
  if self.add_default_buttons or not self.buttons_table then
    if nav_row then
      table.insert(buttons, nav_row)
    end
    table.insert(buttons, action_row)
  end
  if buttons[#buttons] == nil then
    table.insert(buttons, {})
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

function ResultViewer:saveToNotebook()
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

function ResultViewer:onCloseWidget()
  -- Reset display state; history ownership stays with the entry adapter
  self.text = ""
  self.highlighted_text = nil
  
  -- Pop out of the stack. Normally the top, but a HoldClose unwinding several
  -- viewers removes them one by one, and a viewer may also already be gone.
  for idx = #viewer_stack, 1, -1 do
    if viewer_stack[idx] == self then
      table.remove(viewer_stack, idx)
      break
    end
  end

  -- Call InputContainer's default onCloseWidget method
  if InputContainer.onCloseWidget then
    InputContainer.onCloseWidget(self)
  end

  UIManager:setDirty(self, function()
    return "partial", self.frame.dimen
  end)
end

function ResultViewer:askAnotherQuestion(simple_mode)
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
        if self.onSubmit then
          self.onSubmit(self, prompt_config)
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
        
        if self.onSubmit then
          self.onSubmit(self, question, use_websearch) -- question is string (user input)
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
function ResultViewer:HoldClose()
  -- Every viewer, not just this one: the point of the hold is to get back to
  -- the reading UI from wherever the nested queries have led. onClose() pops
  -- the stack through onCloseWidget, so walk a copy, topmost first.
  local viewers = {}
  for idx = #viewer_stack, 1, -1 do
    viewers[#viewers + 1] = viewer_stack[idx]
  end
  for _, viewer in ipairs(viewers) do
    viewer:onClose()
  end
  -- FileManager registers dictionary but no highlight (no open book), so
  -- both are optional here; every other ui.highlight access guards the same.
  local ui = self.assistant.ui
  if ui and ui.dictionary and ui.dictionary.dict_window then
    ui.dictionary.dict_window:onClose()
  end
  if ui and ui.highlight then
    ui.highlight:onClose()
  end
end

function ResultViewer:onShow()
  UIManager:setDirty(self, function()
    return "partial", self.frame.dimen
  end)
  return true
end

function ResultViewer:onTapClose(arg, ges_ev)
  -- A stacked viewer is draggable, so a parent window can end up exposed under
  -- a child that was moved aside. Tapping that exposed region must not close
  -- the parent while the child is still up. The tap-outside affordance is not
  -- lost: the topmost viewer covers the tap and closes itself.
  if not is_topmost_viewer(self) then
    return false
  end
  -- The Close button is looked up by id: ButtonTable builds its Button widgets
  -- from a fixed field list that does not carry the entry id, so walking
  -- self.button_table.buttons and reading button.id never matches anything.
  local close_button = self.button_table and self.button_table:getButtonById("close")
  if close_button and close_button.dimen and ges_ev.pos:intersectWith(close_button.dimen) then
    self:onClose()
    return true
  end

  if ges_ev.pos:notIntersectWith(self.frame.dimen) then
    self:onClose()
    return true
  end

  -- Dismiss a live selection. Nothing else clears the answer's highlight rects,
  -- so without this the picked text stays darkened for the window's lifetime.
  -- The tap is consumed so it cannot also turn the page.
  if self:_clearTextSelection() then
    return true
  end

  return false
end

-- Drop a live text selection of the answer, if there is one.
-- @return boolean true if a selection was live and has now been cleared
function ResultViewer:_clearTextSelection()
  local scroll_widget = self.scroll_text_w
  if not scroll_widget then return false end
  local htmlbox = scroll_widget.htmlbox_widget
  if not htmlbox then return false end
  -- Either one still set means the highlight is painted (updateHighlight()
  -- nils both when nothing is held).
  if not htmlbox.highlight_text and not htmlbox.highlight_rects then return false end
  if htmlbox:clearHighlight() then
    htmlbox:redrawHighlight()
  end
  return true
end

function ResultViewer:onClose()
  -- Export chat log if enabled
  if self.assistant.settings:readSetting("auto_save_to_notebook", false) then
    self:saveToNotebook()
  end

  -- Keep a late selection gesture from popping a menu over the closing viewer
  self.closing = true

  -- Decided before the close: UIManager:close pops self off the stack, so
  -- afterwards every viewer looks like it is closing alone.
  local was_the_last_viewer = is_only_viewer(self)

  UIManager:close(self)
  if self.close_callback then self.close_callback() end

  -- Clear the text selection when the plugin was called without a highlight or
  -- dict dialog. Not while a parent viewer is still open: it can still issue
  -- queries, and those resolve the page number from the live selection
  -- (assistant_dialog.lua resolve_page, DocUtils.getPageNumber), so clearing
  -- here would silently drop the page context of a conversation that is still
  -- on screen. The last viewer out does clear it, as before.
  if self.assistant.ui.highlight and was_the_last_viewer then
    if not (self.assistant.ui.highlight.highlight_dialog or self.assistant.ui.dictionary.dict_window) then
      self.assistant.ui.highlight:clear()
    end
  end

  return true
end

function ResultViewer:onMultiSwipe(arg, ges_ev)
  -- For consistency with other fullscreen widgets where swipe south can't be
  -- used to close and where we then allow any multiswipe to close, allow any
  -- multiswipe to close this widget too.
  self:onClose()
  return true
end

function ResultViewer:onSwipe(arg, ges)
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
function ResultViewer:onHoldStartText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  return self.movable:onMovableHold(_, ges)
end

function ResultViewer:onHoldPanText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  -- We only forward it if we did forward the Touch
  if self.movable._touch_pre_pan_was_inside then
    return self.movable:onMovableHoldPan(arg, ges)
  end
end

function ResultViewer:onHoldReleaseText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  return self.movable:onMovableHoldRelease(_, ges)
end

-- These 3 event processors are just used to forward these events
-- to our MovableContainer, under certain conditions, to avoid
-- unwanted moves of the window while we are selecting text in
-- the definition widget.
function ResultViewer:onForwardingTouch(arg, ges)
  -- This Touch may be used as the Hold we don't get (for example,
  -- when we start our Hold on the bottom buttons)
  if not ges.pos:intersectWith(self.textw.dimen) then
    return self.movable:onMovableTouch(arg, ges)
  else
    -- Ensure this is unset, so we can use it to not forward HoldPan
    self.movable._touch_pre_pan_was_inside = false
  end
end

function ResultViewer:onForwardingPan(arg, ges)
  -- We only forward it if we did forward the Touch or are currently moving
  if self.movable._touch_pre_pan_was_inside or self.movable._moving then
    return self.movable:onMovablePan(arg, ges)
  end
end

function ResultViewer:onForwardingPanRelease(arg, ges)
  -- We can forward onMovablePanRelease() does enough checks
  return self.movable:onMovablePanRelease(arg, ges)
end

-- Label of a selection-menu prompt, taken from the merged prompt table so it
-- follows the user's own renames (and the web search indicator) instead of
-- repeating the wording kept in assistant_prompts.lua.
-- @param prompt_id string id of the prompt in the merged prompt table
-- @return string text for the menu button
function ResultViewer:_selectionPromptLabel(prompt_id)
  local merged = Prompts.getMergedPrompts(self.assistant.config:getFeature("prompts")) or {}
  local prompt = koutil.tableGetValue(merged, prompt_id)
  return Prompts.getDisplayText(koutil.tableGetValue(prompt, "text") or prompt_id,
    koutil.tableGetValue(prompt, "use_websearch") or false,
    Prompts.isWebSearchEnabled(self.assistant.settings))
end

-- Run a prompt on the selected text, through the same wrapper the highlight
-- dialog buttons use (online check first, then trapped, so the query dialogs
-- can show their progress).
-- @param prompt_id string id of the prompt to run
-- @param selected_text string the text the user selected in the answer
function ResultViewer:_runSelectionPrompt(prompt_id, selected_text)
  NetUtils.runWhenOnlineFast(function()
    Trapper:wrap(function()
      -- The query dialog is created post-provider-load, so it may be missing.
      if not self.assistant.assistant_dialog then
        UIManager:show(InfoMessage:new{
          icon = "notice-warning",
          text = _("Plugin is not configured."),
          timeout = 2,
        })
        return
      end
      self.assistant.assistant_dialog:runPrompt(selected_text, prompt_id)
    end)
  end)
end

-- @param text string the text to copy
function ResultViewer:_copySelectionToClipboard(text)
  if not Device:hasClipboard() then return end
  Device.input.setClipboardText(text)
  UIManager:show(Notification:new { text = _("Copied to clipboard.") })
end

-- Screen position to open the selection menu at: the top-left of the first
-- selection rect. The widget tree of the answer text is
--   viewer.textw -> viewer.scroll_text_w -> horizontal group -> htmlbox_widget
-- and the rects of HtmlBoxWidget:updateHighlight are widget-local (the page
-- is drawn at 0,0), so the widget's own dimen translates them to the screen.
-- Anything missing along that path yields no anchor, and ButtonDialog then
-- centers itself: a wrong placement is worse than no placement.
-- @return table|nil Geom to anchor the menu at, or nil to center it
function ResultViewer:_selectionAnchor()
  local htmlbox = koutil.tableGetValue(self, "scroll_text_w", "htmlbox_widget")
  local rect = koutil.tableGetValue(htmlbox, "highlight_rects", 1)
  local widget_x = koutil.tableGetValue(htmlbox, "dimen", "x")
  local widget_y = koutil.tableGetValue(htmlbox, "dimen", "y")
  if not rect or not widget_x or not widget_y then return nil end
  -- Fresh Geom: MovableContainer:ensureAnchor fills in the missing fields.
  return Geom:new{
    x = widget_x + (rect.x or 0),
    y = widget_y + (rect.y or 0),
  }
end

-- A long press inside the answer selects a word (tap-and-hold) or a span
-- (hold and pan). On release we offer the two lookups a reader reaches for
-- on an unfamiliar term, plus a copy.
-- @param text string the selected text
-- @param hold_duration number seconds the press was held
function ResultViewer:handleTextSelection(text, hold_duration)
  local selected = koutil.trim(text or "")
  if selected == "" then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("No text selected"),
      timeout = 2,
    })
    return
  end
  -- A follow-up input or keyboard is up, or we are on our way out: no menu.
  if self.input_dialog or self.closing then return end

  local dialog
  local buttons = {
    {
      {
        text = _("Dictionary"),
        callback = function()
          UIManager:close(dialog)
          -- assistant_dictdialog requires this module, so it is pulled in on
          -- first use rather than at load time (the top-level require would
          -- close the cycle).
          local showDictionaryDialog = require("assistant_dictdialog")
          NetUtils.runWhenOnlineFast(function()
            Trapper:wrap(function()
              showDictionaryDialog(self.assistant, selected)
            end)
          end)
        end,
      },
      {
        text = self:_selectionPromptLabel("wikipedia"),
        callback = function()
          UIManager:close(dialog)
          self:_runSelectionPrompt("wikipedia", selected)
        end,
      },
    },
    {
      {
        text = _("Copy"),
        callback = function()
          UIManager:close(dialog)
          self:_copySelectionToClipboard(selected)
        end,
      },
      {
        text = _("Cancel"),
        callback = function()
          UIManager:close(dialog)
        end,
      },
    },
  }
  dialog = ButtonDialog:new{
    shrink_unneeded_width = true,
    buttons = buttons,
    anchor = function()
      return self:_selectionAnchor()
    end,
  }
  UIManager:show(dialog)
end

function ResultViewer:html_link_tapped_callback(link)
  local SUGGESTION_PREFIX = "#q:"
  if link.uri and koutil.stringStartsWith(link.uri, SUGGESTION_PREFIX) then
    self:askAnotherQuestion(true) -- simple_mode
    local question = koutil.urlDecode(link.uri:sub(4)) or ""
    self.input_dialog:setInputText(question, nil, false)
  end
end

function ResultViewer:_buildCSS()
  local rtl = self.assistant.settings:readSetting("response_is_rtl")
           or self.assistant.ui_language_is_rtl
  local justified = self.assistant.settings:readSetting("response_justified", false)
  return ViewerCSS.build({ rtl = rtl, justified = justified })
end

function ResultViewer:_renderMarkdown()
  -- The text arrives in display shape: the querier keeps the reasoning fence
  -- only while Reasoning Text is on, and the follow-up switch keeps the
  -- suggestions out of the history. The viewer only renders.
  local html_body, err = MD(self.text)
  if err then
    logger.warn("ResultViewer: could not generate HTML", err)
    -- Fallback to plain text if HTML generation fails
    html_body = self.text or "Missing text."
  else
    -- Mark #q: links as suggestion rows (tappable blocks), gated on
    -- the follow-up switch; plain links stay inline.
    if self.assistant.settings:readSetting("auto_prompt_suggest", false) then
      html_body = html_body:gsub('<a href="#q:',
          '<a class="suggestion-link" href="#q:')
    end
    -- puremd wraps raw HTML blocks in <p>, which would add a paragraph indent
    -- to our styled containers; hoedown leaves them bare, so a no-op there.
    -- Gated on a plain scan: a reply usually carries no container at all, and
    -- plain find costs far less than a pattern match over the whole body.
    if html_body:find('<div class="user-bubble">', 1, true)
        or html_body:find('<div class="thought-block">', 1, true) then
      html_body = html_body:gsub(UNWRAP_CONTAINERS, function(class, inner)
        if CONTAINER_CLASSES[class] then
          return T('<div class="%1">%2</div>', class, inner)
        end
        return nil
      end)
    end
  end
  return html_body
end

-- Build a ScrollHtmlWidget for the current text.
-- @param outer_height total available height (before subtracting text padding/margin)
function ResultViewer:_buildScrollWidget(outer_height)
  return ScrollHtmlWidget:new{
    html_body = self:_renderMarkdown(),
    css = self:_buildCSS(),
    default_font_size = Screen:scaleBySize(
      self.assistant.settings:readSetting("response_font_size") or 20),
    width = self.width - 2 * self.text_padding - 2 * self.text_margin,
    height = outer_height - 2 * self.text_padding - 2 * self.text_margin,
    dialog = self,
    -- Required for HtmlBoxWidget:_render to darken highlight_rects, so both
    -- Find matches and text selections are visible (as TextViewer).
    highlight_text_selection = true,
    -- Enable/disable the prev/next page buttons at start/end (as TextViewer).
    scroll_callback = self._buttons_scroll_callback,
    html_link_tapped_callback = function(link)
      self:html_link_tapped_callback(link)
    end,
  }
end

function ResultViewer:update(new_text)
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

-- Re-assemble the reply from the caller's history, then rebuild the scroll
-- widget. A display switch (Reasoning / Follow-up Questions) shapes the text
-- when the dialogs build it, so flipping one has to rebuild the text as well:
-- re-rendering the stored string would keep the parts the switch just hid.
function ResultViewer:_refreshText()
  if self.rebuild_text then
    self.text = self.rebuild_text(self)
  end
  self:_refreshScrollWidget()
end

-- Rebuild the scroll widget in place after a display setting changed,
-- keeping the current page (mirrors the rebuild in update()).
function ResultViewer:_refreshScrollWidget()
  local last_page_num = self.scroll_text_w.htmlbox_widget.page_number or 1
  self.scroll_text_w = self:_buildScrollWidget(self.textw:getSize().h)
  self.textw:clear()
  self.textw[1] = self.scroll_text_w
  self.scroll_text_w:scrollToPage(last_page_num)
  -- One-shot toggles get no continuous refreshes (unlike streaming in
  -- update()), so force a repaint like TextViewer:reinit does.
  UIManager:setDirty("all", "partial", self.frame.dimen)
end

-- Find in the rendered HTML (TextViewer's HTML path). The main Find button
-- taps into the next match while a search is active; the dialog's
-- "Find first"/"Find next" buttons set _find_next, the direction flag
-- consumed by findInHtml.
function ResultViewer:findDialog()
  local input_dialog
  input_dialog = InputDialog:new{
    title = _("Enter text to search for"),
    input = self.search_value,
    buttons = {
      {
        {
          text = _("Cancel"),
          id = "close",
          callback = function()
            UIManager:close(input_dialog)
          end,
        },
        {
          text = _("Find first"),
          callback = function()
            self._find_next = false
            self:findCallback(input_dialog)
          end,
        },
        {
          text = _("Find next"),
          is_enter_default = true,
          callback = function()
            self._find_next = true
            self:findCallback(input_dialog)
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard(true)
end

function ResultViewer:findCallback(input_dialog)
  if input_dialog then
    self.search_value = input_dialog:getInputText()
    if self.search_value == "" then return end
    UIManager:close(input_dialog)
  elseif not self.search_value or self.search_value == "" then
    return
  end
  self:findInHtml()
  if self._find_next_button ~= self._find_next then
    self._find_next_button = self._find_next
    local button_text = self._find_next and _("Find next") or _("Find")
    local find_button = self.button_table and self.button_table:getButtonById("find")
    if find_button then
      find_button:setText(button_text, find_button.width)
      find_button:refresh()
    end
  end
  if not self._find_next then
    UIManager:show(Notification:new{ text = _("Not found.") })
  end
end

function ResultViewer:findInHtml()
  local box_widget = self.scroll_text_w.htmlbox_widget
  local curr_page = box_widget.page_number
  local found
  if self._find_next then
    if box_widget._match_page_list and box_widget.search_term == self.search_value then
      found = box_widget:findTextNextPage(1)
    else
      found = box_widget:findText(self.search_value)
    end
  else -- find first
    box_widget.page_number = 1
    found = box_widget:findText(self.search_value)
  end
  if found then
    self._find_next = true
    if curr_page ~= box_widget.page_number then
      self.scroll_text_w:_updateScrollBar(true)
    end
  else
    self._find_next = false
    box_widget.page_number = curr_page
    box_widget:clearSearch(true)
  end
end

-- Left-icon options menu, mirroring TextViewer:onShowMenu (ButtonDialog
-- with text_func/checked_func closures, no manual setText).
function ResultViewer:onShowMenu()
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
      -- Minimalist mode never shows reasoning; keep the switch greyed out.
      enabled_func = function()
        return not self.minimalist
      end,
      checked_func = function()
        return self.assistant.settings:readSetting("show_reasoning", false)
      end,
      align = "left",
      callback = function()
        -- Kept open like upstream (see RTL Layout above). Rebuilds the text so
        -- the thinking of the turns already on screen follows the switch too.
        local show = self.assistant.settings:readSetting("show_reasoning", false)
        self.assistant.settings:saveSetting("show_reasoning", not show)
        self.assistant.updated = true
        self:_refreshText()
      end,
    }},
    {{
      text = _("Show Follow-up Questions"),
      -- Minimalist mode never shows follow-up questions (see above).
      enabled_func = function()
        return not self.minimalist
      end,
      checked_func = function()
        return self.assistant.settings:readSetting("auto_prompt_suggest", false)
      end,
      align = "left",
      callback = function()
        -- Kept open like upstream (see RTL Layout above). Rebuilds the text:
        -- the switch decides both the system prompt of the next answer and
        -- whether the follow-up questions of the current one are rendered.
        local show = self.assistant.settings:readSetting("auto_prompt_suggest", false)
        self.assistant.settings:saveSetting("auto_prompt_suggest", not show)
        self.assistant.updated = true
        self:_refreshText()
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

return ResultViewer
