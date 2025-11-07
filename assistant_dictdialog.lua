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
local assistant_utils = require("assistant_utils")
local dict_prompts = require("assistant_prompts").assistant_prompts.dict

-- Expand context sentences to include surrounding sentences for pronouns and related narrative
-- This captures "he", "she", "they" and nearby actions that provide important context
-- OPTIMIZED: Now accepts pre-tokenized sentences and indices to avoid re-tokenization
-- all_sentences: array of all sentences in the text (pre-tokenized)
-- selected_indices: array of indices of selected sentences in all_sentences
-- context_window_before/after: number of surrounding sentences to include
local function expandContextWithSurroundings(all_sentences, selected_indices, context_window_before, context_window_after)
    if not selected_indices or #selected_indices == 0 then
        return {}
    end

    context_window_before = context_window_before or 1  -- Include 1 sentence before
    context_window_after = context_window_after or 1    -- Include 1 sentence after

    -- Expand the indices to include surrounding context
    local expanded_indices = {}
    local expanded_set = {}

    for _, idx in ipairs(selected_indices) do
        -- Include context_window_before sentences before and context_window_after after
        for neighbor_idx = math.max(1, idx - context_window_before), math.min(#all_sentences, idx + context_window_after) do
            if not expanded_set[neighbor_idx] then
                table.insert(expanded_indices, neighbor_idx)
                expanded_set[neighbor_idx] = true
            end
        end
    end

    -- Sort by document order
    table.sort(expanded_indices)

    -- Build the expanded context from the expanded indices
    local expanded_sentences = {}
    for _, idx in ipairs(expanded_indices) do
        table.insert(expanded_sentences, all_sentences[idx])
    end

    return expanded_sentences
end

-- Filter text to find sentences containing the highlighted term with surrounding context
local function filterTextForTerm(text, highlighted_term, language_code, configuration)
    if not text or not highlighted_term or highlighted_term == "" then
        return nil
    end

    local LexRankLanguages = require("assistant_lexrank_languages")

    -- Simple sentence splitting (same logic as LexRank)
    local sentences = {}
    local current_sentence = ""

    for i = 1, #text do
        local char = text:sub(i, i)
        current_sentence = current_sentence .. char

        if char:match("[.!?;]") then
            local trimmed = current_sentence:gsub("^%s*(.-)%s*$", "%1")
            if #trimmed > 10 then -- Minimum sentence length
                table.insert(sentences, trimmed)
            end
            current_sentence = ""
        end
    end

    -- Add remaining text as sentence if it's long enough
    local trimmed = current_sentence:gsub("^%s*(.-)%s*$", "%1")
    if #trimmed > 10 then
        table.insert(sentences, trimmed)
    end

    -- Find sentences containing the term (case-insensitive)
    local matching_indices = {}
    local term_lower = highlighted_term:lower()

    for i, sentence in ipairs(sentences) do
        if sentence:lower():find(term_lower, 1, true) then -- true = plain text search
            table.insert(matching_indices, i)
        end
    end

    -- If no direct matches, try language-aware stemming
    if #matching_indices == 0 then
        local stemmed_term = LexRankLanguages.stem_word(highlighted_term, language_code)
        if stemmed_term ~= term_lower then -- Only if stemming actually changed the word
            for i, sentence in ipairs(sentences) do
                if sentence:lower():find(stemmed_term, 1, true) then
                    table.insert(matching_indices, i)
                end
            end
        end
    end

    -- If still no matches, return nil (will trigger fallback)
    if #matching_indices == 0 then
        return nil
    end

    -- Include larger context sentences around matches for better coverage
    local context_window = koutil.tableGetValue(CONFIGURATION, "features", "term_filter_context_window") or 5 -- sentences before and after
    local selected_indices = {}

    for _, idx in ipairs(matching_indices) do
        for context_idx = math.max(1, idx - context_window), math.min(#sentences, idx + context_window) do
            selected_indices[context_idx] = true
        end
    end

    -- Build filtered text from selected sentences
    local filtered_sentences = {}
    for i = 1, #sentences do
        if selected_indices[i] then
            table.insert(filtered_sentences, sentences[i])
        end
    end

    -- Require minimum amount of text to make LexRank worthwhile
    if #filtered_sentences < 3 then
        return nil
    end

    return table.concat(filtered_sentences, " ")
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
    local context_sentence_count = 0
    local dict_language = assistant.settings:readSetting("response_language") or assistant.ui_language

    if prompt_type == "term_xray" then
        -- For term_xray, use LexRank to extract relevant context from book text
        -- OPTIMIZED: Single LexRank call with score-based filtering (instead of 3 separate calls)
        local LexRank = require("assistant_lexrank")
        local LexRankLanguages = require("assistant_lexrank_languages")

        -- Get book text up to current reading position
        local book_text = assistant_utils.extractBookTextForAnalysis(CONFIGURATION, ui)

        if book_text and #book_text > 100 then
            -- Tokenize sentences once (will be reused for all filtering and context expansion)
            local language_module = LexRankLanguages.get_language_module(dict_language)
            local all_sentences = {}
            local current_sentence = ""
            local delim_pattern = "[" .. table.concat(language_module.sentence_delimiters, "") .. "]"

            for i = 1, #book_text do
                local char = book_text:sub(i, i)
                current_sentence = current_sentence .. char

                if char:match(delim_pattern) then
                    local trimmed = current_sentence:gsub("^%s*(.-)%s*$", "%1")
                    if #trimmed >= language_module.min_sentence_length then
                        table.insert(all_sentences, trimmed)
                    end
                    current_sentence = ""
                end
            end

            -- Add remaining text as sentence if it's long enough
            local trimmed = current_sentence:gsub("^%s*(.-)%s*$", "%1")
            if #trimmed >= language_module.min_sentence_length then
                table.insert(all_sentences, trimmed)
            end

            -- OPTIMIZED: Single LexRank call with return_with_metadata=true
            -- Run with the lowest threshold to get all candidates with scores
            local threshold_very_inclusive = koutil.tableGetValue(CONFIGURATION, "features", "lexrank_threshold_very_inclusive") or 0.005
            local all_candidates = LexRank.rank_sentences(book_text, threshold_very_inclusive, 0.1, dict_language, CONFIGURATION.features, true)

            -- Filter candidates at different levels using their scores (no re-tokenization needed!)
            local min_sentences = koutil.tableGetValue(CONFIGURATION, "features", "term_xray_min_sentences") or 1000
            local max_sentences = koutil.tableGetValue(CONFIGURATION, "features", "term_xray_max_sentences") or 1500
            local selected_indices = {}
            local seen_indices = {}

            if all_candidates and #all_candidates > 0 then
                -- Calculate score threshold for term-specific sentences
                local threshold_term_specific = koutil.tableGetValue(CONFIGURATION, "features", "lexrank_threshold_term_specific") or 0.01
                local threshold_general = koutil.tableGetValue(CONFIGURATION, "features", "lexrank_threshold_general") or 0.01

                -- Stage 1: Find term-specific matches and add high-scoring sentence around them
                local filtered_text = filterTextForTerm(book_text, highlightedText, dict_language, CONFIGURATION)
                if filtered_text and #filtered_text > 100 then
                    for _, candidate in ipairs(all_candidates) do
                        -- Check if sentence appears in filtered (term-specific) text
                        if filtered_text:find(candidate.sentence, 1, true) and candidate.score >= threshold_term_specific then
                            if not seen_indices[candidate.index] then
                                table.insert(selected_indices, candidate.index)
                                seen_indices[candidate.index] = true
                            end
                        end
                    end
                end

                -- Stage 2: Add high-scoring general context sentences
                for _, candidate in ipairs(all_candidates) do
                    if not seen_indices[candidate.index] and #selected_indices < (min_sentences * 0.8) and candidate.score >= threshold_general then
                        table.insert(selected_indices, candidate.index)
                        seen_indices[candidate.index] = true
                    end
                end

                -- Stage 3: Add more candidates until we reach min_sentences
                for _, candidate in ipairs(all_candidates) do
                    if not seen_indices[candidate.index] and #selected_indices < min_sentences then
                        table.insert(selected_indices, candidate.index)
                        seen_indices[candidate.index] = true
                    end
                end

                -- Stage 4: Cap at max_sentences
                while #selected_indices > max_sentences do
                    table.remove(selected_indices)
                end
            end

            -- Sort indices to maintain document order
            table.sort(selected_indices)

            -- OPTIMIZED: Expand context using indices (no re-tokenization!)
            local context_before = koutil.tableGetValue(CONFIGURATION, "features", "term_xray_context_sentences_before") or 5
            local context_after = koutil.tableGetValue(CONFIGURATION, "features", "term_xray_context_sentences_after") or 5
            local context_sentences = expandContextWithSurroundings(
                all_sentences,
                selected_indices,
                context_before,
                context_after
            )

            -- Concatenate context sentences without numbering
            -- Sentences are sent in chronological order from the book, which the LLM is instructed to consider
            context_text = table.concat(context_sentences, " ")
            context_sentence_count = #context_sentences
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

    -- Choose the appropriate prompt and context based on prompt type
    local user_prompt, context_content, title, loading_message
    if prompt_type == "term_xray" then
        local term_xray_prompts = require("assistant_prompts").custom_prompts.term_xray
        user_prompt = term_xray_prompts.user_prompt
        context_content = context_text

        -- Get book information for term_xray
        local prop = ui.document:getProps()
        local book_title = prop.title or "Unknown Title"
        local book_author = prop.authors or "Unknown Author"
        title = _("Term X-Ray")
        loading_message = _("Loading Term X-Ray ...")
        local context_message = {
            role = "user",
            content = string.gsub(user_prompt, "{(%w+)}", {
                    language = dict_language,
                    context = context_content,
                    context_sentence_count = context_sentence_count,
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
        title = _("Dictionary")
        loading_message = _("Loading AI Dictionary ...")
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
    local ret, err = Querier:query(message_history, loading_message)
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
        local normalized_answer = assistant_utils.normalizeMarkdownHeadings(answer, 2, 6) or answer
        if render_markdown then
            -- in markdown mode, outputs markdown formatted highlighted text
            result_text = T("... %1 **%2** %3 ...\n\n%4", prev_context_limited, highlightedText, next_context_limited, normalized_answer)
        else
            -- in plain text mode, use widget controlled characters.
            result_text = T("%1... %2%3%4 ...\n\n%5", TextBoxWidget.PTF_HEADER, prev_context_limited, 
                TextBoxWidget.PTF_BOLD_START, highlightedText, TextBoxWidget.PTF_BOLD_END,  next_context_limited, normalized_answer)
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
        title = title,
        text = result,
        onAddToNote = handleAddToNote,
        default_hold_callback = function ()
            chatgpt_viewer:HoldClose()
        end,
    }

    UIManager:show(chatgpt_viewer)
end

return showDictionaryDialog