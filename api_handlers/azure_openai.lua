local BaseHandler = require("api_handlers.base")
local koutil = require("util")
local json = require("json")
local logger = require("logger")

local AzureOpenAIHandler = BaseHandler:new()

function AzureOpenAIHandler:query(message_history, azure_settings )
    
    -- Check required settings
    for _, setting in ipairs({"api_key", "endpoint", "deployment_name", "api_version"}) do
        if not azure_settings or not azure_settings[setting] then
            return nil, "Error: Missing " .. setting .. " in configuration"
        end
    end
    
    -- Construct the Azure OpenAI API URL
    local api_url = string.format(
        "%s/openai/deployments/%s/chat/completions?api-version=%s",
        azure_settings.endpoint:gsub("/$", ""),  -- Remove trailing slash if present
        azure_settings.deployment_name,
        azure_settings.api_version
    )
    
    -- Prepare request body
    local requestBodyTable = {
        messages = message_history,
        max_tokens = azure_settings.max_tokens,
        stream = azure_settings.stream or false,
        temperature = azure_settings.temperature or 0.7
    }
    
    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["api-key"] = azure_settings.api_key,
        ["HTTP-Referer"] = "https://github.com/omer-faruq/assistant.koplugin",
        ["X-Title"] = "assistant.koplugin"
    }
    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(api_url, headers, requestBody)
    end
    
    local status, code, response = self:makeRequest(api_url, headers, requestBody)
    
    if status then
        local success, responseData = pcall(json.decode, response)
        if success then
            local content = koutil.tableGetValue(responseData, "choices", 1, "message", "content")
            if content then return content end
        end

        -- server response error message
        logger.warn("API Error", code, response)
        if success then
            local err_msg = koutil.tableGetValue(responseData, "error", "message")
            if err_msg then return nil, err_msg end
        end
    end

    if code == BaseHandler.CODE_CANCELLED then
        return nil, response
    end
    
    return nil, "Error: " .. (code or "unknown") .. " - " .. response
end

return AzureOpenAIHandler