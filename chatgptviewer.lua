--[[--
Displays some text in a scrollable view.

@usage
    local chatgptviewer = ChatGPTViewer:new{
        title = _("I can scroll!"),
        text = _("I'll need to be longer than this example to scroll."),
    }
    UIManager:show(chatgptviewer)
--]]
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton = require("ui/widget/checkbutton")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local logger = require("logger") -- Moved to top
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget") -- Added for formatting constants
local T = require("ffi/util").template
local util = require("util")
local queryChatGPT = require("gpt_query") -- Added require
local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local Screen = Device.screen
-- local logger = require("logger") -- Redundant, already loaded above
local DataStorage = require("datastorage") -- Ensure DataStorage is required at the top level

-- Load configuration locally as it might be needed in helper functions
local plugin_config = nil
-- Directory determination for dofile removed, using require now
-- Try loading configuration using require, fallback to nil
local config_ok_viewer, config_result_viewer = pcall(require, "configuration")
if config_ok_viewer then
    plugin_config = config_result_viewer
else
    if logger then
        local log_msg = config_result_viewer
        if type(log_msg) == "table" then log_msg = "(table data omitted for security)" end
        logger.info("ChatGPTViewer: configuration.lua not found or error loading via require:", log_msg)
    end
    plugin_config = nil -- Ensure it's nil if loading failed
end


