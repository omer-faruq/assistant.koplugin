local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local DeepSeekHandler = BaseHandler:new()

function DeepSeekHandler:query(message_history, deepseek_settings)

    if not deepseek_settings or not deepseek_settings.api_key then
        return "Error: Missing API key in configuration"
    end

    -- DeepSeek uses OpenAI-compatible API format
    local requestBodyTable = {
        model = deepseek_settings.model,
        messages = message_history,
        stream = koutil.tableGetValue(deepseek_settings, "additional_parameters", "stream") or false,
        max_tokens = koutil.tableGetValue(deepseek_settings, "additional_parameters", "max_tokens")
    }

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. deepseek_settings.api_key
    }

    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(deepseek_settings.base_url, headers, requestBody)
    end
    
    local request_timeout, request_maxtime
    if requestBody and #requestBody > 10000 then -- large book analysis
        request_timeout = 500
        request_maxtime = 500
    else
        request_timeout = 45 -- block_timeout, API is slow sometimes, need longer timeout
        request_maxtime = 90 -- maxtime: total response finished max time
    end

    local success, code, response = self:makeRequest(
        deepseek_settings.base_url,
        headers,
        requestBody,
        request_timeout,
        request_maxtime
    )

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
