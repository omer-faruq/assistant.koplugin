local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local DeepSeekHandler = BaseHandler:new()

function DeepSeekHandler:query(message_history, deepseek_settings, query_option)

    if not deepseek_settings or not deepseek_settings.api_key then
        return "Error: Missing API key in configuration"
    end

    local function buildRequestBody(messages, tools)
        local body = {
            model    = deepseek_settings.model,
            messages = messages,
        }
        if deepseek_settings.additional_parameters then
            -- Available request body args: https://api-docs.deepseek.com/api/create-chat-completion
            for _, option in ipairs({"temperature", "top_p", "max_tokens", "max_completion_tokens",
                                        "frequency_penalty", "presence_penalty", "stop",
                                        "thinking", "logprobs", "top_logprobs", "response_format"}) do
                if deepseek_settings.additional_parameters[option] then
                    body[option] = deepseek_settings.additional_parameters[option]
                end
            end
        end
        if tools then
            body.tools       = tools
            body.tool_choice = "auto"
        end
        return json.encode(body)
    end

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. deepseek_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"

    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, deepseek_settings, query_option, buildRequestBody, headers,
            deepseek_settings.base_url, "openai")
        if not augmented then return nil, err end
        if augmented.__direct_content then return augmented.__direct_content end
        message_history = augmented
    end

    local requestBodyTable = json.decode(buildRequestBody(message_history, nil))
    requestBodyTable.stream = query_option.use_stream_mode
    local requestBody = json.encode(requestBodyTable)

    if requestBodyTable.stream then
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(deepseek_settings.base_url, headers, requestBody)
    end

    local request_timeout, request_maxtime
    if #requestBody > 10000 then
        request_timeout = 500
        request_maxtime = 500
    else
        request_timeout = 45
        request_maxtime = 90
    end

    local success, code, response = self:makeRequest(
        deepseek_settings.base_url, headers, requestBody, request_timeout, request_maxtime)

    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: Failed to connect to DeepSeek API - " .. tostring(response)
    end

    local success_parse, parsed = pcall(json.decode, response)
    if not success_parse then
        return nil, "Error: Failed to parse DeepSeek API response: " .. response
    end

    local content = koutil.tableGetValue(parsed, "choices", 1, "message", "content")
    if content then return content end

    local err = koutil.tableGetValue(parsed, "error")
    if err and err.message then
        logger.warn("API Error:", code, response)
        return nil, "DeepSeek API Error: [" .. (err.code or "unknown") .. "]: " .. err.message
    else
        logger.warn("API Error:", code, response)
        return nil, "DeepSeek API Error: Unexpected response format from API: " .. response
    end
end

return DeepSeekHandler
