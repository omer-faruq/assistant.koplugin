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

local function searchWordInBook(assistant, searchWord, page_or_sentence)
    local ui = assistant.ui
    local CONFIGURATION = assistant.CONFIGURATION
    local book_text = ""
    local instances = {}

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
                table.insert(pages_with_term, {page = page, text = page_text})
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
            local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000
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
        -- INTELLIGENT SENTENCE-based approach - analyze all instances and select the best
        local max_text_length_for_analysis = koutil.tableGetValue(CONFIGURATION, "features", "max_text_length_for_analysis") or 100000

        -- Split text into sentences
        local sentences = {}
        for sentence in book_text:gmatch("[^.!?]+[.!?]*") do
            sentence = sentence:gsub("^%s+", ""):gsub("%s+$", "")
            if sentence ~= "" and #sentence > 15 then -- Filter very short sentences
                table.insert(sentences, sentence)
            end
        end

        if #sentences == 0 then
            return ""
        end

        -- Find all instances and extract context with quality scoring
        local all_contexts = {}

        for i, sentence in ipairs(sentences) do
            local sentence_lower = sentence:lower()
            local contains_term = false
            local term_frequency = 0

            -- Check if sentence contains any search pattern
            for _, pattern in ipairs(unique_patterns) do
                if sentence_lower:find("%f[%w]" .. pattern:gsub("([^%w])", "%%%1") .. "%f[%W]") then
                    contains_term = true
                    -- Count term frequency in this sentence
                    local start = 1
                    while true do
                        local pos = sentence_lower:find(pattern, start, true)
                        if not pos then break end
                        term_frequency = term_frequency + 1
                        start = pos + 1
                    end
                    break
                end
            end

            if contains_term then
                -- Extract context around this sentence (5-10 sentences on each side)
                local context_size = math.min(10, math.max(5, math.floor(#sentences / 30))) -- Adaptive context size: 5-10 sentences
                local start_idx = math.max(1, i - context_size)
                local end_idx = math.min(#sentences, i + context_size)

                local context_sentences = {}
                for j = start_idx, end_idx do
                    table.insert(context_sentences, sentences[j])
                end

                local context_text = table.concat(context_sentences, " ")

                -- Calculate quality score for this context
                local quality_score = 0

                -- 1. Term frequency bonus (more mentions = higher relevance)
                quality_score = quality_score + (term_frequency * 10)

                -- 2. Context length bonus (moderate length is preferred)
                local word_count = 0
                for word in context_text:gmatch("%S+") do
                    word_count = word_count + 1
                end
                if word_count >= 30 and word_count <= 150 then
                    quality_score = quality_score + 5
                elseif word_count >= 15 and word_count <= 200 then
                    quality_score = quality_score + 3
                end

                -- 3. Position diversity bonus (prefer spread across document)
                local position_ratio = i / #sentences
                if position_ratio < 0.2 then -- Early in document
                    quality_score = quality_score + 3
                elseif position_ratio > 0.8 then -- Late in document
                    quality_score = quality_score + 3
                else -- Middle sections
                    quality_score = quality_score + 1
                end

                -- 4. Physical description detection bonus (valuable for X-Ray analysis)
                local description_score = 0

                -- Physical appearance descriptors
                local appearance_words = {
                    -- Colors
                    "red", "blue", "green", "yellow", "black", "white", "brown", "gray", "grey", "golden", "silver", "dark", "light", "pale", "bright",
                    -- Size/shape
                    "tall", "short", "large", "small", "huge", "tiny", "wide", "narrow", "thick", "thin", "broad", "slender", "massive", "enormous",
                    -- Texture/material
                    "rough", "smooth", "soft", "hard", "wooden", "stone", "metal", "cloth", "silk", "leather", "fur", "glass", "crystal",
                    -- Age/condition
                    "old", "young", "ancient", "new", "worn", "fresh", "weathered", "polished", "rusty", "shiny", "dull", "cracked", "broken"
                }

                -- Body parts and facial features (for character descriptions)
                local physical_features = {
                    "eyes", "hair", "face", "hands", "arms", "legs", "nose", "mouth", "lips", "chin", "forehead", "cheeks", "beard", "mustache",
                    "shoulders", "chest", "back", "skin", "complexion", "build", "figure", "stature", "posture", "gait", "voice"
                }

                -- Architecture and place descriptors
                local place_descriptors = {
                    "building", "house", "castle", "tower", "room", "hall", "chamber", "garden", "courtyard", "street", "road", "path", "bridge",
                    "mountain", "hill", "valley", "river", "lake", "forest", "field", "meadow", "desert", "ocean", "sea", "shore", "cliff",
                    "walls", "ceiling", "floor", "windows", "doors", "columns", "stairs", "roof", "basement", "attic"
                }

                -- Clothing and accessories
                local clothing_items = {
                    "dress", "shirt", "coat", "cloak", "robe", "hat", "cap", "boots", "shoes", "gloves", "ring", "necklace", "bracelet",
                    "sword", "dagger", "staff", "crown", "helmet", "armor", "shield", "belt", "buckle", "jewel", "gem"
                }

                -- Sensory descriptors
                local sensory_words = {
                    -- Visual
                    "gleaming", "glowing", "sparkling", "shimmering", "glittering", "blazing", "flickering", "shadowy", "misty", "clear",
                    -- Touch/feel
                    "cold", "warm", "hot", "cool", "freezing", "burning", "wet", "dry", "damp", "moist", "sticky", "slippery",
                    -- Sound
                    "loud", "quiet", "silent", "echoing", "ringing", "whispering", "thundering", "creaking", "rustling",
                    -- Smell
                    "fragrant", "sweet", "bitter", "sour", "musty", "fresh", "stale", "perfumed", "smoky"
                }

                local context_lower = context_text:lower()

                -- Count appearance descriptors
                for _, word in ipairs(appearance_words) do
                    if context_lower:find("%f[%w]" .. word .. "%f[%W]") then
                        description_score = description_score + 3
                    end
                end

                -- Count physical features (high value for character descriptions)
                for _, feature in ipairs(physical_features) do
                    if context_lower:find("%f[%w]" .. feature .. "%f[%W]") then
                        description_score = description_score + 4
                    end
                end

                -- Count place descriptors
                for _, place in ipairs(place_descriptors) do
                    if context_lower:find("%f[%w]" .. place .. "%f[%W]") then
                        description_score = description_score + 3
                    end
                end

                -- Count clothing/accessories (good for character identification)
                for _, item in ipairs(clothing_items) do
                    if context_lower:find("%f[%w]" .. item .. "%f[%W]") then
                        description_score = description_score + 3
                    end
                end

                -- Count sensory descriptors
                for _, sensory in ipairs(sensory_words) do
                    if context_lower:find("%f[%w]" .. sensory .. "%f[%W]") then
                        description_score = description_score + 2
                    end
                end

                -- Bonus for comparative language (helps with relative descriptions)
                local comparative_patterns = {
                    "like", "as.*as", "than", "similar to", "resembled", "reminded.*of", "looked like", "appeared to be"
                }
                for _, pattern in ipairs(comparative_patterns) do
                    if context_lower:find(pattern) then
                        description_score = description_score + 2
                    end
                end

                -- Bonus for measurement/quantity words (specific descriptions)
                local measurement_words = {
                    "feet", "inches", "meters", "miles", "pounds", "dozen", "hundred", "thousand", "several", "many", "few", "numerous"
                }
                for _, measure in ipairs(measurement_words) do
                    if context_lower:find("%f[%w]" .. measure .. "%f[%W]") then
                        description_score = description_score + 2
                    end
                end

                quality_score = quality_score + description_score

                -- 5. Additional contextual richness bonus
                local richness_indicators = {
                    '"[^"]*"', -- Dialogue
                    "[A-Z][a-z]+ [A-Z][a-z]+", -- Proper names
                    "said", "asked", "replied", "thought", -- Speech verbs
                    "because", "however", "therefore", "although", -- Reasoning words
                    "suddenly", "finally", "meanwhile" -- Narrative markers
                }

                for _, indicator in ipairs(richness_indicators) do
                    if context_text:find(indicator) then
                        quality_score = quality_score + 2
                    end
                end

                table.insert(all_contexts, {
                    text = context_text,
                    position = i,
                    sentence_index = i,
                    quality_score = quality_score,
                    term_frequency = term_frequency,
                    word_count = word_count
                })
            end
        end

        if #all_contexts == 0 then
            return ""
        end

        -- Sort by quality score (highest first)
        table.sort(all_contexts, function(a, b)
            return a.quality_score > b.quality_score
        end)

        -- Select the best contexts while avoiding overlap and ensuring diversity
        local selected_contexts = {}
        local used_positions = {}
        local min_distance = math.max(8, math.floor(#sentences / 20)) -- Minimum distance between selections
        local target_contexts = 8 -- Target number of contexts
        local current_length = 0

        for _, context in ipairs(all_contexts) do
            -- Check if this context is too close to already selected ones
            local too_close = false
            for pos in pairs(used_positions) do
                if math.abs(context.position - pos) < min_distance then
                    too_close = true
                    break
                end
            end

            if not too_close then
                -- Check if adding this context would exceed length limit
                local estimated_length = current_length + #context.text + 20 -- +20 for separator
                if estimated_length <= max_text_length_for_analysis and #selected_contexts < target_contexts then
                    table.insert(selected_contexts, context)
                    used_positions[context.position] = true
                    current_length = estimated_length
                elseif #selected_contexts >= target_contexts then
                    break
                end
            end
        end

        -- Sort selected contexts by document order for chronological reading
        table.sort(selected_contexts, function(a, b)
            return a.position < b.position
        end)

        -- Combine selected contexts
        if #selected_contexts > 0 then
            local context_texts = {}
            for _, context in ipairs(selected_contexts) do
                table.insert(context_texts, context.text)
            end

            local combined_context = table.concat(context_texts, "\n\n---\n\n")

            -- Final length check
            if #combined_context > max_text_length_for_analysis then
                combined_context = combined_context:sub(1, max_text_length_for_analysis)
                -- Try to end at a complete separator
                local last_separator = combined_context:reverse():find("---")
                if last_separator and last_separator < 1000 then
                    combined_context = combined_context:sub(1, #combined_context - last_separator + 3)
                end
            end

            return combined_context
        else
            return ""
        end
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
