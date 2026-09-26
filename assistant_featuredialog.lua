local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local InfoMessage = require("ui/widget/infomessage")
local Event = require("ui/event")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local koutil = require("util")
local ChatGPTViewer = require("assistant_viewer")
local assistant_prompts = require("assistant_prompts").assistant_prompts
local Prompts = require("assistant_prompts")
local ASUtils = require("assistant_utils")
local TextUtils = require("assistant_text_utils")
local DocUtils = require("assistant_doc_utils")
local NetUtils = require("assistant_net_utils")
local json = require("rapidjson")
local strbuf = require("string.buffer")
local extractBookTextForAnalysis = DocUtils.extractBookTextForAnalysis

local function extractHighlightsNotesAndNotebook(assistant, include_notebook)
    local ui = assistant and assistant.ui
    local highlights_and_notes = ""
    if ui and ui.annotation and ui.annotation.annotations then
        local buf = strbuf.new()
        buf:reset()
        for _i, annotation in ipairs(ui.annotation.annotations) do
            if annotation.text and annotation.text ~= "" then
                buf:put("Highlight: ", annotation.text, "\n")
            end
            if annotation.note and annotation.note ~= "" then
                buf:put("Note: ", annotation.note, "\n")
            end
            if annotation.chapter then
                buf:put("Chapter: ", annotation.chapter, "\n")
            end
            if annotation.pageno then
                buf:put("Page: ", annotation.pageno, "\n")
            end
            buf:put("\n")
        end
        highlights_and_notes = buf:get()
    end

    local notebook_content = ""
    if include_notebook then
      pcall(function()
          local notebookfile = ui.bookinfo:getNotebookFile(ui.doc_settings)
          if notebookfile then
              local file = io.open(notebookfile, "r")
              if file then
                  local content = file:read("*all")
                  file:close()
                  local success, data = pcall(json.decode, content)
                  if success and data then
                      notebook_content = "Notebook Data:\n" .. json.encode(data)
                  else
                      notebook_content = "Notebook Content (raw):\n" .. content
                  end
              end
          end
      end)
    end

    local combined = highlights_and_notes
    if notebook_content ~= "" then
        if combined ~= "" then
            combined = combined .. "\n--- Notebook Content ---\n" .. notebook_content
        else
            combined = notebook_content
        end
    end

    local max_text_length_for_analysis = assistant.config:getFeature("max_text_length_for_analysis", 100000)
    if #combined > max_text_length_for_analysis then
        combined = TextUtils.truncateToTailUtf8Safe(combined, max_text_length_for_analysis)
    end

    return combined
end

