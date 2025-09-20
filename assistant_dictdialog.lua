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
local LanguageRankers = require("assistant_language_rankers")

local LANGUAGE_ALIASES = {
    en = "en",
    english = "en",
    eng = "en",
    es = "es",
    spa = "es",
    spanish = "es",
    fr = "fr",
    fra = "fr",
    fre = "fr",
    french = "fr",
    de = "de",
    deu = "de",
    ger = "de",
    german = "de",
}

local function extractParagraphs(text)
    local paragraphs = {}
    local buffer = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*$") then
            if #buffer > 0 then
                local paragraph = table.concat(buffer, " ")
                paragraph = paragraph:gsub("^%s+", ""):gsub("%s+$", "")
                paragraph = paragraph:gsub("%s+", " ")
                table.insert(paragraphs, paragraph)
                buffer = {}
            end
        else
            table.insert(buffer, line)
        end
    end
    if #buffer > 0 then
        local paragraph = table.concat(buffer, " ")
        paragraph = paragraph:gsub("^%s+", ""):gsub("%s+$", "")
        paragraph = paragraph:gsub("%s+", " ")
        table.insert(paragraphs, paragraph)
    end
    if #paragraphs == 0 and text:match("%S") then
        local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            table.insert(paragraphs, trimmed)
        end
    end
    return paragraphs
end

local function normalizeLanguageCode(language_value)
    if type(language_value) ~= "string" then
        return nil
    end
    local normalized = language_value:lower()
    normalized = normalized:gsub("%s+", "")
    normalized = normalized:gsub("_", "-")
    if normalized == "" then
        return nil
    end
    local alias = LANGUAGE_ALIASES[normalized]
    if alias then
        return alias
    end
    local first_segment = normalized:match("^(%a+)")
    if first_segment then
        alias = LANGUAGE_ALIASES[first_segment]
        if alias then
            return alias
        end
    end
    local two_letter = normalized:match("^(%a%a)")
    if two_letter then
        alias = LANGUAGE_ALIASES[two_letter]
        if alias then
            return alias
        end
        return two_letter
    end
    return normalized
end

local function detectDocumentLanguage(ui)
    if not ui or not ui.document then
        return nil
    end
    local info = ui.document.info or {}
    local language_value = info.language or info.Language
    if (not language_value or language_value == "") and ui.document.getProps then
        local props = ui.document:getProps() or {}
        language_value = props.language or props.Language
    end
    return normalizeLanguageCode(language_value)
end

