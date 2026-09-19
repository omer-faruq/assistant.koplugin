--- Single-message renderer shared by the Ask dialog and the feature dialog.
---
--- Emits the div-carrier shapes (Question / Thought / Response / Search) so
--- both result paths stay identical; msgids here must stay byte-identical to
--- keep gettext lookups working. Headless-safe: only pure string transforms
--- plus assistant_utils / assistant_prompts (both load under test stubs).
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local strbuf = require("string.buffer")
local ASUtils = require("assistant_utils")
local Prompts = require("assistant_prompts")

local M = {}

--- Format one conversation message into viewer markdown.
--- @param message_history table full history, used for show_suggestions inheritance
--- @param message table the user/assistant message to format
--- @param opts table render options: title (string|nil book title),
---   msg_idx (integer|nil position in history), settings (KOReader settings),
---   default_config (table|nil suggestion fallback config)
--- @return string formatted markdown, "" when the message carries nothing to show
function M.formatSingleMessage(message_history, message, opts)
    if not message then return "" end
    if message.role == "user" then
        local user_message = strbuf.new()
        -- A preset prompt tags its user message with its display name; the
        -- viewer then shows the name instead of the full template text.
        -- Free questions carry no tag and use the title/content below.
        local prompt_title = ASUtils.get_attr(message, "prompt_title")
        local title = opts.title
        if prompt_title and prompt_title ~= "" then
            title = prompt_title
        end
        if title and title ~= "" then
            user_message:put(T(_('<div class="assistant-label">%1 Question</div>\n\n'), "☺"))
            user_message:putf("➤ ‹ %s ›\n", title)

            local user_input = ASUtils.get_attr(message, "user_input", "")

            -- Check if user input is available
            if user_input and user_input ~= "" then

                if user_input:find("%[BOOK TEXT BEGIN%]") then
                    user_input = user_input:gsub("%[BOOK TEXT BEGIN%].*%[BOOK TEXT END%]", "[BOOK TEXT]")
                end

                if user_input:find("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%]") then
                    user_input = user_input:gsub("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%].*%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT END%]", "[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT]")
                end

                user_message:put("➤")
                user_message:put(user_input)
                user_message:put("\n\n")
            end
            return user_message:get()
        elseif type(message.content) == "string" then
            -- shows user input prompt
            user_message:put(T(_('<div class="assistant-label">%1 Question</div>\n\n'), "☺"))
            local content = message.content

            if content:find("%[BOOK TEXT BEGIN%]") then
                content = content:gsub("%[BOOK TEXT BEGIN%].*%[BOOK TEXT END%]", "[BOOK TEXT]")
            end

            if content:find("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%]") then
                content = content:gsub("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%].*%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT END%]", "[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT]")
            end

            user_message:putf("\n➤ %s\n\n", content)
            return user_message:get()
        end
        -- Tool-payload user messages (table content, parts-only) carry no
        -- question text; a bare Question div would be junk, so show nothing.
        return ""
    elseif message.role == "assistant" then
        local assistant_content, answer_type, reasoning_section
        local kw = ASUtils.get_attr(message, "search_keywords")
        if kw then
            answer_type = _("Search")
            assistant_content = string.format("%s\n\n", kw)
        else
            answer_type = _("Response")
            assistant_content = message.content or _("(No response)")
            local show_for_this = ASUtils.get_attr(message, "show_suggestions")
            if show_for_this == nil and opts.msg_idx then
                for j = opts.msg_idx - 1, 1, -1 do
                    if message_history[j].role == "user" then
                        local v = ASUtils.get_attr(message_history[j], "show_suggestions")
                        if v ~= nil then show_for_this = v; break end
                    end
                end
            end
            if show_for_this == nil then
                show_for_this = Prompts.isSuggestionsEnabled(opts.settings, opts.default_config)
            end
            if show_for_this then
                assistant_content = ASUtils.process_suggestions(assistant_content)
            end

            -- Reasoning arrives inline at the top as a bare ```reasoning fence,
            -- mirroring the wrapper in Querier:processStream
            -- (assistant_querier.lua); the title and the `---` separator are
            -- added here so history stays clean. Split it out so it renders
            -- before the `### ✦ Response` header instead of after it.
            local reasoning_text, body = assistant_content:match(
                "^```reasoning%s*([%s%S]-)%s*```%s*([%s%S]*)$")
            if reasoning_text and reasoning_text:find("%S") then
                reasoning_section = T(_('<div class="assistant-label assistant-label--thought">%1 Deeply Thought</div>\n\n```reasoning\n%2\n```\n\n---\n\n'),
                    "※", reasoning_text)
                assistant_content = body
            end
        end

        if reasoning_section then
            return reasoning_section .. T(_('<div class="assistant-label">%1 %2</div>\n\n%3\n\n'), "✦", answer_type, assistant_content)
        end
        return T(_('<div class="assistant-label">%1 %2</div>\n\n%3\n\n'), "✦", answer_type, assistant_content)
    end
    return "" -- Should not happen for valid roles
end

return M
