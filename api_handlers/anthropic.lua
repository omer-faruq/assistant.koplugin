local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local AnthropicHandler = BaseHandler:new()

function AnthropicHandler:query(message_history, anthropic_settings)

    if not anthropic_settings or not anthropic_settings.api_key then
        return "Error: Missing API key in configuration"
    end
    
    local messages = {}
    for _, msg in ipairs(message_history) do
        if msg.role ~= "system" then
            table.insert(messages, {
                role = msg.role == "assistant" and "assistant" or "user",
                content = msg.content
            })
        end
    end

    local requestBodyTable = {
        model = anthropic_settings.model,
        messages = messages,
        max_tokens = koutil.tableGetValue(anthropic_settings, "additional_parameters", "max_tokens"),
        stream = koutil.tableGetValue(anthropic_settings, "additional_parameters", "stream") or false,
    }

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = anthropic_settings.api_key,
        ["anthropic-version"] = koutil.tableGetValue(anthropic_settings, "additional_parameters", "anthropic_version")
    }
    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(anthropic_settings.base_url, headers, requestBody)
    end

    local success, code, response = self:makeRequest(anthropic_settings.base_url, headers, requestBody)

    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil,"Error: Failed to connect to Anthropic API - " .. tostring(response)
    end

    local success_parse, parsed = pcall(json.decode, response)
    if not success_parse then
        logger.warn("JSON Decode Error:", parsed)
        return nil, "Error: Failed to parse Anthropic API response"
    end
    
    local content = koutil.tableGetValue(parsed, "content", 1, "text")
    if content then return content end

    local err_msg = koutil.tableGetValue(parsed, "error", "message")
    if err_msg then
        return nil, err_msg
    else
        return nil, "Error: Unexpected response format from API"
    end
end

return AnthropicHandler