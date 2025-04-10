-- Load required modules
local plugin_config = require("configuration")
if not plugin_config then
    print("DictDialog: Failed to load configuration.lua")
    plugin_config = {} -- Provide empty fallback config
end
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local _ = require("gettext")
local Event = require("ui/event")
local queryChatGPT = require("gpt_query")

local function showDictionaryDialog(ui, highlightedText, message_history)
    local message_history = message_history or {
    -- Removed debug log for plugin_config
        {
            role = "system",
            content = "You are a dictionary with high quality detail vocabulary definitions and examples.",
        },
    }
    
    prev_context, next_context = ui.highlight:getSelectedWordContext(10)
    local context_message = {
        role = "user",
        content = prev_context .. "<<" .. highlightedText .. ">>" .. next_context .. "\n" ..
            "explain vocabulary or content in <<>> in above sentence with following format:\n" ..
            "⮞ Vocabulary in original conjugation if its different than the form in the sentence\n" ..
            "⮞ 3 synonyms for the word if available\n" ..
            "⮞ Give the meaning of the expression without reference to context.Answer this part in ".. plugin_config.features.dictionary_translate_to .." language\n" ..
            "⮞ Explanation of content in <<>> according to context. Answer this part in ".. plugin_config.features.dictionary_translate_to .." language\n" ..
            "⮞ Give another example sentence. Answer this part  in the language of text in <<>>\n" ..
            "only show the replies, do not give a description"
    }
    table.insert(message_history, context_message)

    local answer = queryChatGPT(message_history)
    local function createResultText(highlightedText, answer)
        local result_text = 
            TextBoxWidget.PTF_HEADER .. 
            "... " .. prev_context .. TextBoxWidget.PTF_BOLD_START .. highlightedText .. TextBoxWidget.PTF_BOLD_END .. next_context .. " ...\n\n" ..
            answer 
        return result_text
    end

    local result_text = createResultText(highlightedText, answer)
    local chatgpt_viewer = nil

    local function handleAddToNote()
        local index = ui.highlight:saveHighlight(true)
        local a = ui.annotation.annotations[index]
        a.note = result_text
        ui:handleEvent(Event:new("AnnotationsModified",
                            { a, nb_highlights_added = -1, nb_notes_added = 1 }))

        UIManager:close(chatgpt_viewer)
        ui.highlight:onClose()
    end

    chatgpt_viewer = ChatGPTViewer:new {
        ui = ui,
        title = _("Dictionary"),
        text = result_text,
        showAskQuestion = false,
        onAddToNote = handleAddToNote,
    }

    UIManager:show(chatgpt_viewer)
    if plugin_config and plugin_config.features and plugin_config.features.refresh_screen_after_displaying_results then
        UIManager:setDirty(nil, "full")
    end
end

return showDictionaryDialog