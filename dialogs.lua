local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local Trapper = require("ui/trapper")

local CONFIGURATION = nil
local buttons, input_dialog = nil, nil
local Querier = nil

local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  logger.warn("configuration.lua not found, skipping...")
end

-- Helper function to truncate text based on configuration
local function truncateUserPrompt(text)
  if not CONFIGURATION or not CONFIGURATION.features.max_display_user_prompt_length then
    return text
  end
  
  local max_length = CONFIGURATION.features.max_display_user_prompt_length
  if max_length <= 0 then
    return text
  end
  
  if text and #text > max_length then
    return text:sub(1, max_length) .. "..."
  end
  return text
end

local function getBookContext(ui)
  return {
    title = ui.document:getProps().title or _("Unknown Title"),
    author = ui.document:getProps().authors or _("Unknown Author")
  }
end

local function formatUserPrompt(user_prompt, highlightedText, ui)
  local book = getBookContext(ui)
  
  -- Handle case where no text is highlighted (gesture-triggered)
  local text_to_use = highlightedText and highlightedText ~= "" and highlightedText or ""
  local language = (CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.response_language) or "English"
  
  -- replace placeholders in the user prompt
  return user_prompt:gsub("{(%w+)}", {
    title = book.title,
    author = book.author,
    language = language,
    highlight = text_to_use,
  })
end

local function createContextMessage(ui, highlightedText)
  local book = getBookContext(ui)
  if highlightedText and highlightedText ~= "" then
    return {
      role = "user",
      content = "I'm reading something titled '" .. book.title .. "' by " .. book.author ..
        ". I have a question about the following highlighted text: " .. highlightedText .. 
        ". If the question is not clear enough, analyze the highlighted text.",
      is_context = true
    }
  else
    return {
      role = "user",
      content = "I'm reading something titled '" .. book.title .. "' by " .. book.author .. ". I have a question about this book.",
      is_context = true
    }
  end
end

local function handleFollowUpQuestion(message_history, new_question, ui, highlightedText)
  local context_message = createContextMessage(ui, highlightedText)
  table.insert(message_history, context_message)

  local question_message = {
    role = "user",
    content = formatUserPrompt(new_question, highlightedText, ui)
  }
  table.insert(message_history, question_message)

  local answer, err = Querier:query(message_history)
  
  -- Check if we got a valid response
  if not answer or answer == "" or err ~= nil then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = err or "",
    })
    return
  end
  
  local answer_message = {
    role = "assistant",
    content = answer
  }
  table.insert(message_history, answer_message)

  return message_history
end

