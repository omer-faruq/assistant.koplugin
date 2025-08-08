local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local t = require("i18n")
local Event = require("ui/event")
local configuration = require("configuration")
local dict_prompts = require("prompts").assitant_prompts.dict

local function showDictionaryDialog(assitant, highlightedText, message_history)
    local Querier = assitant.querier
    local ui = assitant.ui

    -- Check if Querier is initialized
    local ok, err = Querier:load_model(assitant:getModelProvider())
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    -- Handle case where no text is highlighted (gesture-triggered)
    local input_dialog
    if not highlightedText or highlightedText == "" then
        -- Show a simple input dialog to ask for a word to look up
        input_dialog = InputDialog:new{
            title = t("ai_dictionary"),
            input_hint = t("enter_a_word_to_look_up"),
            input_type = "text",
            buttons = {
                {
                    {
                        text = t("cancel"),
                        callback = function()
                            UIManager:close(input_dialog)
                        end,
                    },
                    {
                        text = t("look_up"),
                        is_enter_default = true,
                        callback = function()
                            local word = input_dialog:getInputText()
                            UIManager:close(input_dialog)
                            if word and word ~= "" then
                                -- Recursively call with the entered word
                                showDictionaryDialog(assitant, word, message_history)
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

    local message_history = message_history or {
        {
            role = "system",
            content = dict_prompts.system_prompt,
        },
    }
    
    -- Try to get context for the selected word.
    -- By default, we prefer the full sentence as context.
    -- If the sentence provides less than 10 words of context on both sides of the word,
    -- we switch to getting a context of at least 10 words on each side as a fallback.
    local prev_context, next_context = "", ""
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
                    if countWords(prev_part) < 10 and countWords(next_part) < 10 then
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
                return ui.highlight:getSelectedWordContext(10)
            end)
            if success then
                prev_context = prev or ""
                next_context = next or ""
            end
        end
    end
    
    local dict_language = configuration.features.dictionary_translate_to or configuration.features.response_language or "English"
    local context_message = {
        role = "user",
        content = string.gsub(dict_prompts.user_prompt, "{(%w+)}", {
    language = dict_language,
    context = prev_context .. highlightedText .. next_context,
    word = highlightedText
    })}

    table.insert(message_history, context_message)

    -- Query the AI with the message history
    local answer, err = Querier:query(message_history, "Loading AI Dictionary ...")
    if err ~= nil then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    local function createResultText(highlightedText, answer)
        local result_text
        if configuration and configuration.features and (configuration.features.render_markdown or configuration.features.render_markdown == nil) then
        -- in markdown mode, outputs markdown formated highlighted text
        result_text = "... " .. prev_context .. " **" .. highlightedText ..  "** " ..  next_context ..  " ...\n\n" ..  answer
        else
        -- in plain text mode, use widget controled characters.
        result_text =
            TextBoxWidget.PTF_HEADER .. 
            "... " .. prev_context .. TextBoxWidget.PTF_BOLD_START .. highlightedText .. TextBoxWidget.PTF_BOLD_END .. next_context .. " ...\n\n" ..
            answer 
        end
        return result_text
    end

    local result_text = createResultText(highlightedText, answer)
    local chatgpt_viewer = nil

    local function handleAddToNote()
        if ui.highlight and ui.highlight.saveHighlight then
            local success, index = pcall(function()
                return ui.highlight:saveHighlight(true)
            end)
            if success and index then
                local a = ui.annotation.annotations[index]
                a.note = result_text
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
        assitant = assitant,
        ui = ui,
        title = t("dictionary"),
        text = result_text,
        onAddToNote = handleAddToNote,
    }

    UIManager:show(chatgpt_viewer)
end

return showDictionaryDialog
