-- Directory determination for dofile removed, using require now

-- Load configuration using dofile
local plugin_config = nil
-- Try loading configuration using require, fallback to nil
local config_ok_dialogs, config_result_dialogs = pcall(require, "configuration")
if config_ok_dialogs then
    plugin_config = config_result_dialogs
else
    if logger then
        local log_msg = config_result_dialogs
        if type(log_msg) == "table" then log_msg = "(table data omitted for security)" end
        logger.info("Dialogs: configuration.lua not found or error loading via require:", log_msg)
    end
    plugin_config = nil -- Ensure it's nil if loading failed
end

-- Load required modules (moved to top for clarity)
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

-- Helper function to generate a topic for the conversation based on initial prompt
local function generateConversationTopic(highlightedText, userPromptContent)
    if not userPromptContent or userPromptContent == "" then return nil end

    local topic_prompt_text = _("Summarize the topic of this request in maximum 5 words: ")
    local context_for_topic = ""
    if highlightedText and highlightedText ~= "" then
        context_for_topic = context_for_topic .. "\nContext: " .. highlightedText
    end
    context_for_topic = context_for_topic .. "\nRequest: " .. userPromptContent

    local topic_history = {
        { role = "system", content = "You are an expert at summarizing requests concisely." },
        { role = "user", content = topic_prompt_text .. context_for_topic }
    }

    local provider_name_topic = getActiveProvider()
    -- Use queryChatGPT directly, assuming it's globally accessible or required earlier
    local topic_answer = queryChatGPT(topic_history, provider_name_topic, true) -- Pass true for is_topic_generation

    if topic_answer and not topic_answer:match("^Error:") and topic_answer:match("%S") then -- Check for non-empty, non-error
        -- Basic cleanup
        topic_answer = topic_answer:gsub('^"', ''):gsub('"$', ''):gsub("^%s+", ""):gsub("%s+$", "")
        -- Limit words
        local words = {}
        for word in topic_answer:gmatch("%S+") do table.insert(words, word) end
        if #words > 5 then
            topic_answer = table.concat(words, " ", 1, 5) .. "..."
        end
        if logger then logger.info("Generated topic:", topic_answer) end
        return topic_answer
    else
        if logger then logger.warn("Failed to generate topic:", topic_answer) end
        return nil
    end
end
local DataStorage = require("datastorage") -- Used for paths
local LuaSettings = require("luasettings") -- Used for reading/writing settings
local DataStorage = require("datastorage") -- Ensure DataStorage is required at the top level
local logger = require("logger")
local ChatGPTViewer = require("chatgptviewer")
local queryChatGPT = require("gpt_query")
local Screen = require("device").screen

-- Module table to export functions (needed for helpers used elsewhere)
local M = {}

-- Helper function to get active provider (duplicated from main.lua)
local function getActiveProvider()
    -- Use top-level DataStorage
    local path_dlg = nil
    -- Safely get settings dir path
    if DataStorage and DataStorage.getSettingsDir then -- Use top-level DataStorage
        local settings_dir = DataStorage:getSettingsDir()
        if settings_dir then path_dlg = settings_dir .. "/assistant_settings.lua" end
    end

    local active_provider_dlg = "gemini" -- Default
    if path_dlg then
        local settings_store = LuaSettings:open(path_dlg)
        -- readSetting returns nil if key doesn't exist or file doesn't exist
        local settings = settings_store:readSetting("assistant_config") or {}
        if type(settings) == "table" then
            active_provider_dlg = settings.active_provider or active_provider_dlg
        else
            if logger then logger.warn("getActiveProvider (dialogs): Could not read valid settings") end
        end
    elseif logger then
         logger.warn("getActiveProvider (dialogs): Could not get settings path.")
    end

    -- Fallback to global config
    active_provider_dlg = active_provider_dlg or (plugin_config and plugin_config.provider) or "gemini"
    return active_provider_dlg
end
local buttons, input_dialog = nil, nil


-- Common helper functions
local function showLoadingDialog()
  local loading_dialog = InfoMessage:new{
    text = _("Querying AI..."), -- Consistent text
    timeout = nil -- Keep it visible until closed
  }
  UIManager:show(loading_dialog)
  return loading_dialog -- Return the widget
end

-- Helper function to truncate text based on configuration
local function truncateUserPrompt(text)
  if not plugin_config or not plugin_config.features or not plugin_config.features.max_display_user_prompt_length then
    return text
  end
  
  local max_length = plugin_config.features.max_display_user_prompt_length
  if max_length <= 0 then
    return text
  end
  
  if text and #text > max_length then
    return text:sub(1, max_length) .. "..."
  end
  return text