local function showFeatureDialog(assistant, feature_type, title, author, progress_percent, message_history, notebook_path)
    local Querier = assistant.querier
    local ui = assistant.ui

    -- Prefer already-loaded querier; fallback to getActiveProviderId.
    local provider = (assistant.querier and assistant.querier.provider_name
                      and assistant.querier:is_inited())
                     and assistant.querier.provider_name
                     or assistant.config:getActiveProviderId()
    if not provider then
        UIManager:show(InfoMessage:new{ icon = "notice-warning",
            text = _("No active provider configured. Please add one in Settings.") })
        return
    end
    local ok, err = Querier:load_model(provider)
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    local formatted_progress_percent = string.format("%.2f", progress_percent * 100)
    local feature_title, system_prompt, user_prompt_template, user_prompt_use_websearch, book_text, highlights_notes

    local language = assistant.settings:readSetting("response_language") or assistant.ui_language

    -- prompt config used for per-prompt show_suggestions decision
    local feature_prompt_config = nil
    if type(feature_type) == "table" then
        -- Custom feature from configuration
        local custom_config = feature_type
        feature_title = custom_config.text or _("Custom Prompt")
        system_prompt = custom_config.system_prompt
        user_prompt_template = custom_config.user_prompt
        user_prompt_use_websearch = koutil.tableGetValue(custom_config, "use_websearch") or false
        feature_prompt_config = custom_config

        -- Handle use flags
        book_text = nil
        highlights_notes = nil
        if custom_config.use_book_text and custom_config.use_book_text == true then
            book_text = extractBookTextForAnalysis(assistant)
        end
        if custom_config.use_highlight_with_notebook and custom_config.use_highlight_with_notebook == true then
            highlights_notes = extractHighlightsNotesAndNotebook(assistant, true)
        elseif custom_config.use_highlight_without_notebook and custom_config.use_highlight_without_notebook == true then
            highlights_notes = extractHighlightsNotesAndNotebook(assistant, false)
        end
    else
        -- Original feature type handling
        -- Feature type configurations for easy extension
        local feature_configurations = {
            recap = {
                -- @translators Feature name, short for "recapitulation": a brief spoiler-free summary of what the reader has already read, to refresh memory. Keep consistent with "AI Recaps" / "AI Recap" elsewhere.
                title = _("Recap"),
                config_key = "recap_config",
                prompts_key = "recap"
            },
            xray = {
                title = _("X-Ray"),
                config_key = "xray_config",
                prompts_key = "xray"
            },
            book_info = {
                title = _("Book Information"),
                config_key = "book_info_config",
                prompts_key = "book_info"
            },
            annotations = {
                title = _("Highlight & Note Analysis"),
                config_key = "annotations_config",
                prompts_key = "annotations"
            },
            summary_using_annotations = {
                title = _("Summary Using Highlights & Notes"),
                config_key = "summary_using_annotations_config",
                prompts_key = "summary_using_annotations"
            }
        }
        
        -- Get feature configuration
        local feature_config = feature_configurations[feature_type]
        if not feature_config then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = TextUtils.bold_format(
                    T(_("<b>Unknown feature type:</b> %1"), tostring(feature_type))
                ),
            })
            return
        end
        
        feature_title = feature_config.title
        local config_key = feature_config.config_key
        local prompts_key = feature_config.prompts_key
        
        -- Get feature config with fallbacks
        local file_config = assistant.config:getFeature(config_key) or {}
        
        -- Prompts for feature (from config or prompts.lua)
        system_prompt = koutil.tableGetValue(file_config, "system_prompt")
            or koutil.tableGetValue(assistant_prompts, prompts_key, "system_prompt")

        user_prompt_template = koutil.tableGetValue(file_config, "user_prompt")
            or koutil.tableGetValue(assistant_prompts, prompts_key, "user_prompt")

        user_prompt_use_websearch = koutil.tableGetValue(file_config, "use_websearch")
            or koutil.tableGetValue(assistant_prompts, prompts_key, "use_websearch")

        book_text = nil
        highlights_notes = nil
        if feature_type == "xray" or feature_type == "recap" then
          if assistant.settings:readSetting("use_book_text_for_analysis", false) then
            book_text = extractBookTextForAnalysis(assistant)
          end
        elseif feature_type == "annotations" then
          highlights_notes = extractHighlightsNotesAndNotebook(assistant, true)
        elseif feature_type == "summary_using_annotations" then
          book_text = extractBookTextForAnalysis(assistant)
          highlights_notes = extractHighlightsNotesAndNotebook(assistant, false)
        end
        -- build effective prompt config for show_suggestions (file override > builtin)
        local builtin_cfg = assistant_prompts[prompts_key] or {}
        feature_prompt_config = {}
        for k, v in pairs(builtin_cfg) do
            feature_prompt_config[k] = v
        end
        if file_config.show_suggestions ~= nil then
            feature_prompt_config.show_suggestions = file_config.show_suggestions
        end
    end

    local ws_enabled = Prompts.isWebSearchEnabled(assistant.settings)
    feature_title = Prompts.getDisplayText(feature_title, user_prompt_use_websearch or false, ws_enabled)

    if Prompts.isSuggestionsEnabled(assistant.settings, feature_prompt_config) then
      system_prompt = system_prompt .. assistant_prompts.suggestions_prompt
    end
    
    local book_text_prompt = ""
    if book_text then
        book_text_prompt = string.format("\n\n[! IMPORTANT !] Here is the book text up to my current position, only consider this text for your response:\n [BOOK TEXT BEGIN]\n%s\n[BOOK TEXT END]", book_text)
    end

    local highlights_notes_prompt = ""
    if highlights_notes and highlights_notes ~= "" then
        highlights_notes_prompt = string.format("\n\n[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN]\n%s\n[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT END]", highlights_notes)
    end

    local message_history = message_history or {
        {
            role = "system",
            content = system_prompt,
        },
    }
    
    -- Format the user prompt with variables
    local user_content = user_prompt_template:gsub("{([%w_]+)}", {
      title = title,
      author = author,
      progress = formatted_progress_percent,
      language = language,
      koreader_version = Prompts.getKoreaderVersion()
    })

    user_content = user_content .. book_text_prompt .. highlights_notes_prompt
    
    local context_message = {
        role = "user",
        content = user_content,
    }
    ASUtils.set_attr(context_message, "use_websearch", user_prompt_use_websearch)
    ASUtils.set_attr(context_message, "prompt_title", feature_title)
    ASUtils.set_attr(context_message, "show_suggestions", Prompts.isSuggestionsEnabled(assistant.settings, feature_prompt_config))
    table.insert(message_history, context_message)

    local function createResultText()

      local header_text = T(_([[
 - Title : %1
 - Author: %2
 - Reading progress: %3%

-----

]]), title, author, formatted_progress_percent)

      -- Walk the history past the system prompt, skipping context messages;
      -- each remaining message goes through the shared formatter, so Search
      -- divs (search_keywords the querier appended in place) render.
      -- The header above is emitted once; follow-ups append below instead.
      -- Minimalist mode assembles the answer-only shape (no carriers).
      local minimal = assistant.settings:readSetting("minimalist_mode", false)
      local result_parts = { header_text }
      for idx = 2, #message_history do
        local message = message_history[idx]
        local is_context = ASUtils.get_attr(message, "is_context")
        if not is_context then
          table.insert(result_parts, TextUtils.formatSingleMessage(message_history, message, {
            title = nil,
            msg_idx = idx,
            settings = assistant.settings,
            default_config = feature_prompt_config,
            minimal = minimal,
          }))
        end
      end
      return table.concat(result_parts)
    end

    local function prepareMessageHistoryForAdditionalQuestion(message_history, user_question, use_websearch)
      local context = {
        role = "user",
        content = user_question
      }
      ASUtils.set_attr(context, "use_websearch", use_websearch or false)
      ASUtils.set_attr(context, "show_suggestions", Prompts.isSuggestionsEnabled(assistant.settings, feature_prompt_config))
      table.insert(message_history, context)
    end

    local answer, err = Querier:query(message_history, feature_title)
    if err then
      assistant.querier:showError(err, message_history)
      return
    end

    do
      local assistant_msg = {
        role = "assistant",
        content = answer
      }
      ASUtils.set_attr(assistant_msg, "show_suggestions", Prompts.isSuggestionsEnabled(assistant.settings, feature_prompt_config))
      table.insert(message_history, assistant_msg)
    end

    local chatgpt_viewer
    chatgpt_viewer = ChatGPTViewer:new {
      assistant = assistant,
      ui = ui,
      title = feature_title,
      text = createResultText(),
      is_show_addnote = false,
      message_history = message_history,
      notebook_path = notebook_path,
      onAskQuestion = function(viewer, user_question, use_websearch)
        local viewer_title = ""

        if type(user_question) == "string" then
          prepareMessageHistoryForAdditionalQuestion(message_history, user_question, use_websearch)
        elseif type(user_question) == "table" then
          viewer_title = user_question.text or "Custom Prompt"
          local raw_followup = user_question.user_prompt or user_question
          -- Expand {title}/{author}/{progress}/{language}/{user_input} so custom templates don't leak raw placeholders
          local expanded_followup = raw_followup:gsub("{([%w_]+)}", {
            title = title,
            author = author,
            progress = formatted_progress_percent,
            language = language,
            user_input = user_question.user_input or "",
            koreader_version = Prompts.getKoreaderVersion(),
          })
          do
            local followup_user = {
              role = "user",
              content = expanded_followup
            }
            ASUtils.set_attr(followup_user, "use_websearch", user_question.use_websearch or false)
            ASUtils.set_attr(followup_user, "show_suggestions", Prompts.isSuggestionsEnabled(assistant.settings, feature_prompt_config))
            ASUtils.set_attr(followup_user, "prompt_title", viewer_title)
            table.insert(message_history, followup_user)
          end
        end

        viewer:trimMessageHistory()
        NetUtils.runWhenOnlineFast(function()
          Trapper:wrap(function()
            local answer, err = Querier:query(message_history, viewer_title ~= "" and viewer_title or feature_title)
            
            if err then
              Querier:showError(err, message_history)
              return
            end
            
            do
              local assistant_msg = {
                role = "assistant",
                content = answer
              }
              ASUtils.set_attr(assistant_msg, "show_suggestions", Prompts.isSuggestionsEnabled(assistant.settings, feature_prompt_config))
              table.insert(message_history, assistant_msg)
            end
            local last_user_message = message_history[#message_history - 1]
            local last_assistant_message = message_history[#message_history]
            -- Format the two new trailing messages through the shared
            -- formatter (suggestions resolved from the message attrs); the
            -- new answer is processed exactly once.
            local minimal = assistant.settings:readSetting("minimalist_mode", false)
            local additional_text = "---\n\n"
                .. TextUtils.formatSingleMessage(message_history, last_user_message, {
                  title = nil,
                  msg_idx = #message_history - 1,
                  settings = assistant.settings,
                  default_config = feature_prompt_config,
                  minimal = minimal,
                })
                .. TextUtils.formatSingleMessage(message_history, last_assistant_message, {
                  title = nil,
                  msg_idx = #message_history,
                  settings = assistant.settings,
                  default_config = feature_prompt_config,
                  minimal = minimal,
                })
            viewer:update(viewer.text .. additional_text)
            
            if viewer.scroll_text_w then
              viewer.scroll_text_w:resetScroll()
            end
          end)
        end)
      end,
      -- Re-assemble the transcript so a display switch in the viewer's menu
      -- can hide what it just turned off.
      rebuild_text = function()
        return createResultText()
      end,
      default_hold_callback = function ()
        chatgpt_viewer:HoldClose()
      end,
    }

    UIManager:show(chatgpt_viewer)
end

return showFeatureDialog
