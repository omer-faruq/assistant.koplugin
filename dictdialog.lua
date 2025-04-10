-- Determine plugin directory for dofile
local script_path_dict = debug.getinfo(1, "S").source
local plugin_dir_dict = ""
if script_path_dict and script_path_dict:sub(1,1) == "@" then
    script_path_dict = script_path_dict:sub(2)
    plugin_dir_dict = script_path_dict:match("(.*/)") or "./"
else
    plugin_dir_dict = "./"
end

-- Load configuration using dofile
local plugin_config = nil
local config_path_dict = plugin_dir_dict .. "configuration.lua"
local success_dict, result_dict = pcall(function() return dofile(config_path_dict) end)
if success_dict then
    plugin_config = result_dict
else
    print("DictDialog: Failed to load configuration.lua from " .. config_path_dict .. ":", result_dict)
end
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local _ = require("gettext")
local Event = require("ui/event")
local queryChatGPT = require("gpt_query")
-- Configuration is loaded locally using dofile

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