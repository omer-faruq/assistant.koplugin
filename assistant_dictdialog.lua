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

local function showDictionaryDialog(assistant, highlightedText, message_history)
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
    
    local dict_language = assistant.settings:readSetting("response_language") or assistant.ui_language
    local context_message = {
        role = "user",
        content = string.gsub(dict_prompts.user_prompt, "{(%w+)}", {
                language = dict_language,
                context = prev_context .. highlightedText .. next_context,
                word = highlightedText
        })
    }

    table.insert(message_history, context_message)

    -- Query the AI with the message history
    local ret, err = Querier:query(message_history, "Loading AI Dictionary ...")
    if err ~= nil then
        assistant.querier:showError(err)
        return
    end

    local function createResultText(highlightedText, answer)
        local result_text
        local render_markdown = koutil.tableGetValue(CONFIGURATION, "features", "render_markdown") or true
        if render_markdown then
            -- in markdown mode, outputs markdown formatted highlighted text
            result_text = T("... %1 **%2** %3 ...\n\n%4", prev_context, highlightedText, next_context, answer)
        else
            -- in plain text mode, use widget controled characters.
            result_text = T("%1... %2%3%4 ...\n\n%5", TextBoxWidget.PTF_HEADER, prev_context, 
                TextBoxWidget.PTF_BOLD_START, highlightedText, TextBoxWidget.PTF_BOLD_END,  next_context, answer)
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
