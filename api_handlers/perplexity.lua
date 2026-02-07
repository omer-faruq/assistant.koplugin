local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local PerplexityHandler = BaseHandler:new()

function PerplexityHandler:query(message_history, perplexity_settings)
    if not perplexity_settings or not perplexity_settings.api_key then
        return nil, "Error: Missing API key in configuration"
    end

    -- Perplexity uses OpenAI-compatible API format
    local requestBodyTable = {
        model = perplexity_settings.model,
        messages = message_history,
        stream = koutil.tableGetValue(perplexity_settings, "additional_parameters", "stream") or false,
    }

    -- Add optional parameters if present
    if perplexity_settings.additional_parameters then
        for _, option in ipairs({"temperature", "top_p", "max_tokens", "max_completion_tokens"}) do
            if perplexity_settings.additional_parameters[option] then
                requestBodyTable[option] = perplexity_settings.additional_parameters[option]
            end
        end
    end

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. perplexity_settings.api_key
    }

    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(perplexity_settings.base_url, headers, requestBody)
    end

    local request_timeout, request_maxtime
    if requestBody and #requestBody > 10000 then -- large book analysis
        request_timeout = 500
        request_maxtime = 500
    else
        request_timeout = 45 -- block_timeout
        request_maxtime = 90 -- maxtime: total response finished max time
    end

    local success, code, response = self:makeRequest(
        perplexity_settings.base_url,
        headers,
        requestBody,
        request_timeout,
        request_maxtime
    )

    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: Failed to connect to Perplexity API - " .. tostring(response)
    end

    local success_parse, parsed = pcall(json.decode, response)
    if not success_parse then
        return nil, "Error: Failed to parse Perplexity API response: " .. response
    end

    local content = koutil.tableGetValue(parsed, "choices", 1, "message", "content")
    if content then
        return content
    end

    local err = koutil.tableGetValue(parsed, "error")
    if err and err.message then
        logger.warn("API Error:", code, response)
        return nil, "Perplexity API Error: [" .. (err.code or "unknown") .. "]: " .. err.message
    else
        logger.warn("API Error:", code, response)
        return nil, "Perplexity API Error: Unexpected response format from API: " .. response
    end
end

return PerplexityHandler
