local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("assistant_viewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local Font = require("ui/font")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local Prompts = require("assistant_prompts")
local koutil = require("util")
local Device = require("device")
local Screen = Device.screen

-- main dialog class
local AssistantDialog = {
  CONFIGURATION = nil,
  assistant = nil,
  querier = nil,
  input_dialog = nil,
}
AssistantDialog.__index = AssistantDialog

function AssistantDialog:new(assistant, c)
  local self = setmetatable({}, AssistantDialog)
  self.assistant = assistant
  self.querier = assistant.querier
  self.CONFIGURATION = c
  return self
end

function AssistantDialog:_close()
  if self.input_dialog then
    UIManager:close(self.input_dialog)
    self.input_dialog = nil
  end
end

function AssistantDialog:_formatUserPrompt(user_prompt, highlightedText)
  local book = self:_getBookContext()
  
  -- Handle case where no text is highlighted (gesture-triggered)
  local text_to_use = highlightedText and highlightedText ~= "" and highlightedText or ""
  local language = self.assistant.settings:readSetting("response_language") or self.assistant.ui_language
  local suggestions_prompt = self.assistant.settings:readSetting("auto_prompt_suggest", false) and 
            Prompts.assistant_prompts.suggestions_prompt:gsub("{(%w+)}", {language = language}) or ""

  -- replace placeholders in the user prompt
  return user_prompt:gsub("{(%w+)}", {
    title = book.title,
    author = book.author,
    language = language,
    highlight = text_to_use,
    suggestions = suggestions_prompt,
  })
end

function AssistantDialog:_createResultText(highlightedText, message_history, previous_text, title)
  -- Helper function to format a single message (user or assistant)
  local function formatSingleMessage(message, title)
    if not message then return "" end
    if message.role == "user" then
      local user_message
      if title and title ~= "" then
        -- shows "User: <title>" if title is provided
        user_message = string.format("%s\n\n", title)
      else
        -- shows user input prompt
        user_message = string.format("\n\n%s\n\n", message.content or _("(Empty message)"))
      end
      return "### ⮞ User: " .. user_message
    elseif message.role == "assistant" then
      local assistant_content = message.content or _("(No response)")
      -- Remove code block markers before displaying
      assistant_content = assistant_content:gsub("```", "\n")
      return string.format("### ⮞ Assistant:\n\n%s\n\n", assistant_content)
    end
    return "" -- Should not happen for valid roles
  end

  -- first response message
  if not previous_text then
    local result_text = ""
    local show_highlighted_text = true

    -- if highlightedText is nil or empty, don't show highlighted text
    if not highlightedText or highlightedText == "" then
      show_highlighted_text = false
    end

    -- won't show if `hide_highlighted_text` is set to false
    if koutil.tableGetValue(self.CONFIGURATION, "features", "hide_highlighted_text") then
      show_highlighted_text = false
    end

    -- won't show if highlighted text is longer than threshold `long_highlight_threshold`
    if show_highlighted_text and koutil.tableGetValue(self.CONFIGURATION, "features", "hide_long_highlights") and
        highlightedText and #highlightedText > (koutil.tableGetValue(self.CONFIGURATION, "features", "long_highlight_threshold") or 99999) then
      show_highlighted_text = false
    end

    local result_parts = {}
    if show_highlighted_text then
      table.insert(result_parts, string.format("__%s__\"%s\"\n\n", _("Highlighted text:"), highlightedText))
    end
    
    -- skips the first message (system prompt)
    for i = 2, #message_history do
      local message = message_history[i]
      if not message.is_context then
        table.insert(result_parts, formatSingleMessage(message, title))
      end
    end
    return table.concat(result_parts)
  end

  local last_user_message = message_history[#message_history - 1]
  local last_assistant_message = message_history[#message_history]

  return previous_text .. "------------\n\n" ..
      formatSingleMessage(last_user_message, title) .. formatSingleMessage(last_assistant_message, title)
end

-- Helper function to create and show ChatGPT viewer
function AssistantDialog:_createAndShowViewer(highlightedText, message_history, title)
  local result_text = self:_createResultText(highlightedText, message_history, nil, title)
  
  local chatgpt_viewer 
  chatgpt_viewer = ChatGPTViewer:new {
    title = title,
    text = result_text,
    text_face = Font:getFace("infofont", self.assistant.settings:readSetting("response_font_size") or 20),
    assistant = self.assistant,
    ui = self.assistant.ui,
    -- Hide Add Note button when invoked via gesture (no highlighted text)
    disable_add_note = (not highlightedText or highlightedText == ""),
    onAskQuestion = function(viewer, user_question) -- callback for user entered question
        -- Use viewer's own highlighted_text value
        local current_highlight = viewer.highlighted_text or highlightedText
        local viewer_title = ""

        if type(user_question) == "string" then
          -- Use user entered question
          if self.assistant.settings:readSetting("auto_prompt_suggest", false) then
            user_question = user_question .. "\n\n" .. Prompts.assistant_prompts.suggestions_prompt
          end
          self:_prepareMessageHistoryForUserQuery(message_history, current_highlight, user_question)
        elseif type(user_question) == "table" then
          -- Use custom prompt from configuration
          viewer_title = user_question.text or "Custom Prompt"
          table.insert(message_history, {
            role = "user",
            content = self:_formatUserPrompt(user_question.user_prompt, current_highlight)
          })
        end

        viewer:trimMessageHistory()
        Trapper:wrap(function()
          local answer, err = self.querier:query(message_history)
          
          -- Check if we got a valid response
          if err then
            self.querier:showError(err)
            return
          end
          
          table.insert(message_history, {
            role = "assistant",
            content = answer
          })
          viewer:update(self:_createResultText(current_highlight, message_history, viewer.text, viewer_title))
          
          if viewer.scroll_text_w then
            viewer.scroll_text_w:resetScroll()
          end
        end)
      end,
    highlighted_text = highlightedText,
    message_history = message_history,
    render_markdown = koutil.tableGetValue(self.CONFIGURATION, "features", "render_markdown") or true,
    default_hold_callback = function () chatgpt_viewer:HoldClose() end
  }
  
  UIManager:show(chatgpt_viewer)
end


function AssistantDialog:_prepareMessageHistoryForUserQuery(message_history, highlightedText, user_question)
  local book = self:_getBookContext()
  local context = {}
  if highlightedText and highlightedText ~= "" then
    context = {
      role = "user",
      is_context = true,
      content = string.format([[I'm reading something titled '%s' by %s.
I have a question about the following highlighted text: ```%s```.
If the question is not clear enough, analyze the highlighted text.]],
      book.title, book.author, highlightedText),
    }
  else
    context = {
      role = "user",
      is_context = true,
      content = string.format([[I'm reading something titled '%s' by %s.
I have a question about this book.]], book.title, book.author),
    }
  end

  table.insert(message_history, context)
  local question_message = {
    role = "user",
    content = user_question
  }
  table.insert(message_history, question_message)
end

function AssistantDialog:_getBookContext()
  local prop = self.assistant.ui.document:getProps()
  return {
    title = prop.title or "Unknown Title",
    author = prop.authors or "Unknown Author"
  }
end

-- When clicked [Assistant] button in main select popup,
-- Or when activated from guesture (no text highlighted)
function AssistantDialog:show(highlightedText)

  local is_highlighted = highlightedText and highlightedText ~= ""
  
  -- close any existing input dialog
  self:_close()

  -- Handle regular dialog (user input prompt, other buttons)
  local book = self:_getBookContext()
  local system_prompt = koutil.tableGetValue(self.CONFIGURATION, "features", "system_prompt") or koutil.tableGetValue(Prompts, "assistant_prompts", "default", "system_prompt")
  local message_history = {{
    role = "system",
    content = system_prompt
  }}

  -- Create button rows (3 buttons per row)
  local button_rows = {}
  local prompt_buttons = {}
  local first_row = {
    {
      text = _("Cancel"),
      id = "close",
      callback = function()
        self:_close()
      end
    },
    {
      text = _("Ask"),
      is_enter_default = true,
      callback = function()
        local user_question = self.input_dialog and self.input_dialog:getInputText() or ""
        if not user_question or user_question == "" then
          UIManager:show(InfoMessage:new{
            text = _("Enter a question before proceeding."),
            timeout = 3
          })
          return
        end
        if self.assistant.settings:readSetting("auto_copy_asked_question", true) and Device:hasClipboard() then
          Device.input.setClipboardText(user_question)
        end
        self:_close()
        self:_prepareMessageHistoryForUserQuery(message_history, highlightedText, user_question)
        Trapper:wrap(function()
          local answer, err = self.querier:query(message_history)
          
          -- Check if we got a valid response
          if err then
            self.querier:showError(err)
            return
          end
          
          table.insert(message_history, {
            role = "assistant",
            content = answer,
          })
          
          -- do not have a title to display user prompt 
          local viewer_title = nil
          self:_createAndShowViewer(highlightedText, message_history, viewer_title)
        end)
      end
    }
  }
  
  -- Only add additional buttons if there's highlighted text
  if is_highlighted then
    local sorted_prompts = Prompts.getSortedCustomPrompts(function (prompt)
      if prompt.visible == false then
        return false
      end
      return true
    end) or {}

    -- logger.warn("Sorted prompts: ", sorted_prompts)
    -- Add buttons in sorted order
    for i, tab in ipairs(sorted_prompts) do
      table.insert(prompt_buttons, {
        text = tab.text,
        callback = function()
          self:_close()
          Trapper:wrap(function()
            if tab.order == -10 and tab.idx == "dictionary" then
              -- Special case for dictionary prompt
              local showDictionaryDialog = require("assistant_dictdialog")
              showDictionaryDialog(self.assistant, highlightedText)
            else
              self:showCustomPrompt(highlightedText, tab.idx)
            end
          end)
        end,
        hold_callback = function()
          local menukey = string.format("assistant_%02d_%s", tab.order, tab.idx)
          local settingkey = "showOnMain_" .. menukey
          UIManager:show(ConfirmBox:new{
            text = string.format("%s: %s\n\n%s", tab.text, tab.desc, _("Add this button to the Highlight Menu?")),
            ok_text = _("Add"),
            ok_callback = function()
              self.assistant:handleEvent(Event:new("AssistantSetButton", {order=tab.order, idx=tab.idx}, "add"))
            end,
          })
        end
      })
    end
  end
  
  table.insert(button_rows, first_row)
  -- Organize buttons into rows of three
  local current_row = {}
  for _, button in ipairs(prompt_buttons) do
    table.insert(current_row, button)
    if #current_row == 3 then
      table.insert(button_rows, current_row)
      current_row = {}
    end
  end
  
  if #current_row > 0 then
    table.insert(button_rows, current_row)
  end

  -- Show the dialog with the button rows
  local dialog_hint = is_highlighted and 
    _("Ask a question about the highlighted text") or 
    string.format(_("Ask a question about this book:\n%s by %s"), book.title, book.author)
  
  local input_hint = is_highlighted and 
    _("Type your question here...") or 
    _("Ask anything about this book...")
  
  self.input_dialog = InputDialog:new{
    title = _("AI Assistant"),
    description = dialog_hint,
    input_hint = input_hint,
    input_height = 6,
    allow_newline = false,
    input_multiline = true,
    text_height = math.floor( 10 * Screen:scaleBySize(20) ), -- about 10 lines of text
    buttons = button_rows,
    title_bar_left_icon = "appbar.settings",
    title_bar_left_icon_tap_callback = function ()
        self.input_dialog:onCloseKeyboard()
        self.assistant:showSettings()
    end,
    close_callback = function () self:_close() end,
    dismiss_callback = function () self:_close() end
  }
  
  --  adds a close button to the top right
  self.input_dialog.title_bar.close_callback = function() self:_close() end
  self.input_dialog.title_bar:init()
  UIManager:show(self.input_dialog)
end

-- Process main select popup buttons
-- ( custom prompts from configuration )
function AssistantDialog:showCustomPrompt(highlightedText, prompt_index)

  local user_prompts = koutil.tableGetValue(self.CONFIGURATION, "features", "prompts")
  local prompt_config = Prompts.getMergedCustomPrompts(user_prompts)[prompt_index]

  local title = koutil.tableGetValue(prompt_config, "text") or prompt_index

  highlightedText = highlightedText:gsub("\n", "\n\n") -- ensure newlines are doubled (LLM presumes markdown input)
  local user_content = self:_formatUserPrompt(koutil.tableGetValue(prompt_config, "user_prompt"), highlightedText)
  local message_history = {
    {
      role = "system",
      content = koutil.tableGetValue(prompt_config, "system_prompt") or koutil.tableGetValue(Prompts, "assistant_prompts", "default", "system_prompt"),
    },
    {
      role = "user",
      content = user_content,
      is_context = true
    }
  }
  
  local answer, err = self.querier:query(message_history, string.format("🌐 Loading for %s ...", title or prompt_index))
  if err then
    self.querier:showError(err)
    return
  end
  if answer then
    table.insert(message_history, {
      role = "assistant",
      content = answer
    })
  end

  if not message_history or #message_history < 1 then
    UIManager:show(InfoMessage:new{text = _("Error: No response received"), icon = "notice-warning"})
    return
  end

  self:_createAndShowViewer(highlightedText, message_history, title)
end

return AssistantDialog