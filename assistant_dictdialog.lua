local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("assistant_viewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Event = require("ui/event")
local koutil = require("util")
local ASUtils = require("assistant_utils")
local TextUtils = require("assistant_text_utils")
local DocUtils = require("assistant_doc_utils")
local TermXray = require("assistant_term_xray")
local Prompts = require("assistant_prompts")
local dict_prompts = Prompts.assistant_prompts.dict
local term_xray_prompts = Prompts.builtin_prompts.term_xray

-- Original book text immediately before/after the selected word. Shared by the
-- Dictionary excerpt and Term X-Ray so both can show and send the term's own
-- sentence. Returns "", "" when the selection API is unavailable.
local function extractSelectedWordContext(ui, highlightedText)
    local prev_context, next_context = "", ""
    if not (ui.highlight and ui.highlight.getSelectedWordContext) then
        return prev_context, next_context
    end

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

    return prev_context, next_context
end

local function showDictionaryDialog(assistant, highlightedText, message_history, prompt_type)
    local Querier = assistant.querier
    local ui = assistant.ui

    -- Prefer already-loaded querier; fallback to getActiveProviderId.
    local provider = (assistant.querier and assistant.querier.provider_name
                      and assistant.querier:is_inited())
                     and assistant.querier.provider_name
                     or assistant.config:getActiveProviderId()
    if not provider then
        UIManager:show(InfoMessage:new{ icon = "notice-warning",
            text = _("No active provider configured. Please add one in Settings.") })
        return
    end
    local ok, err = Querier:load_model(provider)
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
    local context_text = ""
    local context_sentence_count = 0
    local dict_language = assistant.settings:readSetting("dict_language") or assistant.ui_language

    -- Original text around the selected word, shared by both prompt types: the
    -- Dictionary builds its excerpt from it and Term X-Ray feeds it to the
    -- model so the term's own sentence is always present.
    local prev_context, next_context = extractSelectedWordContext(ui, highlightedText)

    if prompt_type == "term_xray" then
        -- Show the loading dialog immediately to avoid the app appearing frozen during the anchor scan
        local context_loading_msg = InfoMessage:new{
            icon = "book.opened",
            text = TextUtils.bold_format(_("<b>Analyzing book context for Term X-Ray...</b>")),
        }

        -- The whole blocking analysis runs under pcall so a malformed book
        -- never leaves the loading dialog on screen.
        local analysis_ok, analysis_err = pcall(function()
            UIManager:show(context_loading_msg)
            UIManager:forceRePaint()  -- Force immediate display before blocking the anchor scan

            -- Include the page the reader is on (and a couple ahead): the
            -- extraction otherwise stops at the top of the current view, which
            -- would exclude the selected term's own occurrence.
            local book_text = DocUtils.extractBookTextForAnalysis(assistant, 2)

            if book_text and #book_text > 100 then
                local all_sentences = TermXray.split_sentences(book_text)
                local term = TextUtils.strip_selection_punctuation(highlightedText)
                local term_indices = TermXray.find_term_indices(all_sentences, term)
                local max_characters = assistant.config:getFeature("term_xray_max_characters", 60000)
                local built = TermXray.build_anchor_context(all_sentences, term_indices, {
                    sentences_before = assistant.config:getFeature("term_xray_context_sentences_before", 5),
                    sentences_after = assistant.config:getFeature("term_xray_context_sentences_after", 5),
                    max_occurrences = assistant.config:getFeature("term_xray_max_occurrences", 40),
                    max_characters = max_characters,
                })
                context_text = built.text
                context_sentence_count = built.sentence_count
            else
                -- Fallback to standard context if book text is too short
                context_text = prev_context .. highlightedText .. next_context
            end
        end)

        -- Always dismiss the loading dialog, even if analysis failed.
        UIManager:close(context_loading_msg)

        if not analysis_ok then
            logger.warn("Term X-Ray context analysis failed: " .. tostring(analysis_err))
            context_text = prev_context .. highlightedText .. next_context
            context_sentence_count = 0
        end
    else
        -- Standard dictionary context extraction
        context_text = prev_context .. highlightedText .. next_context
    end

    -- Get book information (shared by both branches)
    local prop = ui.document:getProps() or {}
    local book_title = prop.title or "Unknown Title"
    local book_author = prop.authors or "Unknown Author"

    -- Choose the appropriate prompt and context based on prompt type
    local user_prompt, context_content, title
    if prompt_type == "term_xray" then
        user_prompt = term_xray_prompts.user_prompt
        -- Prepend the term's immediate surroundings to the anchor-selected
        -- context so the model always sees its own sentence.
        local context_parts = {}
        if prev_context ~= "" or next_context ~= "" then
            table.insert(context_parts, prev_context .. highlightedText .. next_context)
        end
        if context_text and context_text ~= "" then
            table.insert(context_parts, context_text)
        end
        context_content = table.concat(context_parts, "\n\n")
        title = Prompts.getDisplayText(_("Term X-Ray"),
            term_xray_prompts.use_websearch or false,
            Prompts.isWebSearchEnabled(assistant.settings))
        local context_message = {
            role = "user",
            content = string.gsub(user_prompt, "{([%w_]+)}", {
                language = dict_language,
                context = context_content,
                context_sentence_count = context_sentence_count,
                highlight = highlightedText,
                title = book_title,
                author = book_author,
                user_input = "",
                koreader_version = Prompts.getKoreaderVersion(),
            }),
        }
        ASUtils.set_attr(context_message, "prompt_title", title)
        table.insert(message_history, context_message)
    else
        user_prompt = Prompts.build_dict_prompt(
            Prompts.resolveDictSections(assistant.settings),
            { concise = assistant.settings:readSetting("dict_concise", false) })
        context_content = prev_context .. highlightedText .. next_context
        title = _("Dictionary")
        local context_message = {
            role = "user",
            content = string.gsub(user_prompt, "{([%w_]+)}", {
                language = dict_language,
                context = context_content,
                word = TextUtils.strip_selection_punctuation(highlightedText),
                title = book_title,
                author = book_author,
                koreader_version = Prompts.getKoreaderVersion(),
            }),
        }
        ASUtils.set_attr(context_message, "prompt_title", title)
        table.insert(message_history, context_message)
    end

    -- Query the AI with the message history
    local ret, err = Querier:query(message_history, title)
    if err ~= nil then
        assistant.querier:showError(err, message_history)
        return
    end

    -- Suggestion switch for this prompt (off for dict and term_xray): the
    -- shared formatter falls back to it when messages carry no attr.
    local prompt_config = (prompt_type == "term_xray") and term_xray_prompts or dict_prompts

    do
        local assistant_msg = {
            role = "assistant",
            content = ret,
        }
        ASUtils.set_attr(assistant_msg, "show_suggestions", Prompts.isSuggestionsEnabled(assistant.settings, prompt_config))
        table.insert(message_history, assistant_msg)
    end

    local function createResultText(highlightedText)
        -- Limit prev_context to last 100 bytes and next_context to first 100 bytes,
        -- backing off to UTF-8 character boundaries and snapping to word
        -- boundaries so no partial word is shown
        local prev_context_limited = TermXray.clip_excerpt(prev_context, 100, "tail")
        local next_context_limited = TermXray.clip_excerpt(next_context, 100, "head")
        -- Walk the history past the system prompt and format each message
        -- with assistant_text_utils (Search/Thought/Response divs,
        -- reasoning split, suggestion switch), so Search divs the querier
        -- appended in place render alongside the answer. Minimalist mode
        -- assembles the answer-only shape (no carriers) instead.
        local minimal = assistant.settings:readSetting("minimalist_mode", false)
        local result_parts = {}
        for idx = 2, #message_history do
            local message = message_history[idx]
            local is_context = ASUtils.get_attr(message, "is_context")
            if not is_context then
                table.insert(result_parts, TextUtils.formatSingleMessage(message_history, message, {
                    title = nil,
                    msg_idx = idx,
                    settings = assistant.settings,
                    default_config = prompt_config,
                    minimal = minimal,
                }))
            end
        end
        -- Normalize the selection's whitespace before bolding it: a leading or
        -- trailing space in "** word **" stops Markdown from rendering bold.
        -- The %4 slot carries the formatted history; the msgid is unchanged
        -- so existing translations keep matching.
        return T("... %1 **%2** %3 ...\n\n%4", prev_context_limited, koutil.cleanupSelectedText(highlightedText), next_context_limited, table.concat(result_parts))
    end

    local result = createResultText(highlightedText)
    local chatgpt_viewer

    chatgpt_viewer = ChatGPTViewer:new {
        assistant = assistant,
        ui = ui,
        title = title,
        text = result,
        extra_buttons = {
            {
                -- @translators Button text: adds the word to the Vocabulary Builder. Keep it short.
                text = _("Vocabulary Builder"),
                callback = function()
                    if not ui then return end
                    local word = TextUtils.strip_selection_punctuation(highlightedText)
                    if not word or word == "" then
                        UIManager:show(InfoMessage:new{
                            icon = "notice-warning",
                            text = _("No word to add"),
                            timeout = 2,
                        })
                        return
                    end
                    ui:handleEvent(Event:new("WordLookedUp", word, book_title, true))
                    UIManager:show(InfoMessage:new{
                        text = _("Added to vocabulary builder"),
                        timeout = 2,
                    })
                end,
                hold_callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Saves the word to the vocabulary builder"),
                    })
                end,
            },
        },
        -- Re-assemble the result so a display switch in the viewer's menu can
        -- hide what it just turned off.
        rebuild_text = function()
            return createResultText(highlightedText)
        end,
        default_hold_callback = function ()
            chatgpt_viewer:HoldClose()
        end,
    }

    UIManager:show(chatgpt_viewer)
end

return showDictionaryDialog