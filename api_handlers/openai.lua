local BaseHandler = require("api_handlers.base")
local json = require("json")
local logger = require("logger")

local OpenAIHandler = BaseHandler:new()

local function extract_output_text(responseData)
    -- 1. Direct field on the response (most common)
    if responseData.output_text and responseData.output_text ~= "" then
        return responseData.output_text
    end

    -- 2. Iterate through the output array for the first chunk that contains text
    if responseData.output and type(responseData.output) == "table" then
        for _, item in ipairs(responseData.output) do
            -- Items with a direct text field
            if item.text and item.text ~= "" then
                return item.text
            end
            -- Items with nested content list (e.g., messages)
            if item.content and type(item.content) == "table" then
                for _, sub in ipairs(item.content) do
                    if sub.text and sub.text ~= "" then
                        return sub.text
                    end
                end
            end
        end
    end
    return nil
end

function OpenAIHandler:query(message_history, openai_settings)
    -- Extract the most recent user message as single-turn input, as multi-turn is not required.
    local user_message = ""
    if message_history and #message_history > 0 then
        -- find the last message with role "user"; fallback to the last message
        for i = #message_history, 1, -1 do
            local m = message_history[i]
            if m.role == "user" or i == #message_history then
                user_message = m.content or ""
                break
            end
        end
    end

    -- Determine whether to use the new Responses API or legacy Chat Completions based on the URL
    local using_responses_api = openai_settings.base_url and string.find(openai_settings.base_url, "/responses") ~= nil

    local requestBodyTable

    if using_responses_api then
        -- Convert the conversation history (excluding the system prompt) to Responses API input items
        local input_items = {}
        if message_history and #message_history > 0 then
            for _, msg in ipairs(message_history) do
                if msg.role ~= "system" then
                    table.insert(input_items, {
                        role = msg.role,
                        content = msg.content,
                    })
                end
            end
        end

        -- Fallback to single user message if somehow empty
        if #input_items == 0 then
            input_items = user_message
        end

        requestBodyTable = {
            model = openai_settings.model,
            input = input_items,
        }

        -- If the first message is a system prompt, map it to `instructions`
        if message_history and #message_history > 0 and message_history[1].role == "system" then
            requestBodyTable.instructions = message_history[1].content
        end

        -- Merge any additional parameters directly into the request body
        if openai_settings.additional_parameters then
            for k, v in pairs(openai_settings.additional_parameters) do
                if k == "max_tokens" then
                    -- map to the new parameter name
                    requestBodyTable.max_output_tokens = v
                elseif k ~= "messages" and k ~= "n" and k ~= "logprobs" and k ~= "logit_bias" and k ~= "presence_penalty" and k ~= "frequency_penalty" then
                    -- Pass through other parameters that are still valid in the Responses API
                    requestBodyTable[k] = v
                end
            end
        end

        -- Handle legacy max_tokens field mapping specified at the top level
        if openai_settings.max_tokens and not requestBodyTable.max_output_tokens then
            requestBodyTable.max_output_tokens = openai_settings.max_tokens
        end

        -- Optionally enable the built-in web search tool
        if openai_settings.enable_web_search then
            -- Ensure a tools array exists
            requestBodyTable.tools = requestBodyTable.tools or {}

            -- Check if web_search tool already present
            local has_web_search = false
            for _, t in ipairs(requestBodyTable.tools) do
                if t.type == "web_search" then
                    has_web_search = true
                    break
                end
            end

            if not has_web_search then
                table.insert(requestBodyTable.tools, { type = "web_search" })
            end
        end
    else
        -- Fallback to legacy Chat Completions format for backwards compatibility
        requestBodyTable = {
            model = openai_settings.model,
            messages = message_history,
            max_tokens = openai_settings.max_tokens
        }

        if openai_settings.additional_parameters then
            for k, v in pairs(openai_settings.additional_parameters) do
                requestBodyTable[k] = v
            end
        end
    end

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (openai_settings.api_key)
    }

    -- Web-search augmented responses can take longer; bump max timeouts when we know a tool is in play.
    local timeout, maxtime
    if using_responses_api and openai_settings.enable_web_search then
        timeout, maxtime = 60, 180 -- seconds: wait longer than defaults
    end

    local status, code, response = self:makeRequest(openai_settings.base_url, headers, requestBody, timeout, maxtime)

    if status then
        local success, responseData = pcall(json.decode, response)
        if success and responseData then
            if using_responses_api then
                local content_text = extract_output_text(responseData)
                if content_text then
                    return content_text
                end
            else
                if responseData.choices and responseData.choices[1] then
                    -- chat completion or completion style
                    if responseData.choices[1].message and responseData.choices[1].message.content then
                        return responseData.choices[1].message.content
                    elseif responseData.choices[1].text then
                        return responseData.choices[1].text
                    end
                end
            end

            -- server response error message inside JSON
            if responseData.error and responseData.error.message then
                return nil, responseData.error.message
            end
        end

        -- Couldn't parse or unexpected structure
        logger.warn("API Error", code, response)
    end

    if code == BaseHandler.CODE_CANCELLED then
        return nil, response
    end
    return nil, "Error: " .. (code or "unknown") .. " - " .. response
end

return OpenAIHandler