local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("assistant_viewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Event = require("ui/event")
local koutil = require("util")
local dict_prompts = require("assistant_prompts").assistant_prompts.dict

local function showDictionaryDialog(assistant, highlightedText, message_history, prompt_type)
    local CONFIGURATION = assistant.CONFIGURATION
    local Querier = assistant.querier
    local ui = assistant.ui

    -- Check if Querier is initialized
    local ok, err = Querier:load_model(assistant:getModelProvider())
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    -- Handle case where no text is highlighted (gesture-triggered)
    local input_dialog
    if not highlightedText or highlightedText == "" then
        -- Show a simple input dialog to ask for a word to look up
        input_dialog = InputDialog:new{
            title = _("AI Dictionary"),
            input_hint = _("Enter a word to look up..."),
            input_type = "text",
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(input_dialog)
                        end,
                    },
                    {
                        text = _("Look Up"),
                        is_enter_default = true,
                        callback = function()
                            local word = input_dialog:getInputText()
                            UIManager:close(input_dialog)
                            if word and word ~= "" then
                                -- Recursively call with the entered word
                                showDictionaryDialog(assistant, word, message_history)
                            end
                        end,
                    },
                }
            }
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
        return
    end

    local message_history = message_history or {}

    -- Set up system prompt based on prompt type
    if #message_history == 0 then
        local system_prompt
        if prompt_type == "term_xray" then
            local term_xray_prompts = require("assistant_prompts").custom_prompts.term_xray
            system_prompt = term_xray_prompts.system_prompt
        else
            system_prompt = dict_prompts.system_prompt
        end

        table.insert(message_history, {
            role = "system",
            content = system_prompt,
        })
    end

    -- Get context for the selected word
    local prev_context, next_context = "", ""
    local context_text = ""

    if prompt_type == "term_xray" then
        -- For term_xray, use LexRank to extract relevant context from book text
        local assistant_utils = require("assistant_utils")
        local LexRank = require("assistant_lexrank")

        -- Get book text up to current reading position
        local book_text = assistant_utils.extractBookTextForAnalysis(CONFIGURATION, ui)

        if book_text and #book_text > 100 then
            -- Use LexRank to get relevant sentences
            local ranked_sentences = LexRank.rank_sentences(book_text, 0.1, 0.1)
            context_text = table.concat(ranked_sentences, " ")
        else
            -- Fallback to standard context if book text is too short
            context_text = prev_context .. highlightedText .. next_context
        end
    else
        -- Standard dictionary context extraction
        if ui.highlight and ui.highlight.getSelectedWordContext then
            -- Helper function to count words in a string.
            local function countWords(str)
                if not str or str == "" then return 0 end
                local _, count = string.gsub(str, "%S+", "")
                return count
            end

            local use_fallback_context = true
            -- Try to get the full sentence containing the word. If `getSelectedSentence()` doesn't exist,
            -- the code will gracefully use the fallback method.
            if ui.highlight.getSelectedSentence then
                local success, sentence = pcall(function() return ui.highlight:getSelectedSentence() end)
                if success and sentence then
                    -- Find the selected word in the sentence to split it.
                    local word_start, word_end = string.find(sentence, highlightedText, 1, true)
                    if word_start then
                        local prev_part = string.sub(sentence, 1, word_start - 1)
                        local next_part = string.sub(sentence, word_end + 1)

                        -- Check if the sentence context is too short on both sides.
                        if countWords(prev_part) < 50 and countWords(next_part) < 50 then
                            -- The sentence is short, so we'll use the fallback to get more context.
                            use_fallback_context = true
                        else
                            -- The sentence provides enough context, so we'll use it.
                            prev_context = prev_part
                            next_context = next_part
                            use_fallback_context = false
                        end
                    end
                end
            end

            -- Use the fallback method (word count) if we couldn't get a good sentence context.
            if use_fallback_context then
                local success, prev, next = pcall(function()
                    return ui.highlight:getSelectedWordContext(50)
                end)
                if success then
                    prev_context = prev or ""
                    next_context = next or ""
                end
            end
        end
        context_text = prev_context .. highlightedText .. next_context
    end
    
    local dict_language = assistant.settings:readSetting("response_language") or assistant.ui_language

    -- Choose the appropriate prompt and context based on prompt type
    local user_prompt, context_content
    if prompt_type == "term_xray" then
        local term_xray_prompts = require("assistant_prompts").custom_prompts.term_xray
        user_prompt = term_xray_prompts.user_prompt
        context_content = context_text

        -- Get book information for term_xray
        local prop = ui.document:getProps()
        local book_title = prop.title or "Unknown Title"
        local book_author = prop.authors or "Unknown Author"

        local context_message = {
            role = "user",
            content = string.gsub(user_prompt, "{(%w+)}", {
                    language = dict_language,
                    context = context_content,
                    word = highlightedText,
                    highlight = highlightedText,
                    title = book_title,
                    author = book_author,
                    user_input = ""
            })
        }
        table.insert(message_history, context_message)
    else
        user_prompt = dict_prompts.user_prompt
        context_content = prev_context .. highlightedText .. next_context

        local context_message = {
            role = "user",
            content = string.gsub(user_prompt, "{(%w+)}", {
                    language = dict_language,
                    context = context_content,
                    word = highlightedText
            })
        }
        table.insert(message_history, context_message)
    end

    -- Query the AI with the message history
    local ret, err = Querier:query(message_history, "Loading AI Dictionary ...")
    if err ~= nil then
        assistant.querier:showError(err)
        return
    end

    local function createResultText(highlightedText, answer)
        local result_text
        local render_markdown = koutil.tableGetValue(CONFIGURATION, "features", "render_markdown") or true
        -- Limit prev_context to last 100 characters and next_context to first 100 characters
        local prev_context_limited = string.sub(prev_context, -100)
        local next_context_limited = string.sub(next_context, 1, 100)
        if render_markdown then
            -- in markdown mode, outputs markdown formatted highlighted text
            result_text = T("... %1 **%2** %3 ...\n\n%4", prev_context_limited, highlightedText, next_context_limited, answer)
        else
            -- in plain text mode, use widget controled characters.
            result_text = T("%1... %2%3%4 ...\n\n%5", TextBoxWidget.PTF_HEADER, prev_context_limited, 
                TextBoxWidget.PTF_BOLD_START, highlightedText, TextBoxWidget.PTF_BOLD_END,  next_context_limited, answer)
        end
        return result_text
    end

    local result = createResultText(highlightedText, ret)
    local chatgpt_viewer

    local function handleAddToNote()
        if ui.highlight and ui.highlight.saveHighlight then
            local success, index = pcall(function()
                return ui.highlight:saveHighlight(true)
            end)
            if success and index then
                local a = ui.annotation.annotations[index]
                a.note = result
                ui:handleEvent(Event:new("AnnotationsModified",
                                    { a, nb_highlights_added = -1, nb_notes_added = 1 }))
            end
        end

        UIManager:close(chatgpt_viewer)
        if ui.highlight and ui.highlight.onClose then
            ui.highlight:onClose()
        end
    end

    chatgpt_viewer = ChatGPTViewer:new {
        assistant = assistant,
        ui = ui,
        title = _("Dictionary"),
        text = result,
        onAddToNote = handleAddToNote,
        default_hold_callback = function ()
            chatgpt_viewer:HoldClose()
        end,
    }

    UIManager:show(chatgpt_viewer)
end

return showDictionaryDialog