-- Define ChatGPTViewer class immediately after requires
local ChatGPTViewer = InputContainer:extend {
-- Removed forward declaration as it's no longer needed here
  title = nil,
  text = nil,
  width = nil,
  height = nil,
  buttons_table = nil,
  -- See TextBoxWidget for details about these options
  -- We default to justified and auto_para_direction to adapt
  -- to any kind of text we are given (book descriptions,
  -- bookmarks' text, translation results...).
  -- When used to display more technical text (HTML, CSS,
  -- application logs...), it's best to reset them to false.
  alignment = "left",
  justified = false, -- Set justified to false for better list alignment
  lang = nil,
  para_direction_rtl = nil,
  auto_para_direction = true,
  alignment_strict = false,

  title_face = nil,               -- use default from TitleBar
  title_multilines = nil,         -- see TitleBar for details
  title_shrink_font_to_fit = nil, -- see TitleBar for details
  text_face = Font:getFace("x_smallinfofont"), -- Keep a default face here
  fgcolor = Blitbuffer.COLOR_BLACK,
  text_padding = Size.padding.large,
  text_margin = Size.margin.small,
  button_padding = Size.padding.default,
  -- Bottom row with Close, Find buttons. Also added when no caller's buttons defined.
  add_default_buttons = nil,
  default_hold_callback = nil,   -- on each default button
  find_centered_lines_count = 5, -- line with find results to be not far from the center

  onAskQuestion = nil,
  input_dialog = nil,
  showAskQuestion = true,
}

-- Global variables
local active_chatgpt_viewer = nil
local is_input_dialog_open = false

-- Helper function for simple Markdown bold formatting
-- Define default text formatting constants if not available
local TEXT_FORMATTING = {
    HEADER = TextBoxWidget.PTF_HEADER or "",
    BOLD_START = TextBoxWidget.PTF_BOLD_START or "",
    BOLD_END = TextBoxWidget.PTF_BOLD_END or "",
    ITALIC_START = TextBoxWidget.PTF_ITALIC_START or "",
    ITALIC_END = TextBoxWidget.PTF_ITALIC_END or "",
}

local function formatMarkdown(text)
    if not text or text == "" then return text end

    -- Replace **bold** and __bold__ with TextBoxWidget bold tags
    local formatted_text = text
    if TEXT_FORMATTING.BOLD_START ~= "" then
        formatted_text = formatted_text:gsub("%*%*([^*]+)%*%*", TEXT_FORMATTING.BOLD_START .. "%1" .. TEXT_FORMATTING.BOLD_END)
        formatted_text = formatted_text:gsub("__([^_]+)__", TEXT_FORMATTING.BOLD_START .. "%1" .. TEXT_FORMATTING.BOLD_END)
    end

    -- Handle *italic* and _italic_
    if TEXT_FORMATTING.ITALIC_START ~= "" then
        formatted_text = formatted_text:gsub("%*([^*_]+)%*", TEXT_FORMATTING.ITALIC_START .. "%1" .. TEXT_FORMATTING.ITALIC_END)
        formatted_text = formatted_text:gsub("_([^_*]+)_", TEXT_FORMATTING.ITALIC_START .. "%1" .. TEXT_FORMATTING.ITALIC_END)
    end

    -- Replace Markdown list markers with bullet points
    formatted_text = formatted_text:gsub("(?m)^([ \t]*)[%*%-%+] ", "%1- ") -- Use hyphen instead of bullet point

    -- Add header if formatting was applied and header tag is available
    if TEXT_FORMATTING.HEADER ~= "" and (
        formatted_text:find(TEXT_FORMATTING.BOLD_START, 1, true) or
        formatted_text:find(TEXT_FORMATTING.ITALIC_START, 1, true)
    ) then
        formatted_text = TEXT_FORMATTING.HEADER .. formatted_text
    end

    return formatted_text
end

function ChatGPTViewer:init(args)
  -- Ensure args is always a table to prevent crashes
  args = args or {}
  if logger then logger.info("ChatGPTViewer:init - Received args:", args) end -- Log received arguments
  -- Initialize base class first using super
  if InputContainer.super and InputContainer.super.init then
      InputContainer.super.init(self, args)
  elseif InputContainer.init then
      -- Fallback to direct init if super.init is not found
      InputContainer.init(self, args)
  end

  -- Properties should already be set on 'self' by the Widget:new mechanism.
  -- We just ensure created_timestamp exists and rebuild text if needed.
  self.created_timestamp = self.created_timestamp or os.time()
  
  -- Rebuild text from history if history is passed but text is not
  if self.message_history and not self.text then
    self.text = self:rebuildTextFromHistory()
  end

  -- Log the state of self after base init
  if logger then
      logger.info("ChatGPTViewer:init - AFTER base init - self.title type:", type(self.title))
      logger.info("ChatGPTViewer:init - AFTER base init - self.message_history type:", type(self.message_history))
      logger.info("ChatGPTViewer:init - AFTER base init - self.is_saved:", self.is_saved)
      logger.info("ChatGPTViewer:init - AFTER base init - self.topic:", self.topic) -- Log topic
  end
  -- Note: self.topic is set by Widget:new if passed in args
  if logger then logger.info("ChatGPTViewer: Entering init function. Logger seems available.") else print("ChatGPTViewer: Entering init function. Logger is NIL!") end
  -- calculate window dimension
  self.align = "center"
  self.region = Geom:new {
    x = 0, y = 0,
    w = Screen:getWidth(),
    h = Screen:getHeight(),
  }
  -- Check if self.text_face was initialized correctly (Moved AFTER self.region is defined)
  if not self.text_face then
    if logger then logger.info("ChatGPTViewer: Inside 'if not self.text_face'. Logger seems available.") else print("ChatGPTViewer: Inside 'if not self.text_face'. Logger is NIL!") end
    if logger then logger.error("ChatGPTViewer: self.text_face is nil at start of init! Falling back.") end
    -- Fallback to a known good face if possible, or handle error
    local FontModule = require("ui/font") -- Ensure Font is required here for fallback
    if FontModule then
        self.text_face = FontModule:getFace("smallfont") -- Example fallback
    else
        if logger then logger.info("ChatGPTViewer: Inside 'else' of FontModule check. Logger seems available.") else print("ChatGPTViewer: Inside 'else' of FontModule check. Logger is NIL!") end
        if logger then logger.error("ChatGPTViewer: Could not load Font module for fallback!") end
        -- Cannot proceed without a valid text_face
        -- return -- Removed return to prevent premature exit (already done?)
    end
  end

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

  local titlebar = TitleBar:new {
    width = self.width,
    align = "left",
    with_bottom_line = true,
    title = "Assistant: " .. (self.title or ""),
    title_face = self.title_face,
    title_multilines = self.title_multilines,
    title_shrink_font_to_fit = self.title_shrink_font_to_fit,
    close_callback = function() self:onClose() end,
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
  if self.showAskQuestion ~= false then
    table.insert(default_buttons, {
      text = _("Ask"), -- Renamed button
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
      self.scroll_text_w:scrollToTop()
    end,
    hold_callback = self.default_hold_callback,
    -- allow_hold_when_disabled = true, -- Removed to prevent interaction when disabled
  })

  table.insert(default_buttons, {
    text = "⇲",
    id = "bottom",
    callback = function()
      self.scroll_text_w:scrollToBottom()
    end,
    hold_callback = self.default_hold_callback,
    -- allow_hold_when_disabled = true, -- Removed to prevent interaction when disabled
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
                  text = _("Text copied to clipboard"),
                  timeout = 3,
              })
          end
      end
  }

  -- Insert the buttons into the existing buttons, with close button on the right
  table.insert(buttons[#buttons], copy_button)

  -- Add a button to add notes
  local function createAddNoteButton(self)
      return {
          text = _("Add Note"),
          callback = function()
              -- Check if ui is available in self
              local ui = self.ui
              if not ui or not ui.highlight then
                  UIManager:show(InfoMessage:new{
                      text = _("Highlight functionality not available"),
                      timeout = 2
                  })
                  return
              end

              if not self.text or self.text == "" then
                  UIManager:show(InfoMessage:new{
                      text = _("No text to add as note"),
                      timeout = 2
                  })
                  return
              end

              -- Find the last non-error assistant message in the history
              local note_text = nil
              if self.message_history and #self.message_history > 0 then
                  for i = #self.message_history, 1, -1 do
                      local msg = self.message_history[i]
                      if msg.role == "assistant" then
                          local content = msg.content or ""
                          local is_error = content:match("^Error:") or content:match("^%a+ API Error")
                          if not is_error then
                              note_text = content -- Found the last valid assistant response
                              break
                          end
                      end
                  end
              end

              if not note_text or note_text == "" then
                  UIManager:show(InfoMessage:new{
                      text = _("No valid assistant response found to add as note."),
                      timeout = 2
                  })
                  return
              end
              -- note_text now holds the content of the last valid assistant response

              local index = ui.highlight:saveHighlight(true)
              local a = ui.annotation.annotations[index]
              local current_pos0 = a.pos0
              local current_pos1 = a.pos1
              local original_index = index -- Keep track of the index returned by saveHighlight

              -- Check if another highlight with the exact same range already exists
              local existing_index = nil
              for other_idx, other_ann in ipairs(ui.annotation.annotations) do
                  -- Ensure other_ann has position data before comparing
                  if other_idx ~= original_index and other_ann.pos0 and other_ann.pos1 and other_ann.pos0 == current_pos0 and other_ann.pos1 == current_pos1 then
                      existing_index = other_idx -- Found an existing identical highlight
                      break
                  end
              end

              local nb_highlights_added = 0 -- Track if a truly new highlight was added
              if existing_index then
                  -- A duplicate was likely created, use the existing one instead
                  if logger then logger.info("Add Note: Duplicate highlight detected. Using existing index:", existing_index) end
                  index = existing_index
                  a = ui.annotation.annotations[index] -- Point 'a' to the existing annotation
                  -- We don't delete the duplicate at original_index to avoid potential issues
              else
                  -- No duplicate found, so saveHighlight potentially created a new one
                  nb_highlights_added = 1
              end

              -- Now proceed with adding/updating the note using the potentially corrected 'index' and 'a'
              local function updateNote(overwrite)
                  local was_note_empty = not a.note or a.note == ""
                  if overwrite then
                      a.note = note_text
                  else
                      -- Append new text to existing note
                      a.note = (a.note or "") .. "\n\n" .. note_text
                  end
                  local nb_notes_added = (was_note_empty and 1 or 0)
                  -- nb_highlights_added should be 1 only if no existing index was found
                  local final_nb_highlights_added = existing_index and 0 or 1

                  ui:handleEvent(Event:new("AnnotationsModified",
                                          -- Use the final index 'a' points to
                                          { a, nb_highlights_added = final_nb_highlights_added, nb_notes_added = nb_notes_added }))
                  UIManager:show(InfoMessage:new{
                      text = overwrite and _("Note overwritten successfully") or _("Note appended successfully"),
                      timeout = 2
                  })
              end

              -- Check if a note already exists for this highlight (using the final 'a')
              if a.note and a.note ~= "" then
                  local Menu = require("ui/widget/menu") -- Require Menu for options
                  local options_menu = Menu:new{
                      title = _("A note already exists. Choose action:"),
                      width = Screen:getWidth() * 0.6, -- Adjust width as needed
                      items = {
                          {
                              text = _("Overwrite existing note"),
                              callback = function() updateNote(true) end,
                          },
                          {
                              text = _("Append to existing note"),
                              callback = function() updateNote(false) end,
                          },
                          {
                              text = _("Cancel"),
                          },
                      }
                  }
                  UIManager:show(options_menu)
              else
                  -- No existing note, add it directly (equivalent to overwriting an empty note)
                  updateNote(true)
              end
          end
      }
  end

  -- Add "Add Note" button (if ui context available)
  if self.ui then
      local add_note_button = createAddNoteButton(self)
      -- Insert Add Note before Copy
      table.insert(buttons[#buttons], #buttons[#buttons], add_note_button)
  end

  -- Add "Save Conversation" button
  local save_convo_button = {
      text = self.is_saved and "★" or "☆", -- Set initial star based on saved state
      id = "save_conversation", -- Keep ID for reference
      callback = function(button_widget)
          -- Call saveConversationToHistory and pass the button widget
          self:saveConversationToHistory(button_widget)
          -- The saveConversationToHistory function now handles the button update (text, enabled state)
      end,
  }
  -- Insert Save Conversation before Add Note/Copy
  table.insert(buttons[#buttons], #buttons[#buttons] - (self.ui and 1 or 0), save_convo_button)

  self.button_table = ButtonTable:new {
    width = self.width - 2 * self.button_padding,
    buttons = buttons,
    zero_sep = true,
    show_parent = self,
  }
local textw_height = self.height - titlebar:getHeight() - self.button_table:getSize().h

-- Removed problematic dynamic font size block entirely

  self.scroll_text_w = ScrollTextWidget:new {
    text = formatMarkdown(self.text),
    face = self.text_face, -- Use the default face directly
    fgcolor = self.fgcolor,
    width = self.width - 2 * self.text_padding - 2 * self.text_margin,
    height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
    dialog = self,
    alignment = self.alignment,
    justified = self.justified, -- Use the class default (now false)
    lang = self.lang,
    para_direction_rtl = self.para_direction_rtl,
    auto_para_direction = self.auto_para_direction,
    alignment_strict = self.alignment_strict,
    scroll_callback = self._buttons_scroll_callback,
    parsed_text_format = true, -- Explicitly enable parsing of format tags
  }
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
      titlebar,
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
end

function ChatGPTViewer:askAnotherQuestion()
  -- Prevent multiple dialogs
  if self.input_dialog and self.input_dialog.dialog_open then
    return
  end

  -- Attempt to load configuration
  local success, CONFIGURATION = pcall(function() return require("configuration") end)

  -- Initialize default options
  local default_options = {}

  -- Load additional prompts from configuration if available
  if success and CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.prompts then
    -- Create a sorted list of prompts
    local sorted_prompts = {}
    for prompt_key, prompt_config_local in pairs(CONFIGURATION.features.prompts) do
      table.insert(sorted_prompts, {key = prompt_key, config = prompt_config_local})
    end
    -- Sort by order value, default to 1000 if not specified
    table.sort(sorted_prompts, function(a, b)
      local order_a = a.config.order or 1000
      local order_b = b.config.order or 1000
      return order_a < order_b
    end)
    -- Add sorted prompts to default_options
    for i, prompt_data in ipairs(sorted_prompts) do
      -- Removed filter: Add all prompts now
        table.insert(default_options, {
          text = _(prompt_data.config.text), -- Translate prompt text
          callback = function()
            -- Close the current input dialog first
            if self.input_dialog then
              self.input_dialog.dialog_open = false
              UIManager:close(self.input_dialog)
              self.input_dialog = nil
            end

            -- Show loading indicator (using InfoMessage directly)
            local InfoMessage = require("ui/widget/infomessage")
            local loading_dialog_ask = InfoMessage:new{ text = _("Querying AI..."), timeout = nil }
            UIManager:show(loading_dialog_ask)

            -- Schedule the API call and viewer creation
            UIManager:scheduleIn(0.1, function()
                -- Find the last assistant message
                local last_assistant_message = nil
                if self.message_history and #self.message_history > 0 then
                    for i = #self.message_history, 1, -1 do
                        if self.message_history[i].role ~= "user" and not self.message_history[i].is_context then
                            last_assistant_message = self.message_history[i].content
                            break
                        end
                    end
                end
                -- Use last assistant message or original highlight
                local text_to_use = last_assistant_message or self.highlighted_text or ""

                -- Re-implement handlePredefinedPrompt logic locally
                local prompt_type = prompt_data.type
                local prompt = prompt_data.config
                local ui_ctx = self.ui -- Use the viewer's ui context

                if not plugin_config or not plugin_config.features or not plugin_config.features.prompts then
                    UIManager:show(InfoMessage:new{text = _("Error: No prompts configured")})
                    return
                end
                if not prompt then
                    UIManager:show(InfoMessage:new{text = _("Error: Prompt not found")})
                    return
                end

                local Dialogs = require("dialogs") -- Require the table M
                local book = Dialogs.getBookContext(ui_ctx) -- Use table access
                local formatted_user_prompt = (prompt.user_prompt or "Please analyze: ")
                    :gsub("{title}", book.title)
                    :gsub("{author}", book.author)
                    :gsub("{highlight}", text_to_use)
                local user_content = (string.find(prompt.user_prompt or "", "{highlight}")) and formatted_user_prompt or (formatted_user_prompt .. text_to_use)

                -- Start with existing message history or create new one
                -- local util_local = require("util") -- Require util locally (Removed due to issues)
                -- Manual shallow copy for history as table.copy/deepcopy are problematic
                local initial_history = {}
                if self.message_history then
                    for _, v in ipairs(self.message_history) do table.insert(initial_history, v) end
                else
                    initial_history = {
                    } -- End of else block for initial_history creation
                    table.insert(initial_history, { role = "system", content = prompt.system_prompt or "You are a helpful assistant." })
                end -- End of if/else for self.message_history check
                -- Add new user message
                table.insert(initial_history, { role = "user", content = user_content, is_context = true })
                -- Get active provider (duplicate logic from main.lua/gpt_query.lua)
                local provider_ask = "gemini" -- Default
                -- Use top-level DataStorage
                if DataStorage and DataStorage.getSettingsDir then -- Use top-level DataStorage
                    local settings_dir_ask = DataStorage:getSettingsDir()
                    if settings_dir_ask then
                        local assistant_settings_path_ask = settings_dir_ask .. "/assistant_settings.lua"
                        local ok_ask, settings_ask = pcall(DataStorage.readSettings, DataStorage, assistant_settings_path_ask) -- Use top-level DataStorage
                        if ok_ask and type(settings_ask) == "table" then
                             provider_ask = settings_ask.active_provider or provider_ask
                        end
                    end
                end
                provider_ask = provider_ask or (plugin_config and plugin_config.provider) or "gemini"

                local answer = queryChatGPT(initial_history, provider_ask) -- Pass provider name

                local new_message_history
                if answer then
                    table.insert(initial_history, { role = "assistant", content = answer })
                    new_message_history = initial_history
                else
                    UIManager:show(InfoMessage:new{text = _("Error: No response from AI")})
                    return -- Stop if no answer
                end

                -- Re-implement createAndShowViewer logic locally
                local title_text = prompt.text
                local show_h_text = false -- Don't show original highlight in follow-up
                local result_text = Dialogs.createResultText(text_to_use, new_message_history, nil, show_h_text) -- Use table access

                -- Prepare previous conversation text if there was one
                if self.text and self.text ~= "" then
                    result_text = self.text .. "\n" .. result_text
                end

                local new_viewer = ChatGPTViewer:new {
                    title = _(title_text),
                    text = result_text,
                    ui = ui_ctx,
                    onAskQuestion = self.onAskQuestion, -- Pass the original callback
                    highlighted_text = text_to_use, -- Pass the text used for the prompt
                    message_history = new_message_history
                }
                if loading_dialog_ask then UIManager:close(loading_dialog_ask) end -- Close loading dialog
                UIManager:show(new_viewer)
                if plugin_config and plugin_config.features and plugin_config.features.refresh_screen_after_displaying_results then
                    UIManager:setDirty(nil, "full")
                end
            end)
            if self.input_dialog then -- Close the dialog
              self.input_dialog.dialog_open = false
              UIManager:close(self.input_dialog)
              self.input_dialog = nil
            end
          end,
        })
      -- Removed end for the filter if statement
    end
  end

  self.input_dialog = InputDialog:new{
    title = _("Ask a question"),
    input_hint = _("Enter your question here"),
    buttons = (function() -- Use function to construct buttons like in dialogs.lua
      local all_buttons = {
        {
          text = _("Cancel"),
          id = "close",
          callback = function()
            if self.input_dialog then
              self.input_dialog.dialog_open = false
              UIManager:close(self.input_dialog)
              self.input_dialog = nil
            end
          end
        },
        {
          text = _("Ask"),
          is_enter_default = true,
          callback = function()
            local user_input = self.input_dialog:getInputText()
            if not user_input or user_input == "" then return end

            -- Show loading indicator (using InfoMessage directly)
            local loading_dialog_ask = InfoMessage:new{ text = _("Querying AI..."), timeout = nil }
            UIManager:show(loading_dialog_ask)

            -- Schedule the API call and viewer creation
            UIManager:scheduleIn(0.1, function()
              -- Initialize or copy message history
              local util_local = require("util") -- Require util locally
              local new_message_history = self.message_history and util_local.deepcopy(self.message_history) or {
                { role = "system", content = "You are a helpful assistant." }
              }

              -- Add the new question
              table.insert(new_message_history, { role = "user", content = user_input })

              -- Get the response using the entire message history
              local provider_name = getActiveProvider()
              local answer = queryChatGPT(new_message_history, provider_name)

              -- Handle the response
              local result_text = ""
              if self.text and self.text ~= "" then
                result_text = self.text .. "\n"
              end
              result_text = result_text .. "⮞ " .. _("User: ") .. user_input .. "\n"

              -- Get the assistant prefix if configured
              local assistant_prefix = (plugin_config and plugin_config.features and plugin_config.features.show_assistant_prefix) and "Assistant: " or ""

              -- Check if answer is a non-error response
              if answer and not answer:match("^Error:") then
                -- Add valid response to history and display
                table.insert(new_message_history, { role = "assistant", content = answer })
                result_text = result_text .. "⮞ " .. assistant_prefix .. answer .. "\n\n"

                -- Create new viewer with the updated history
                local new_viewer = ChatGPTViewer:new {
                  title = self.title,
                  text = result_text,
                  ui = self.ui,
                  onAskQuestion = self.onAskQuestion,
                  highlighted_text = self.highlighted_text,
                  message_history = new_message_history
                }
                UIManager:show(new_viewer)
              else
                -- Show error message (including API errors)
                local error_msg = answer or _("No response from AI")
                result_text = result_text .. "⮞ " .. assistant_prefix .. error_msg .. "\n\n"
                
                -- Create new viewer without adding error to history
                local new_viewer = ChatGPTViewer:new {
                  title = self.title,
                  text = result_text,
                  ui = self.ui,
                  onAskQuestion = self.onAskQuestion,
                  highlighted_text = self.highlighted_text,
                  message_history = new_message_history -- History without error message
                }
                UIManager:show(new_viewer)
              end

              -- Always close loading dialog
              if loading_dialog_ask then
                UIManager:close(loading_dialog_ask)
              end

              -- Always close input dialog
              if self.input_dialog then
                self.input_dialog.dialog_open = false
                UIManager:close(self.input_dialog)
                self.input_dialog = nil
              end
            end)
          end
        }
      }

      -- Add the prompt buttons collected earlier
      for _, prompt_button_def in ipairs(default_options) do
          table.insert(all_buttons, prompt_button_def)
      end

      -- Organize buttons into rows of three
      local button_rows = {}
      local current_row = {}
      for _, button in ipairs(all_buttons) do
        table.insert(current_row, button)
        if #current_row == 3 then
          table.insert(button_rows, current_row)
          current_row = {}
        end
      end
      if #current_row > 0 then
        table.insert(button_rows, current_row)
      end
      return button_rows
    end)(), -- Immediately call the function to get the button rows
    dialog_open = true, -- Flag to track dialog state
    close_callback = function() -- Add close_callback like in dialogs.lua
      if self.input_dialog then
        UIManager:close(self.input_dialog)
        self.input_dialog = nil
      end
    end,
    dismiss_callback = function() -- Add dismiss_callback like in dialogs.lua
      if self.input_dialog then
        UIManager:close(self.input_dialog)
        self.input_dialog = nil
      end
    end
  } -- Closing brace for InputDialog:new
  UIManager:show(self.input_dialog)
  self.input_dialog:onShowKeyboard()
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
  local ok, active_window = pcall(function() return UIManager:getActiveWindow() end)

  pcall(function() UIManager:close(self) end)

  pcall(function()
    UIManager:setDirty(nil, "full")
    UIManager:forceRePaint()
  end)

  if self.close_callback then
    pcall(function() self.close_callback() end)
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
  if not self.movable then
    if logger then logger.warn("ChatGPTViewer: onForwardingTouch called but self.movable is nil!") end
    return false -- Cannot handle touch if movable container doesn't exist
  end
  -- if logger then logger.info("ChatGPTViewer: Entering onForwardingTouch. self.scroll_text_w is:", self.scroll_text_w) else print("ChatGPTViewer: Entering onForwardingTouch. Logger is NIL!") end
  -- if logger then logger.info("ChatGPTViewer: Entering onForwardingTouch. self.scroll_text_w is:", self.scroll_text_w) else print("ChatGPTViewer: Entering onForwardingTouch. Logger is NIL!") end
  -- if self.scroll_text_w:isSelectingText() then -- Commented out to prevent crash
    -- return true -- Don't move window while selecting text
  -- end
  -- end -- Removed extra end from commenting out the if block
  -- This Touch may be used as the Hold we don't get (for example,
  -- when we start our Hold on the bottom buttons)
  if not ges.pos:intersectWith(self.textw.dimen) then
    return self.movable:onMovableTouch(arg, ges)
  else
    -- Ensure this is unset, so we can use it to not forward HoldPan
    self.movable._touch_pre_pan_was_inside = false
  end
end -- Re-enabled end for the function

function ChatGPTViewer:onForwardingPan(arg, ges)
  if not self.movable then
    if logger then logger.warn("ChatGPTViewer: onForwardingPan called but self.movable is nil!") end
    return false -- Cannot handle pan if movable container doesn't exist
  end
  -- if self.scroll_text_w:isSelectingText() then -- Commented out to prevent crash
    -- return true -- Don't move window while selecting text
  -- end
  -- We only forward it if we did forward the Touch or are currently moving
  if self.movable._touch_pre_pan_was_inside or self.movable._moving then
    return self.movable:onMovablePan(arg, ges)
  end
end

function ChatGPTViewer:onForwardingPanRelease(arg, ges)
  if self.scroll_text_w:isSelectingText() then
    return true -- Don't move window while selecting text
  end
  return self.movable:onPanRelease(ges.pos, ges.touch_id)
end

function ChatGPTViewer:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
    -- This function is called when text is selected in the ScrollTextWidget
    -- You can add logic here to handle the selected text, e.g., copy it,
    -- look it up, or use it for a new query.
    if text and text ~= "" then
        -- Example: Show an InfoMessage with the selected text
        -- UIManager:show(InfoMessage:new{ text = "Selected: " .. text, timeout = 3 })

        -- Example: Copy selected text to clipboard
        Device.input.setClipboardText(text)
        UIManager:show(InfoMessage:new{ text = _("Selected text copied"), timeout = 2 })

        -- Example: Use selected text for a new query (if onAskQuestion is defined)
        -- if self.onAskQuestion then
        --     local query_prompt = "Explain this selected text: {highlight}" -- Example prompt
        --     self.onAskQuestion(query_prompt:format{highlight = text})
        -- end
    end
end

function ChatGPTViewer:saveConversationToHistory(button_widget)
    local logger = require("logger")
    local LuaSettings = require("luasettings")
    local util = require("util")
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")

    -- 1. Error Check: Check last assistant message
    local last_assistant_message = nil
    if self.message_history and #self.message_history > 0 then
        for i = #self.message_history, 1, -1 do
            if self.message_history[i].role == "assistant" then
                last_assistant_message = self.message_history[i].content
                break
            end
        end
    end

    if last_assistant_message and (
        last_assistant_message:match("^Error:") or
        last_assistant_message:match("^Gemini API Error") or
        last_assistant_message:match("^OpenAI API Error") or
        last_assistant_message:match("^Anthropic API Error") or
        last_assistant_message:match("^Ollama API Error") or
        last_assistant_message:match("^DeepSeek API Error") or
        last_assistant_message:match("^Mistral API Error") or
        last_assistant_message:match("^OpenRouter API Error")
    ) then
        UIManager:show(InfoMessage:new{ text = _("Cannot save conversation with error"), timeout = 2 })
        return
    end

    -- Get settings path
    local settings_dir = DataStorage:getSettingsDir()
    if not settings_dir then
        if logger then logger.error("saveConversationToHistory: Could not get settings directory") end
        UIManager:show(InfoMessage:new{ text = _("Error: Could not get settings directory."), timeout = 3 })
        return
    end
    local conversation_store_path = settings_dir .. "/assistant_conversations.lua"
    local settings_store = LuaSettings:open(conversation_store_path)
    local history = settings_store:readSetting("conversations") or {}

    -- 2. Check if already saved using the creation timestamp
    local found_index = nil
    for i, entry in ipairs(history) do
        -- Use both timestamps for identification
        if entry.created_timestamp == self.created_timestamp
           and entry.save_timestamp == self.save_timestamp then
            found_index = i
            break
        end
    end

    local ok, err
    if found_index then
        -- Delete Logic
        table.remove(history, found_index)
        ok, err = pcall(function()
            settings_store:saveSetting("conversations", history)
            settings_store:flush()
        end)
        if ok then
            UIManager:show(InfoMessage:new{ text = _("Conversation removed from history"), timeout = 2 })
            -- Create and show new viewer with updated state (not saved)
            local new_viewer = ChatGPTViewer:new{
                ui = self.ui,
                title = self.title,
                -- Regenerate text to ensure correctness, pass false for show_highlighted_text
                text = require("dialogs").createResultText(self.highlighted_text, self.message_history, nil, false),
                message_history = self.message_history,
                highlighted_text = self.highlighted_text,
                onAskQuestion = self.onAskQuestion,
                created_timestamp = self.created_timestamp, -- Pass original timestamp
                save_timestamp = nil, -- Clear save timestamp
                is_saved = false -- Mark as not saved
            }
            UIManager:show(new_viewer)
            UIManager:close(self) -- Close the old viewer
        else
            if logger then logger.error("saveConversationToHistory: Failed to remove conversation:", err) end
            UIManager:show(InfoMessage:new{ text = _("Error removing conversation"), timeout = 2 })
        end
    else
        -- Save Logic
        local message_history_copy = self.message_history
        if util and util.deepcopy then
            message_history_copy = util.deepcopy(self.message_history)
        end
        local new_entry = {
            created_timestamp = self.created_timestamp,
            save_timestamp = os.time(),
            topic = self.topic, -- Save the topic
            title = self.title or os.date("%Y-%m-%d %H:%M"), -- Keep original title as fallback
            highlighted_text = self.highlighted_text,
            message_history = message_history_copy or {}
        }
        table.insert(history, 1, new_entry) -- Insert at start

        -- Limit history size
        while #history > 50 do
            table.remove(history)
        end

        ok, err = pcall(function()
            settings_store:saveSetting("conversations", history)
            settings_store:flush()
        end)

        if ok then
            UIManager:show(InfoMessage:new{ text = _("Conversation saved to history"), timeout = 2 })
            -- Create and show new viewer with updated state (saved)
            local new_viewer = ChatGPTViewer:new{
                ui = self.ui,
                title = self.title,
                -- Regenerate text to ensure correctness, pass false for show_highlighted_text
                text = require("dialogs").createResultText(self.highlighted_text, self.message_history, nil, false),
                message_history = self.message_history,
                highlighted_text = self.highlighted_text,
                onAskQuestion = self.onAskQuestion,
                created_timestamp = self.created_timestamp, -- Pass original timestamp
                save_timestamp = new_entry.save_timestamp, -- Use the exact timestamp saved
                is_saved = true -- Mark as saved
            }
            UIManager:show(new_viewer)
            UIManager:close(self) -- Close the old viewer
        else
            if logger then logger.error("saveConversationToHistory: Failed to save conversation:", err) end
            UIManager:show(InfoMessage:new{ text = _("Failed to save conversation"), timeout = 2 })
        end
    end -- end of main if/else block (found_index)
end

-- New function to update an existing conversation in history
function ChatGPTViewer:updateSavedConversation()
    local logger = require("logger")
    local LuaSettings = require("luasettings")
    local util = require("util")
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")

    -- Ensure this conversation was actually saved before trying to update
    if not self.is_saved or not self.created_timestamp or not self.save_timestamp then
        if logger then logger.warn("updateSavedConversation: Attempted to update unsaved or invalid conversation.") end
        return
    end

    -- Get settings path (similar to saveConversationToHistory)
    local settings_dir = DataStorage:getSettingsDir()
    if not settings_dir then
        if logger then logger.error("updateSavedConversation: Could not get settings directory") end
        return
    end
    local conversation_store_path = settings_dir .. "/assistant_conversations.lua"
    local settings_store = LuaSettings:open(conversation_store_path)
    local history = settings_store:readSetting("conversations") or {}

    -- Find the existing entry
    local found_index = nil
    for i, entry in ipairs(history) do
        if entry.created_timestamp == self.created_timestamp and entry.save_timestamp == self.save_timestamp then
            found_index = i
            break
        end
    end

    if found_index then
        -- Update the entry
        local updated_entry = {
            created_timestamp = self.created_timestamp,
            save_timestamp = os.time(), -- Update save timestamp
            topic = self.topic, -- Ensure topic is included in update
            title = self.title or os.date("%Y-%m-%d %H:%M"),
            highlighted_text = self.highlighted_text,
            message_history = self.message_history or {} -- Use current history
        }
        history[found_index] = updated_entry

        -- Save the updated history
        local ok, err = pcall(function()
            settings_store:saveSetting("conversations", history)
            settings_store:flush()
        end)

        if ok then
            -- Update the viewer's own save_timestamp to match the new one
            self.save_timestamp = updated_entry.save_timestamp
            if logger then logger.info("updateSavedConversation: Conversation updated successfully.") end
            -- Optional: Show a subtle confirmation?
            -- UIManager:show(InfoMessage:new{ text = _("Conversation updated"), timeout = 1 })
        else
            if logger then logger.error("updateSavedConversation: Failed to save updated history:", err) end
            UIManager:show(InfoMessage:new{ text = _("Error updating conversation"), timeout = 2 })
        end
    else
        if logger then logger.warn("updateSavedConversation: Entry not found for update. Timestamps:", self.created_timestamp, self.save_timestamp) end
        -- Maybe try saving as a new entry instead? Or just report error?
        UIManager:show(InfoMessage:new{ text = _("Error: Could not find conversation to update"), timeout = 2 })
    end
end

function ChatGPTViewer:rebuildTextFromHistory()
    local text = ""
    -- Use the already loaded plugin_config
    local current_plugin_config = plugin_config

    if self.highlighted_text then
         text = text .. _("Highlighted text: ") .. "\"" .. self.highlighted_text .. "\"\n\n"
    end
    if self.message_history then
        for i = 1, #self.message_history do -- Start from 1 to include system prompt if needed
          local msg = self.message_history[i]
          if not msg.is_context then
            local content = msg.content or ""
            -- Skip assistant messages that are error responses
            if msg.role == "assistant" and content:match("^Error:") then
              -- Skip this message
            else
              if msg.role == "user" then
                text = text .. "▶ " .. _("User: ") .. truncateUserPrompt(content) .. "\n"
              elseif msg.role == "assistant" then
                local prefix = (current_plugin_config and current_plugin_config.features and current_plugin_config.features.show_assistant_prefix) and "Assistant: " or ""
                text = text .. "◀ " .. prefix .. content .. "\n\n"
              -- Optionally handle system prompt differently if needed
              -- elseif msg.role == "system" then
              --   text = text .. "[System: " .. content .. "]\n"
              end
            end
          end
        end
    end
    return text
end

-- Helper function to truncate user prompt if needed
local function truncateUserPrompt(prompt)
    local max_len = (plugin_config and plugin_config.features and plugin_config.features.max_display_user_prompt_length) or 100 -- Default 100
    if #prompt > max_len then
        return prompt:sub(1, max_len) .. "..."
    end
    return prompt
end

function ChatGPTViewer:update(new_text)
    -- Update the message history (assuming new_text is the latest assistant response)
    if self.message_history and #self.message_history > 0 then
        local last_message = self.message_history[#self.message_history]
        if last_message.role == "assistant" then
            last_message.content = new_text -- Update last assistant message
        else
            -- This case shouldn't normally happen if the flow is correct,
            -- but handle it by adding a new assistant message
            table.insert(self.message_history, { role = "assistant", content = new_text })
        end
    else
        -- If no history, just add the new text as an assistant message
        self.message_history = {{ role = "assistant", content = new_text }}
    end

    -- Rebuild the display text from the updated history
    self.text = self:rebuildTextFromHistory()

    -- Update the ScrollTextWidget
    if self.scroll_text_w then
        self.scroll_text_w:setText(formatMarkdown(self.text))
        self.scroll_text_w:resetScroll() -- Scroll to top after update
        self.scroll_text_w:paintTo(self.scroll_text_w.bb, 0, 0) -- Repaint
        UIManager:setDirty(self, function() return "partial", self.frame.dimen end) -- Mark for repaint
    end

    -- Re-enable the save button if it exists and was disabled
    local save_button = self.button_table and self.button_table:getButtonById("save_conversation")
    if save_button and not save_button:isEnabled() then
        save_button:setText("☆") -- Reset to empty star
        save_button:enable()
        save_button:refresh()
    end
end


return ChatGPTViewer