local function createResultText(highlightedText, message_history, previous_text, show_highlighted_text, title)
  if not previous_text then
    local result_text = ""
    -- Check if we should show highlighted text based on configuration
    if show_highlighted_text and 
       highlightedText and highlightedText ~= "" and
       (not CONFIGURATION or 
        not CONFIGURATION.features or 
        not CONFIGURATION.features.hide_highlighted_text) then
      
      -- Check for long text
      local should_show = true
      if CONFIGURATION and CONFIGURATION.features then
        if CONFIGURATION.features.hide_long_highlights and 
           CONFIGURATION.features.long_highlight_threshold and 
           highlightedText and #highlightedText > CONFIGURATION.features.long_highlight_threshold then
          should_show = false
        end
      end
      
      if should_show then
        result_text = _("__Highlighted text: __") .. "\"" .. highlightedText .. "\"\n\n"
      end
    end
    
    for i = 2, #message_history do
      if not message_history[i].is_context then
        if message_history[i].role == "user" then
          local user_content = message_history[i].content or _("(Empty message)")
          result_text = string.format("%s\n\n### ⮞ User: %s\n\n%s\n\n",
                                      result_text, title or "", truncateUserPrompt(user_content))
        else
          local assistant_content = message_history[i].content or _("(No response)")
          result_text = string.format("%s\n\n### ⮞ Assistant: %s\n\n%s\n\n",
                                      result_text, title or "", assistant_content)
        end
      end
    end
    return result_text
  end

  local last_user_message = message_history[#message_history - 1]
  local last_assistant_message = message_history[#message_history]

  if last_user_message and last_user_message.role == "user" and 
     last_assistant_message and last_assistant_message.role == "assistant" then
    -- Add nil checks for content
    local user_content = last_user_message.content or _("(Empty message)")
    local assistant_content = last_assistant_message.content or _("(No response)")
    return string.format("%s\n\n### ⮞ User: \n%s\n### ⮞ Assistant: %s\n\n%s\n",
                         previous_text, truncateUserPrompt(user_content), title or "", assistant_content)
  end

  return previous_text
end

-- Helper function to create and show ChatGPT viewer
local function createAndShowViewer(assitant, highlightedText, message_history, title, show_highlighted_text)
  local ui = assitant.ui
  show_highlighted_text = show_highlighted_text == nil and true or show_highlighted_text
  local result_text = createResultText(highlightedText, message_history, nil, show_highlighted_text, title)
  local render_markdown = (CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.render_markdown) or true
  local markdown_font_size = (CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.markdown_font_size) or 20
  
  local chatgpt_viewer = ChatGPTViewer:new {
    assitant = assitant,
    title = title,
    text = result_text,
    ui = ui,
    onAskQuestion = function(viewer, new_question, _title)
        Trapper:wrap(function()
          -- Use viewer's own highlighted_text value
          local current_highlight = viewer.highlighted_text or highlightedText
          local msg = handleFollowUpQuestion(message_history, new_question, ui, current_highlight)
          if msg ~= nil then
            message_history = msg
            local new_result_text = createResultText(current_highlight, message_history, viewer.text, false, _title)
            viewer:update(new_result_text)
            
            if viewer.scroll_text_w then
              viewer.scroll_text_w:resetScroll()
            end
          end
        end)
    end,
    highlighted_text = highlightedText,
    message_history = message_history,
    render_markdown = render_markdown,
    markdown_font_size = markdown_font_size,
  }
  
  UIManager:show(chatgpt_viewer)
  
  -- Refresh the screen after displaying the results
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.refresh_screen_after_displaying_results then
    UIManager:setDirty(nil, "full")
  end
end

-- Handle predefined prompt request
local function handlePredefinedPrompt(prompt_idx, highlightedText, ui, title)
  if not CONFIGURATION or not CONFIGURATION.features or not CONFIGURATION.features.prompts then
    return nil, "No prompts configured"
  end

  local prompt = CONFIGURATION.features.prompts[prompt_idx]
  if not prompt then
    return nil, "Prompt '" .. prompt_idx .. "' not found"
  end

  local user_content = formatUserPrompt(prompt.user_prompt, highlightedText, ui)
  
  local message_history = {
    {
      role = "system",
      content = prompt.system_prompt or "You are a helpful assistant."
    },
    {
      role = "user",
      content = user_content,
      is_context = true
    }
  }
  
  local answer, err = Querier:query(message_history, string.format("🌐 Loading %s ...", title or prompt_idx))
  if answer then
    table.insert(message_history, {
      role = "assistant",
      content = answer
    })
  end
  
  return message_history, err
end

-- Process main select popup buttons
-- ( custom prompts from configuration )
local function showProcCustomPrompt(assitant, highlightedText, prompt_index)
  local ui = assitant.ui
  if not Querier then
    Querier = assitant.querier
  end

  -- Check if Querier is initialized
  if not Querier:is_inited() then
    local ok, err = Querier:load_model(assitant:getModelProvider())
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end
  end

  local title = CONFIGURATION.features.prompts[prompt_index].text or prompt_index
  local message_history, err = handlePredefinedPrompt(prompt_index, highlightedText, ui, title)
  if err then
    UIManager:show(InfoMessage:new{text = err, icon = "notice-warning"})
    return
  end

  if not message_history or #message_history < 1 then
    UIManager:show(InfoMessage:new{text = _("Error: No response received"), icon = "notice-warning"})
    return
  end

  createAndShowViewer(assitant, highlightedText, message_history, title)
end

-- Main dialog function
local function showChatGPTDialog(assitant, highlightedText)
  local ui = assitant.ui
  if not Querier then
    Querier = assitant.querier
  end

  if input_dialog then
    UIManager:close(input_dialog)
    input_dialog = nil
  end

  -- Check if Querier is initialized
  if not Querier:is_inited() then
    local ok, err = Querier:load_model(assitant:getModelProvider())
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err})
        return
    end
  end

  -- When clicked [Assistant] button in main select popup,
  -- Or when activated from guesture (no text highlighted)

  -- Handle regular dialog (user input prompt, other buttons)
  local book = getBookContext(ui)
  local message_history = {{
    role = "system",
    content = CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.system_prompt or "You are a helpful assistant for reading comprehension."
  }}

  -- Create button rows (3 buttons per row)
  local button_rows = {}
  local all_buttons = {
    {
      text = _("Cancel"),
      id = "close",
      callback = function()
        if input_dialog then
          UIManager:close(input_dialog)
          input_dialog = nil
        end
      end
    },
    {
      text = _("Ask"),
      is_enter_default = true,
      callback = function()
        Trapper:wrap(function()
          local context_message = createContextMessage(ui, highlightedText)
          table.insert(message_history, context_message)

          local question_message = {
            role = "user",
            content = input_dialog:getInputText()
          }
          table.insert(message_history, question_message)

          -- Close input dialog and keyboard before querying
          if input_dialog then
            UIManager:close(input_dialog)
            input_dialog = nil
          end

          local answer, err = Querier:query(message_history)
          
          -- Check if we got a valid response
          if not answer or answer == "" or err ~= nil then
            UIManager:show(InfoMessage:new{
              icon = "notice-warning",
              text = "Error: " .. (err or ""),
              timeout = 3
            })
            return
          end
          
          local answer_message = {
            role = "assistant",
            content = answer
          }
          table.insert(message_history, answer_message)
          
          -- Create a contextual title
          local viewer_title = highlightedText and highlightedText ~= "" and 
            _("Text Analysis") or 
            book.title
        
          createAndShowViewer(assitant, highlightedText, message_history, viewer_title)
        end)
      end
    }
  }
  
  -- Only add additional buttons if there's highlighted text
  if highlightedText and highlightedText ~= "" then
    -- Add Dictionary button
    if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.dictionary_translate_to then
      table.insert(all_buttons, {
        text = _("Dictionary"),
        callback = function()
          if input_dialog then
            UIManager:close(input_dialog)
            input_dialog = nil
          end
          local showDictionaryDialog = require("dictdialog")
          Trapper:wrap(function()
            showDictionaryDialog(ui, highlightedText)
          end)
        end
      })  
    end

    -- Add custom prompt buttons
    if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.prompts then
      -- Create a sorted list of prompts
      local sorted_prompts = {}
      for prompt_index, prompt in pairs(CONFIGURATION.features.prompts) do
        table.insert(sorted_prompts, {idx = prompt_index, config = prompt})
      end
      -- Sort by order value, default to 1000 if not specified
      table.sort(sorted_prompts, function(a, b)
        local order_a = a.config.order or 1000
        local order_b = b.config.order or 1000
        return order_a < order_b
      end)
      
      -- Add buttons in sorted order
      for _, tab in ipairs(sorted_prompts) do
        table.insert(all_buttons, {
          text = tab.config.text,
          callback = function()
            if input_dialog then
              UIManager:close(input_dialog)
              input_dialog = nil
            end
            Trapper:wrap(function()
              -- Pass the assistant instance so showProcCustomPrompt can access querier and ui
              showProcCustomPrompt(assitant, highlightedText, tab.idx)
            end)
          end
        })
      end
    end
  end
  
  -- Organize buttons into rows of three
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

  -- Show the dialog with the button rows
  local dialog_title = highlightedText and highlightedText ~= "" and 
    _("Ask a question about the highlighted text") or 
    _("Ask a question about this book")
  
  local input_hint = highlightedText and highlightedText ~= "" and 
    _("Type your question here...") or 
    _("Ask anything about this book...")
  
  input_dialog = InputDialog:new{
    title = dialog_title,
    input_hint = input_hint,
    input_type = "text",
    buttons = button_rows,
    close_callback = function()
      if input_dialog then
        UIManager:close(input_dialog)
        input_dialog = nil
      end
    end,
    dismiss_callback = function()
      if input_dialog then
        UIManager:close(input_dialog)
        input_dialog = nil
      end
    end
  }
  
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

return {
  showChatGPTDialog = showChatGPTDialog,
  showProcCustomPrompt = showProcCustomPrompt,
}