end

-- Export this helper
local function getBookContext(ui) -- Make local again
  local title = _("Unknown Title")
  local author = _("Unknown Author")
  -- Check if ui and ui.document exist before accessing properties
  if ui and ui.document and type(ui.document.getProps) == "function" then
      local props = ui.document:getProps()
      if props then
          title = props.title or title
          author = props.authors or author
      end
  end
  return { title = title, author = author }
end

local function createContextMessage(ui, highlightedText)
  local book = getBookContext(ui)
  return {
    role = "user",
    content = "I'm reading something titled '" .. book.title .. "' by " .. book.author ..
      ". I have a question about the following highlighted text: " .. highlightedText,
    is_context = true
  }
end

local function handleFollowUpQuestion(message_history, new_question, ui, highlightedText)
  local context_message = createContextMessage(ui, highlightedText)
  table.insert(message_history, context_message)

  local question_message = {
    role = "user",
    content = new_question
  }
  table.insert(message_history, question_message)

  local answer = queryChatGPT(message_history)
  local answer_message = {
    role = "assistant",
    content = answer
  }
  table.insert(message_history, answer_message)

  return message_history
end

-- Export this helper
local function createResultText(highlightedText, message_history, previous_text, show_highlighted_text) -- Make local again
  if not previous_text then
    local result_text = ""
    -- Check if we should show highlighted text based on configuration
    if show_highlighted_text and
       ((not plugin_config or
        not plugin_config.features or
        not plugin_config.features.hide_highlighted_text)) then
      
      -- Check for long text
      local should_show = true
      if plugin_config and plugin_config.features then
        if plugin_config.features.hide_long_highlights and
           plugin_config.features.long_highlight_threshold and
           #highlightedText > plugin_config.features.long_highlight_threshold then
          should_show = false
        end
      end
      
      if should_show then
        result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
      end
    end
    
    for i = 2, #message_history do -- Start from 2 to skip system prompt
        if not message_history[i].is_context then
            local msg = message_history[i]
            local content = msg.content or ""
            local is_error = content:match("^Error:") or content:match("^%a+ API Error")
            local is_last_message = (i == #message_history)

            -- Only add assistant messages if they are NOT errors,
            -- UNLESS it's the very last message (which can be an error).
            local should_add_assistant_msg = (msg.role == "assistant" and (not is_error or is_last_message))
            
            if msg.role == "user" then
                result_text = result_text .. "⮞ " .. _("User: ") .. truncateUserPrompt(content) .. "\n"
            elseif should_add_assistant_msg then
                local prefix = (plugin_config and plugin_config.features and plugin_config.features.show_assistant_prefix) and "Assistant: " or ""
                result_text = result_text .. "⮞ " .. prefix .. content .. "\n\n"
            end
            -- Otherwise (assistant error that is not the last message), skip it.
        end
    end
    return result_text
end -- End of createResultText function

  -- This part seems redundant now as the loop handles everything
  -- local last_user_message = message_history[#message_history - 1]
  -- local last_assistant_message = message_history[#message_history]
  -- ... (rest of the old block removed)

  return previous_text
end

-- Helper function to create and show ChatGPT viewer
local function createAndShowViewer(ui, highlightedText, message_history, title, show_highlighted_text, generated_topic) -- Added generated_topic parameter
  show_highlighted_text = show_highlighted_text == nil and true or show_highlighted_text
  local result_text = createResultText(highlightedText, message_history, nil, show_highlighted_text)
  if logger then
      logger.info("Dialogs:createAndShowViewer - title:", title)
      logger.info("Dialogs:createAndShowViewer - highlightedText type:", type(highlightedText))
      logger.info("Dialogs:createAndShowViewer - message_history type:", type(message_history))
      if type(message_history) == "table" then
          logger.info("Dialogs:createAndShowViewer - message_history length:", #message_history)
      end
  end
  
  local chatgpt_viewer = ChatGPTViewer:new {
    title = _(title), -- Keep original title for the window bar
    text = result_text,
    ui = ui,
    message_history = message_history,
    highlighted_text = highlightedText,
    created_timestamp = os.time(),
    is_saved = false,
    topic = generated_topic, -- Pass the generated topic
    onAskQuestion = function(viewer, new_question)
      NetworkMgr:runWhenOnline(function()
        -- Use viewer's own highlighted_text value
        -- Ensure the viewer still exists before updating it
        if viewer and viewer.movable then
            local current_highlight = viewer.highlighted_text -- Use the highlight stored in the viewer
            -- Pass the viewer's current message history to the follow-up function
            -- Create a shallow copy of the viewer's history before passing it
            local history_copy = {}
            if viewer.message_history then
                for _, v in ipairs(viewer.message_history) do table.insert(history_copy, v) end
            end
            local updated_history = handleFollowUpQuestion(history_copy, new_question, ui, current_highlight)
            
            -- Regenerate the full text based ONLY on the updated history
            -- Pass nil for highlightedText and false for show_highlighted_text to avoid duplication
            local new_result_text = createResultText(nil, updated_history, nil, false)
            
            -- Update the viewer's text content
            viewer:update(new_result_text)
            
            -- Update the viewer's history state
            viewer.message_history = updated_history

            -- Automatically update the saved entry if this conversation was loaded from history
            if viewer.is_saved then
                -- Check if the update function exists before calling
                if viewer.updateSavedConversation then
                    viewer:updateSavedConversation()
                else
                    if logger then logger.warn("Dialogs: viewer:updateSavedConversation() method not found.") end
                end
            end

            if viewer.scroll_text_w then
              viewer.scroll_text_w:resetScroll()
            end
        else
            if logger then logger.warn("Dialogs: Viewer was nil when trying to update after prompt button click.") end
        end
      end)
    end,
    highlighted_text = highlightedText,
    message_history = message_history
  }
  
  UIManager:show(chatgpt_viewer)
  
  -- Refresh the screen after displaying the results
  if plugin_config and plugin_config.features and plugin_config.features.refresh_screen_after_displaying_results then
    UIManager:setDirty(nil, "full")
  end
end

  local function handlePredefinedPrompt(prompt_type, highlightedText, ui_ctx) -- Renamed ui to ui_ctx for clarity
    -- Reload config *inside* the function for safety
    local current_config = nil
    local config_ok, config_result = pcall(function() return dofile(config_path_dialogs) end)
    if config_ok then
        current_config = config_result
    else
        if logger then logger.error("handlePredefinedPrompt: Failed to reload config:", config_result) end
        return nil, "Configuration error"
    end

    -- Robust checks at the beginning using reloaded config
    if not current_config or not current_config.features or not current_config.features.prompts then
        if logger then logger.error("handlePredefinedPrompt: Config invalid or missing prompts section.") end
        return nil, "No prompts configured"
    end
    if logger then logger.info("handlePredefinedPrompt: Looking for prompt_type:", prompt_type) end
    local prompt = current_config.features.prompts[prompt_type]
    if not prompt then
        if logger then logger.error("handlePredefinedPrompt: Prompt not found for type:", prompt_type) end
        return nil, "Prompt '" .. tostring(prompt_type or "nil") .. "' not found in configuration"
    end
    if logger then logger.info("handlePredefinedPrompt: Found prompt:", prompt.text) end

    local book = getBookContext(ui_ctx)
    -- Check if prompt.user_prompt exists before using it
    if not prompt.user_prompt then
        if logger then logger.error("handlePredefinedPrompt: prompt.user_prompt is nil for prompt:", prompt_type) end
        return nil, "Prompt configuration error (missing user_prompt)"
    end

  local book = getBookContext(ui)
  local formatted_user_prompt = (prompt.user_prompt or "Please analyze: ")
    :gsub("{title}", book.title)
    :gsub("{author}", book.author)
    :gsub("{highlight}", highlightedText)
  
  local user_content = ""
  if string.find(prompt.user_prompt or "Please analyze: ", "{highlight}") then
    user_content = formatted_user_prompt
  else
    user_content = formatted_user_prompt .. highlightedText
  end
  
  local message_history = {
    {
      role = "system",
      content = (prompt.system_prompt or "You are a helpful assistant.") .. "\n\nStart your response with 'Topic: [Summarize request topic in max 5 words]' followed by a newline, then provide the main answer."
    },
    {
      role = "user",
      content = user_content,
      is_context = true
    }
  }
  
  -- Generate topic before the main query
  local generated_topic = generateConversationTopic(highlightedText, user_content)

  -- Use top-level DataStorage
  if logger then logger.info("handlePredefinedPrompt: Required DataStorage locally. Type:", type(DataStorage_local)) end
  local provider_name = getActiveProvider() -- Get current provider
  local answer = queryChatGPT(message_history, provider_name) -- Pass provider name
  local generated_topic = nil -- Initialize topic
  if answer then
    -- Try to extract topic
    local topic_str = answer:match("^Topic:(.-)\n")
    if topic_str then
        generated_topic = topic_str:gsub("^%s+", ""):gsub("%s+$", "") -- Trim whitespace
        -- Remove topic line from the actual answer
        answer = answer:gsub("^Topic:.*\n\n", "", 1)
        if logger then logger.info("handlePredefinedPrompt: Extracted topic:", generated_topic) end
    else
        if logger then logger.warn("handlePredefinedPrompt: Could not extract topic from answer.") end
    end
    table.insert(message_history, {
      role = "assistant",
      content = answer -- Add cleaned answer
      -- We don't store the topic in the message history itself
    })
  end
  
  return message_history, nil
end

-- Main dialog function
local function showChatGPTDialog(ui, highlightedText, direct_prompt)
  if input_dialog then
    UIManager:close(input_dialog)
    input_dialog = nil

    -- Define helper functions within the scope where they are used by callbacks
    local function showLoadingDialog()
        UIManager:show(InfoMessage:new{ text = _("Querying AI..."), timeout = nil })
    end

    local function createAndShowViewer(ui_ctx, h_text, msg_hist, title_text, show_h_text)
        show_h_text = show_h_text == nil and true or show_h_text
        local result_text = createResultText(h_text, msg_hist, nil, show_h_text)
        local chatgpt_viewer = ChatGPTViewer:new {
            title = _(title_text),
            text = result_text,
            ui = ui_ctx,
            onAskQuestion = function(viewer, new_question)
                NetworkMgr:runWhenOnline(function()
                    if viewer and viewer.movable then
                        local current_highlight = viewer.highlighted_text or h_text
                        -- Need handleFollowUpQuestion defined or accessible here too
                        local updated_history = handleFollowUpQuestion(msg_hist, new_question, ui_ctx, current_highlight)
                        local new_result_text = createResultText(current_highlight, updated_history, viewer.text, false)
                        viewer:update(new_result_text)
                        if viewer.scroll_text_w then viewer.scroll_text_w:resetScroll() end
                    else
                        if logger then logger.warn("Dialogs: Viewer was nil when trying to update after prompt button click.") end
                    end
                end)
            end,
            highlighted_text = h_text,
            message_history = msg_hist
        }
        UIManager:show(chatgpt_viewer)
        if plugin_config and plugin_config.features and plugin_config.features.refresh_screen_after_displaying_results then
            UIManager:setDirty(nil, "full")
        end
    end


    -- Need handleFollowUpQuestion defined here as well
    local function handleFollowUpQuestion(current_history, new_question, ui_ctx, h_text)
        -- Check if the last message was an error
        local last_msg = current_history[#current_history]
        local use_original_context = last_msg and last_msg.role == "assistant" and last_msg.content and (
            last_msg.content:match("^Error:") or last_msg.content:match("^%a+ API Error")
        )

        if use_original_context then
            -- Remove the error message
            table.remove(current_history)
            -- Add a new user message combining original highlight and new question
            -- We need to know the actual prompt text (e.g., "Explain") here, not just new_question
            -- For now, let's just use the new_question but ideally pass the prompt text
            local combined_content = string.format("Context: \"%s\"\n\nFollow-up: %s", h_text or "", new_question)
            table.insert(current_history, { role = "user", content = combined_content })
            if logger then logger.info("handleFollowUpQuestion: Last message was error, using original context.") end
        else
            -- Add the new user question normally
            table.insert(current_history, { role = "user", content = new_question })
        end
        -- Query the AI
        -- Use top-level DataStorage
        local provider_name_followup = getActiveProvider() -- Get current provider
        local answer = queryChatGPT(current_history, provider_name_followup) -- Pass provider name
        if answer then
            table.insert(current_history, { role = "assistant", content = answer })
        else
            -- Handle error, maybe add an error message to history?
            table.insert(current_history, { role = "assistant", content = _("Error: No response from AI.") })
        end
        return current_history
    end
  end

  -- Handle direct prompts ( custom)
  if direct_prompt then
    local loading_dialog = showLoadingDialog() -- Store the dialog
  -- Removed debug log for plugin_config
    UIManager:scheduleIn(0.1, function()
      -- Reload config inside the callback to ensure it's available
      local reloaded_config = nil
      local success_reload, result_reload = pcall(function() return dofile(config_path_dialogs) end)
      if success_reload then
          reloaded_config = result_reload
      else
          print("Dialogs (callback): Failed to reload configuration.lua:", result_reload)
          UIManager:show(InfoMessage:new{text = _("Error reloading configuration.")})
          return
      end
      -- Use reloaded_config from here on in this callback
      plugin_config = reloaded_config -- Overwrite the module-level variable for simplicity within this scope
      local message_history, err

      local title

      -- Call handlePredefinedPrompt which now returns the topic
      local generated_topic -- Declare topic variable
      message_history, err, generated_topic = handlePredefinedPrompt(direct_prompt, highlightedText, ui)
      if err then
        if loading_dialog then UIManager:close(loading_dialog) end
        UIManager:show(InfoMessage:new{text = _("Error: " .. err)})
        return
      end
      
      -- Determine title based on prompt type or default
      local title = (plugin_config and plugin_config.features.prompts[direct_prompt] and plugin_config.features.prompts[direct_prompt].text) or "Assistant"
      title = _(title) -- Translate title

      if not message_history or #message_history < 1 then
         if loading_dialog then UIManager:close(loading_dialog) end
         UIManager:show(InfoMessage:new{text = _("Error: No response received")})
         return
      end

      if loading_dialog then UIManager:close(loading_dialog) end
      -- Pass the generated topic to createAndShowViewer
      createAndShowViewer(ui, highlightedText, message_history, title, true, generated_topic)
    end)
    return
  end

  -- Handle regular dialog with buttons
  local book = getBookContext(ui)
  local message_history = {{
    role = "system",
    content = (plugin_config and plugin_config.features and plugin_config.features.system_prompt or "You are a helpful assistant for reading comprehension.") .. "\n\nStart your response with 'Topic: [Summarize request topic in max 5 words]' followed by a newline, then provide the main answer."
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
        local question_text = input_dialog:getInputText()
        if not question_text or question_text:match("^%s*$") then
            UIManager:show(InfoMessage:new{ text = _("Please enter a question.") })
            return -- Stop if question is empty
        end
        local loading_dialog_ask = showLoadingDialog() -- Store the dialog
        UIManager:scheduleIn(0.1, function()
          local context_message = createContextMessage(ui, highlightedText)
          table.insert(message_history, context_message)

          local question_message = {
            role = "user",
            content = question_text -- Use the validated question text
          }
          table.insert(message_history, question_message)

          -- Generate topic before the main query
          local generated_topic = generateConversationTopic(highlightedText, question_text)
          
          local answer = queryChatGPT(message_history)
          local generated_topic = nil -- Initialize topic
          if answer then
              -- Try to extract topic
              local topic_str = answer:match("^Topic:(.-)\n")
              if topic_str then
                  generated_topic = topic_str:gsub("^%s+", ""):gsub("%s+$", "") -- Trim whitespace
                  -- Remove topic line from the actual answer
                  answer = answer:gsub("^Topic:.*\n\n", "", 1)
                  if logger then logger.info("Ask Callback: Extracted topic:", generated_topic) end
              else
                   if logger then logger.warn("Ask Callback: Could not extract topic from answer.") end
              end
          end
          local answer_message = {
            role = "assistant",
            content = answer or _("Error: No response received") -- Use cleaned answer or error
            -- We don't store the topic in the message history itself
          }
          table.insert(message_history, answer_message)

          -- Close input dialog and keyboard before showing the viewer
          if input_dialog then
            UIManager:close(input_dialog)
            input_dialog = nil
          end
          
          if loading_dialog_ask then UIManager:close(loading_dialog_ask) end -- Close loading dialog
          -- Pass the generated topic to createAndShowViewer
          createAndShowViewer(ui, highlightedText, message_history, generated_topic or "Assistant", true, generated_topic)
        end)
      end
    }
  }
  
  -- Add Dictionary button
  if plugin_config and plugin_config.features and plugin_config.features.dictionary_translate_to then
    table.insert(all_buttons, {
      text = _("Dictionary"),
      callback = function()
        if input_dialog then
          UIManager:close(input_dialog)
          input_dialog = nil
        end
        local loading_dialog_prompt = showLoadingDialog() -- Store the dialog
        UIManager:scheduleIn(0.1, function()
          local showDictionaryDialog = require("dictdialog")
          showDictionaryDialog(ui, highlightedText)
        end)
      end
    })  
  end


  -- Add custom prompt buttons
  if plugin_config and plugin_config.features and plugin_config.features.prompts then
    -- Create a sorted list of prompts
    local sorted_prompts = {}
    for prompt_type, prompt in pairs(plugin_config.features.prompts) do
      table.insert(sorted_prompts, {type = prompt_type, config = prompt})
    end
    -- Sort by order value, default to 1000 if not specified
    table.sort(sorted_prompts, function(a, b)
      local order_a = a.config.order or 1000
      local order_b = b.config.order or 1000
      return order_a < order_b
    end)
    
    -- Add buttons in sorted order
    for idx, prompt_data in ipairs(sorted_prompts) do
      local prompt_type = prompt_data.type
      local prompt = prompt_data.config
      table.insert(all_buttons, {
        text = _(prompt.text), -- Translate button text
        callback = function()
          -- Close the input dialog
          if input_dialog then
              UIManager:close(input_dialog)
              input_dialog = nil
          end
          -- Show loading indicator (using local function defined in showChatGPTDialog)
          -- Show loading indicator FIRST
          local loading_dialog_prompt = showLoadingDialog()
          
          UIManager:scheduleIn(0.1, function()
              -- Reload config inside the callback
              local current_config = nil
              local config_ok, config_result = pcall(require, "configuration") -- Use require
              if config_ok then
                  current_config = config_result
              else
                  if logger then
                      local log_msg = config_result
                      if type(log_msg) == "table" then log_msg = "(table data omitted for security)" end
                      logger.error("Initial Prompt Callback: Failed to reload config via require:", log_msg)
                  end
                  if loading_dialog_prompt then UIManager:close(loading_dialog_prompt) end -- Close loading dialog on error
                  UIManager:show(InfoMessage:new{text = _("Error reloading configuration.")})
                  return -- Stop execution
              end
              
              -- Check for prompt AFTER loading config
              local prompt = current_config and current_config.features and current_config.features.prompts and current_config.features.prompts[prompt_type]
              if not prompt then
                  if loading_dialog_prompt then UIManager:close(loading_dialog_prompt) end -- Close loading dialog on error
                  UIManager:show(InfoMessage:new{text = _("Error: Prompt not found")})
                  return -- Stop execution
              end
              
              -- Prepare message history (logic from handlePredefinedPrompt)
              local book = getBookContext(ui) -- Use helper defined in outer scope
              local formatted_user_prompt = (prompt.user_prompt or "Please analyze: ")
                  :gsub("{title}", book.title)
                  :gsub("{author}", book.author)
                  :gsub("{highlight}", highlightedText)
              local user_content = (string.find(prompt.user_prompt or "", "{highlight}")) and formatted_user_prompt or (formatted_user_prompt .. highlightedText)

              local initial_history = {
                  { role = "system", content = (prompt.system_prompt or "You are a helpful assistant.") .. "\n\nStart your response with 'Topic: [Summarize request topic in max 5 words]' followed by a newline, then provide the main answer." },
                  { role = "user", content = user_content, is_context = true }
              }
              
              -- Get provider and call queryChatGPT
              local provider_name = getActiveProvider() -- Use helper defined in outer scope
              local answer = queryChatGPT(initial_history, provider_name) -- Pass provider name

              -- Process answer
              local message_history_result
              if answer and string.sub(answer, 1, 7) ~= "Error: " then -- Check for actual errors from queryChatGPT
                  table.insert(initial_history, { role = "assistant", content = answer })
                  message_history_result = initial_history
              else
                  if loading_dialog_prompt then UIManager:close(loading_dialog_prompt) end -- Close loading dialog on error
                  UIManager:show(InfoMessage:new{text = answer or _("Error: No response from AI")}) -- Show specific error if available
                  return -- Stop if no answer or error
              end

              -- Show viewer (logic from createAndShowViewer)
              local title_text = prompt.text
              local show_h_text = true -- Show original highlight for initial prompts
              if loading_dialog_prompt then UIManager:close(loading_dialog_prompt) end -- Close loading dialog before showing viewer
              createAndShowViewer(ui, highlightedText, message_history_result, title_text, show_h_text) -- Use helper defined in outer scope
          end)
        end
      })
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
  input_dialog = InputDialog:new{
    title = _("Ask a question about the highlighted text"),
    input_hint = _("Type your question here..."),
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

-- Export necessary functions in a table
local M = {}
M.showChatGPTDialog = showChatGPTDialog
M.getBookContext = getBookContext
M.createResultText = createResultText
-- Do NOT export the other helpers like showLoadingDialog, handlePredefinedPrompt etc.
return M
