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

local function searchWordInBook(assistant, searchWord)
    local ui = assistant.ui
    local CONFIGURATION = assistant.CONFIGURATION
    local book_text = ""
    local instances = {}

    -- Extract full book text from start to current position
    if not ui.document.info.has_pages then
        -- EPUB documents
        local current_xp = ui.document:getXPointer()
        ui.document:gotoPos(0)
        local start_xp = ui.document:getXPointer()
        ui.document:gotoXPointer(current_xp)
        book_text = ui.document:getTextFromXPointers(start_xp, current_xp) or ""
    else
        -- Page-based documents (PDF, etc.)
        local current_page = ui.view.state.page
        for page = 1, current_page do
            local page_text = ui.document:getPageText(page) or ""
            if type(page_text) == "table" then
                local texts = {}
                for _, block in ipairs(page_text) do
                    if type(block) == "table" then
                        for i = 1, #block do
                            local span = block[i]
                            if type(span) == "table" and span.word then
                                table.insert(texts, span.word)
                            end
                        end
                    end
                end
                page_text = table.concat(texts, " ")
            end
            book_text = book_text .. page_text .. "\n"
        end
    end

    if book_text == "" then
        return ""
    end

    -- Create case-insensitive and plural-insensitive search patterns
    local search_patterns = {}
    local base_word = searchWord:lower():gsub("s$", ""):gsub("es$", ""):gsub("ies$", "y")

    -- Add original word and variations
    table.insert(search_patterns, searchWord:lower())
    table.insert(search_patterns, base_word)
    table.insert(search_patterns, base_word .. "s")
    table.insert(search_patterns, base_word .. "es")
    table.insert(search_patterns, base_word:gsub("y$", "") .. "ies")

    -- Remove duplicates
    local unique_patterns = {}
    local seen = {}
    for _, pattern in ipairs(search_patterns) do
        if not seen[pattern] and pattern ~= "" then
            seen[pattern] = true
            table.insert(unique_patterns, pattern)
        end
    end

    -- Split text into sentences (rough approximation)
    local sentences = {}
    local sentence_positions = {}
    local pos = 1

    for sentence in book_text:gmatch("[^.!?]+[.!?]*") do
        sentence = sentence:gsub("^%s+", ""):gsub("%s+$", "")
        if sentence ~= "" then
            table.insert(sentences, sentence)
            table.insert(sentence_positions, pos)
            pos = pos + #sentence + 1
        end
    end

    -- Search for instances and extract context with position tracking
    local found_instances = {}
    for i, sentence in ipairs(sentences) do
        local sentence_lower = sentence:lower()
        for _, pattern in ipairs(unique_patterns) do
            if sentence_lower:find("%f[%w]" .. pattern:gsub("([^%w])", "%%%1") .. "%f[%W]") then
                table.insert(found_instances, {position = i, sentence_idx = i})
                break -- Found in this sentence, no need to check other patterns
            end
        end
    end

    -- If no instances found, return empty
    if #found_instances == 0 then
        return ""
    end

    -- Extract contexts for quality filtering
    local quality_instances = {}
    local min_distance = math.max(5, math.floor(#sentences / 30)) -- Minimum distance to ensure diversity

    for _, instance in ipairs(found_instances) do
        local i = instance.sentence_idx
        -- Extract 1-2 sentences before and after for focused context (reduced from 3)
        local start_idx = math.max(1, i - 1)
        local end_idx = math.min(#sentences, i + 1)

        local context_sentences = {}
        for j = start_idx, end_idx do
            table.insert(context_sentences, sentences[j])
        end

        local context = table.concat(context_sentences, " ")

        -- Check minimum distance from previously added instances
        local is_too_close = false
        for _, existing in ipairs(quality_instances) do
            if math.abs(i - existing.position) < min_distance then
                is_too_close = true
                break
            end
        end

        -- Simple duplicate check based on context length and first few words
        local is_duplicate = false
        local context_start = context:sub(1, 50):lower()
        for _, existing in ipairs(quality_instances) do
            local existing_start = existing.context:sub(1, 50):lower()
            if context_start == existing_start then
                is_duplicate = true
                break
            end
        end

        if not is_too_close and not is_duplicate then
            table.insert(quality_instances, {
                position = i,
                context = context
            })
        end
    end

    -- Select first 3 and last 3 instances
    local selected_instances = {}
    local total_quality = #quality_instances

    if total_quality <= 6 then
        -- Use all instances if 6 or fewer
        for _, instance in ipairs(quality_instances) do
            table.insert(selected_instances, instance.context)
        end
    else
        -- Take first 3
        for i = 1, 3 do
            table.insert(selected_instances, quality_instances[i].context)
        end

        -- Take last 3 (avoiding overlap with first 3)
        local start_last = math.max(4, total_quality - 2)
        for i = start_last, total_quality do
            table.insert(selected_instances, quality_instances[i].context)
        end
    end

    -- Combine selected instances with separators
    local combined_context = ""
    if #selected_instances > 0 then
        combined_context = table.concat(selected_instances, "\n\n---\n\n")

        -- Apply max length limit from configuration
        local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
        if #combined_context > max_text_length_for_analysis then
            combined_context = combined_context:sub(1, max_text_length_for_analysis)
            -- Try to end at a complete sentence or separator
            local last_separator = combined_context:reverse():find("---")
            if last_separator and last_separator < 1000 then -- Within reasonable distance
                combined_context = combined_context:sub(1, #combined_context - last_separator + 3)
            end
        end

        return combined_context
    else
        return ""
    end
end

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

    -- Initialize message history based on prompt type
    local default_system_prompt = dict_prompts.system_prompt
    if prompt_type == "term_xray" then
        local custom_prompts = require("assistant_prompts").custom_prompts
        local term_xray_config = custom_prompts.term_xray
        if term_xray_config.system_prompt then
            default_system_prompt = term_xray_config.system_prompt
        end
    end

    local message_history = message_history or {
        {
            role = "system",
            content = default_system_prompt,
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
    local final_context = ""
    local prompt_config = dict_prompts

    -- Only use searchWordInBook for term_xray prompt
    if prompt_type == "term_xray" then
        -- Get comprehensive context from the entire book for term_xray
        local current_context = prev_context .. highlightedText .. next_context
        local book_context = searchWordInBook(assistant, highlightedText)

        if book_context and book_context ~= "" then
            -- Combine current context with book context, ensuring current context is included
            final_context = "**Current Context:**\n" .. current_context .. "\n\n**Additional Context from Book:**\n" .. book_context
        else
            -- Fallback to local context if no book context found
            final_context = current_context
        end

        -- Use term_xray prompt configuration
        local custom_prompts = require("assistant_prompts").custom_prompts
        prompt_config = custom_prompts.term_xray
    else
        -- Use local context for regular dictionary
        final_context = prev_context .. highlightedText .. next_context
    end

    local context_message = {
        role = "user",
        content = string.gsub(prompt_config.user_prompt, "{(%w+)}", {
                language = dict_language,
                context = final_context,
                word = highlightedText,
                highlight = highlightedText,
                user_input = ""
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
