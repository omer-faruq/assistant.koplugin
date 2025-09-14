local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local groqHandler = BaseHandler:new()

function groqHandler:query(message_history, groq_settings)

    -- Groq API accepts only 'role' and 'content' fields in messages
    -- Doc: https://console.groq.com/docs/api-reference
    local cloned_history = {}
    for i, message in ipairs(message_history) do
      cloned_history[i] = {
        role = message.role,
        content = message.content,
      }
      if message.name then cloned_history[i].name = message.name end
      if message.reasoning then cloned_history[i].reasoning = message.reasoning end
    end
    
    local requestBodyTable = {
        model = groq_settings.model,
        messages = cloned_history,
    }

    -- Handle reasoning tokens configuration
    if groq_settings.additional_parameters then
        --- available req body args: https://console.groq.com/docs/api-reference
        for _, option in ipairs({"temperature", "top_p", "max_completion_tokens", "max_tokens", 
                                    "reasoning_effort", "reasoning_format", "search_settings", "stream"}) do
            if groq_settings.additional_parameters[option] then
                requestBodyTable[option] = groq_settings.additional_parameters[option]
            end
        end
    end

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (groq_settings.api_key)
    }

    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(groq_settings.base_url, headers, requestBody)
    end
    
    local status, code, response = self:makeRequest(groq_settings.base_url, headers, requestBody)
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
    logger.warn("groq API Error", response)
    return nil, "Error: " .. (code or "unknown") .. " - " .. response
end

return groqHandler
