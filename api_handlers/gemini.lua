local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local GeminiHandler = BaseHandler:new()

function GeminiHandler:query(message_history, gemini_settings, query_option)

    if not gemini_settings or not gemini_settings.api_key then
        return "Error: Missing API key in configuration"
    end

    local model    = gemini_settings.model or "gemini-2.0-flash"
    local base_url = gemini_settings.base_url or "https://generativelanguage.googleapis.com/v1beta/models/"
    local stream   = query_option.use_stream_mode

    local url_non_stream = string.format("%s%s:generateContent", base_url, model)
    local url_stream     = string.format("%s%s:streamGenerateContent?alt=sse", base_url, model)

    local headers = {
        ["Content-Type"]  = "application/json",
        ["x-goog-api-key"] = gemini_settings.api_key,
    }

    -- Convert OpenAI-style message_history to Gemini contents format.
    -- Also handles augmented messages that may contain Gemini-native
    -- model turns (role="model") or functionResponse user turns.
    local function toGeminiContents(messages)
        local contents      = {}
        local system_content = ""
        for _, msg in ipairs(messages) do
            if msg.role == "system" then
                system_content = system_content .. msg.content .. "\n"
            elseif msg.role == "user" then
                -- May be a plain text message or a functionResponse turn
                if msg.parts then
                    -- Already in Gemini format (functionResponse turn from augmented history)
                    table.insert(contents, msg)
                else
                    table.insert(contents, { role = "user", parts = {{ text = msg.content }} })
                end
            elseif msg.role == "assistant" then
                table.insert(contents, { role = "model", parts = {{ text = msg.content }} })
            elseif msg.role == "model" then
                -- Already a Gemini model turn (from augmented history replay)
                table.insert(contents, msg)
            else
                table.insert(contents, { role = "user", parts = {{ text = msg.content }} })
            end
        end
        return contents, system_content
    end

    -- build_request_fn for Gemini.
    -- tool_def is the Gemini function_declarations table (or nil).
    local function buildRequestBody(messages, tool_def)
        local contents, system_content = toGeminiContents(messages)

        local system_instruction = { parts = {}}
        if system_content ~= "" then
            table.insert(system_instruction.parts, { text = system_content:gsub("\n$", "") })
        end

        local generationConfig = nil
        local thinking_budget = koutil.tableGetValue(gemini_settings, "additional_parameters", "thinking_budget")
        if thinking_budget ~= nil then
            generationConfig = generationConfig or {}
            generationConfig.thinking_config = { thinking_budget = thinking_budget }
        end
        if gemini_settings.additional_parameters then
            for _, option in ipairs({"maxOutputTokens", "temperature", "topP", "topK"}) do
                if gemini_settings.additional_parameters[option] then
                    generationConfig = generationConfig or {}
                    generationConfig[option] = gemini_settings.additional_parameters[option]
                end
            end
        end

        -- tools: prefer injected search tool_def; fall back to builtin google_search
        local gemini_tools
        if tool_def then
            gemini_tools = { tool_def }
        end

        local body = {
            contents          = contents,
            system_instruction = system_instruction,
            safetySettings    = {
                { category = "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold = "BLOCK_NONE" },
                { category = "HARM_CATEGORY_HATE_SPEECH",       threshold = "BLOCK_NONE" },
                { category = "HARM_CATEGORY_HARASSMENT",        threshold = "BLOCK_NONE" },
                { category = "HARM_CATEGORY_DANGEROUS_CONTENT", threshold = "BLOCK_NONE" },
            },
            generationConfig  = generationConfig,
            tools             = gemini_tools,
        }
        return json.encode(body)
    end

    local ws_mode = query_option.use_websearch or "none"
    local tool_called = false

    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, gemini_settings, query_option, buildRequestBody, headers,
            url_non_stream, "gemini")
        if not augmented then return nil, err end
        if augmented.__direct_content then return augmented.__direct_content end
        message_history = augmented
        tool_called = true
    end

    -- Final request body
    local final_tools, final_tool_config
    if ws_mode == "builtin" then
        -- Gemini built-in Google Search grounding
        final_tools = { { google_search = {} } }
    end
    if tool_called then
        final_tool_config = {
                function_calling_config = {
                    mode                   = "NONE",
                }
            }
    end

    local final_contents, final_system = toGeminiContents(message_history)
    local final_system_instruction = nil
    if final_system ~= "" then
        final_system_instruction = { parts = {{ text = final_system:gsub("\n$", "") }} }
    end

    local generationConfig = nil
    local thinking_budget = koutil.tableGetValue(gemini_settings, "additional_parameters", "thinking_budget")
    if thinking_budget ~= nil then
        generationConfig = generationConfig or {}
        generationConfig.thinking_config = { thinking_budget = thinking_budget }
    end
    if gemini_settings.additional_parameters then
        for _, option in ipairs({"maxOutputTokens", "temperature", "topP", "topK"}) do
            if gemini_settings.additional_parameters[option] then
                generationConfig = generationConfig or {}
                generationConfig[option] = gemini_settings.additional_parameters[option]
            end
        end
    end

    local requestBodyTable = {
        contents          = final_contents,
        system_instruction = final_system_instruction,
        safetySettings    = {
            { category = "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HATE_SPEECH",       threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HARASSMENT",        threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_DANGEROUS_CONTENT", threshold = "BLOCK_NONE" },
        },
        generationConfig  = generationConfig,
        tools             = final_tools,
        tool_config       = final_tool_config,
    }
    local requestBody = json.encode(requestBodyTable)
    local url = stream and url_stream or url_non_stream

    logger.dbg("Making Gemini API request to model:", model)

    if stream then
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(url, headers, requestBody)
    end

    local success, code, response = self:makeRequest(url, headers, requestBody)
    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        logger.warn("Gemini API request failed:", {
            error        = response,
            model        = model,
            request_size = #requestBody,
            message_count = #message_history,
        })
        return nil, "Error: Failed to connect to Gemini API - " .. tostring(response)
    end

    local ok, parsed = pcall(json.decode, response)
    if not ok then
        logger.warn("JSON Decode Error:", parsed)
        return nil, "Error: Failed to parse Gemini API response"
    end

    local content = koutil.tableGetValue(parsed, "candidates", 1, "content", "parts", 1, "text")
    if content then return content end

    local err_msg = koutil.tableGetValue(parsed, "error", "message")
    if err_msg then
        return nil, err_msg
    else
        return nil, "Error: Unexpected response format from Gemini API"
    end
end

return GeminiHandler