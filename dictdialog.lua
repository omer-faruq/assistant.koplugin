local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local _ = require("gettext")
local Event = require("ui/event")
local configuration = require("configuration")

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
            content = "You are a dictionary with high quality detail vocabulary definitions and examples.",
        },
    }
    
    -- Try to get context, but handle cases where no text is selected
    local prev_context, next_context = "", ""
    if ui.highlight and ui.highlight.getSelectedWordContext then
        local success, prev, next = pcall(function()
            return ui.highlight:getSelectedWordContext(10)
        end)
        if success then
            prev_context = prev or ""
            next_context = next or ""
        end
    end
    
    local dict_language = configuration.features and configuration.features.dictionary_translate_to or "English"
    local context_message = {
        role = "user",
        content = string.gsub([[
"Explain vocabulary or content with the focus word with following information:"
"- *Conjugation*. Vocabulary in original conjugation if its different than the form in the sentence."
"- *Synonyms*. 3 synonyms for the word if available."
"- *Meaning*. Meaning of the expression without reference to context. Answer this part in {language} language."
"- *Explanation*. Explanation of the content according to context. Answer this part in {language} language."
"- *Example*. Another example sentence. Answer this part in the original language of the sentence."
"- *Origin*. Origin of that word, tracing it back to its ancient roots. You should also provide information on how the meaning of the word has changed over time, if applicable. Answer this part in {language} language." ..
"Only show the requested replies, do not give a description, answer in markdown list format."

[CONTEXT]
{context}

[FOCUS WORD]
{word}
]], "{(%w+)}", {
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
        title = _("Dictionary"),
        text = result_text,
        showAskQuestion = false,
        onAddToNote = handleAddToNote,
    }

    UIManager:show(chatgpt_viewer)
    if configuration and configuration.features and configuration.features.refresh_screen_after_displaying_results then
        UIManager:setDirty(nil, "full")
    end
end

return showDictionaryDialog