local function searchWordInBook(assistant, searchWord, page_or_sentence)
    local ui = assistant.ui
    local CONFIGURATION = assistant.CONFIGURATION
    local book_text = ""
    local language_code = detectDocumentLanguage(ui) or "unknown"

    -- Auto-detect mode based on document type if not specified
    if not page_or_sentence then
        if ui.document.info.has_pages then
            page_or_sentence = "page"
        else
            page_or_sentence = "sentence"
        end
    end

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

    if page_or_sentence == "page" and ui.document.info.has_pages then
        -- PAGE-based approach for page documents
        local pages_with_term = {}
        local current_page = ui.view.state.page

        -- Search through pages from 1 to current page
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

            -- Check if any pattern matches on this page
            local page_lower = page_text:lower()
            local found_on_page = false
            for _, pattern in ipairs(unique_patterns) do
                if page_lower:find("%f[%w]" .. pattern:gsub("([^%w])", "%%%1") .. "%f[%W]") then
                    found_on_page = true
                    break
                end
            end

            if found_on_page then
                table.insert(pages_with_term, { page = page, text = page_text })
            end
        end

        -- Select first 3 and last 3 pages (including current page if it has the term)
        local selected_pages = {}
        local total_pages = #pages_with_term

        if total_pages <= 6 then
            -- Use all pages if 6 or fewer
            for _, page_info in ipairs(pages_with_term) do
                table.insert(selected_pages, "**Page " .. page_info.page .. ":**\n" .. page_info.text)
            end
        else
            -- Take first 3
            for i = 1, 3 do
                table.insert(selected_pages, "**Page " .. pages_with_term[i].page .. ":**\n" .. pages_with_term[i].text)
            end

            -- Take last 3 (avoiding overlap with first 3)
            local start_last = math.max(4, total_pages - 2)
            for i = start_last, total_pages do
                table.insert(selected_pages, "**Page " .. pages_with_term[i].page .. ":**\n" .. pages_with_term[i].text)
            end
        end

        -- Combine selected pages with separators
        local combined_context = ""
        if #selected_pages > 0 then
            combined_context = table.concat(selected_pages, "\n\n---\n\n")

            -- Apply max length limit from configuration
            local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features",
                "max_text_length_for_analysis") or 100000
            if #combined_context > max_text_length_for_analysis then
                combined_context = combined_context:sub(1, max_text_length_for_analysis)
                -- Try to end at a complete page separator
                local last_separator = combined_context:reverse():find("---")
                if last_separator and last_separator < 2000 then -- Within reasonable distance
                    combined_context = combined_context:sub(1, #combined_context - last_separator + 3)
                end
            end

            return combined_context
        else
            return ""
        end
    else
        -- Paragraph-based approach - analyze paragraph windows and expand context size
        local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features",
            "max_text_length_for_analysis") or 100000

        local paragraphs = extractParagraphs(book_text)
        if #paragraphs == 0 then
            return ""
        end

        local paragraph_contexts = {}

        for index, paragraph in ipairs(paragraphs) do
            local paragraph_lower = paragraph:lower()
            local contains_term = false
            local term_frequency = 0

            for _, pattern in ipairs(unique_patterns) do
                local boundary_pattern = "%f[%w]" .. pattern:gsub("([^%w])", "%%%1") .. "%f[%W]"
                if paragraph_lower:find(boundary_pattern) then
                    contains_term = true
                    local start_pos = 1
                    while true do
                        local pos = paragraph_lower:find(pattern, start_pos, true)
                        if not pos then break end
                        term_frequency = term_frequency + 1
                        start_pos = pos + 1
                    end
                    break
                end
            end

            if contains_term then
                local word_count = 0
                for _ in paragraph:gmatch("%S+") do
                    word_count = word_count + 1
                end

                table.insert(paragraph_contexts, {
                    text = paragraph,
                    position = index,
                    paragraph_index = index,
                    term_frequency = term_frequency,
                    word_count = word_count,
                })
            end
        end

        if #paragraph_contexts == 0 then
            return ""
        end

        local ranked_contexts = LanguageRankers.rankContexts(language_code, paragraph_contexts, {
            total_units = #paragraphs,
            total_paragraphs = #paragraphs,
            current_paragraph_index = #paragraphs,
            current_index = #paragraphs,
        })

        local min_paragraphs = math.min(6, #paragraphs)
        local max_paragraphs = math.min(20, #paragraphs)
        local selected_indices = {}
        local ordered_indices = {}

        local function add_index(idx)
            if idx < 1 or idx > #paragraphs or selected_indices[idx] or #ordered_indices >= max_paragraphs then
                return false
            end
            selected_indices[idx] = true
            table.insert(ordered_indices, idx)
            return true
        end

        for _, context in ipairs(ranked_contexts) do
            add_index(context.paragraph_index)
            if #ordered_indices >= max_paragraphs then
                break
            end
        end

        if #ordered_indices == 0 then
            return ""
        end

        if #ordered_indices < min_paragraphs then
            local candidates = {}
            for idx = 1, #paragraphs do
                if not selected_indices[idx] then
                    local nearest = math.huge
                    for _, selected_idx in ipairs(ordered_indices) do
                        local distance = math.abs(idx - selected_idx)
                        if distance < nearest then
                            nearest = distance
                        end
                    end
                    table.insert(candidates, { index = idx, distance = nearest })
                end
            end

            table.sort(candidates, function(a, b)
                if a.distance == b.distance then
                    return a.index < b.index
                end
                return a.distance < b.distance
            end)

            for _, candidate in ipairs(candidates) do
                if #ordered_indices >= min_paragraphs or #ordered_indices >= max_paragraphs then
                    break
                end
                add_index(candidate.index)
            end
        end

        if #ordered_indices < min_paragraphs then
            for idx = 1, #paragraphs do
                if #ordered_indices >= min_paragraphs or #ordered_indices >= max_paragraphs then
                    break
                end
                add_index(idx)
            end
        end

        table.sort(ordered_indices)

        local combined_parts = {}
        local current_length = 0
        local separator = "\n\n---\n\n\n"

        for _, idx in ipairs(ordered_indices) do
            local paragraph_text = paragraphs[idx]
            if paragraph_text and paragraph_text ~= "" then
                local separator_length = (#combined_parts > 0) and #separator or 0
                local part_length = #paragraph_text
                if current_length + separator_length + part_length > max_text_length_for_analysis then
                    break
                end
                current_length = current_length + separator_length + part_length
                table.insert(combined_parts, paragraph_text)
            end
        end

        if #combined_parts > 0 then
            local combined_context = table.concat(combined_parts, separator)
            return combined_context
        end

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
        UIManager:show(InfoMessage:new { icon = "notice-warning", text = err })
        return
    end

    -- Handle case where no text is highlighted (gesture-triggered)
    local input_dialog
    if not highlightedText or highlightedText == "" then
        -- Show a simple input dialog to ask for a word to look up
        input_dialog = InputDialog:new {
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
            final_context = "**Current Context:**\n" ..
                current_context .. "\n\n**Additional Context from Book:**\n" .. book_context
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
        -- Limit prev_context to last 100 characters and next_context to first 100 characters
        local prev_context_limited = string.sub(prev_context, -100)
        local next_context_limited = string.sub(next_context, 1, 100)
        if render_markdown then
            -- in markdown mode, outputs markdown formatted highlighted text
            result_text = T("... %1 **%2** %3 ...\n\n%4", prev_context_limited, highlightedText, next_context_limited,
                answer)
        else
            -- in plain text mode, use widget controled characters.
            result_text = T("%1... %2%3%4 ...\n\n%5", TextBoxWidget.PTF_HEADER, prev_context_limited,
                TextBoxWidget.PTF_BOLD_START, highlightedText, TextBoxWidget.PTF_BOLD_END, next_context_limited, answer)
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
        default_hold_callback = function()
            chatgpt_viewer:HoldClose()
        end,
    }

    UIManager:show(chatgpt_viewer)
end

return showDictionaryDialog
