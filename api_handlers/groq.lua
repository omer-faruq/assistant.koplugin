local BaseHandler = require("api_handlers.base")
local json = require("json")
local logger = require("logger")

local groqHandler = BaseHandler:new()

function groqHandler:query(message_history, groq_settings)

    -- Remove is_context from body, which causes an error in groq API
    -- Need to clone the history so that we don't affect the actual message history which gets displayed
    local cloned_history = {}

    for i, message in ipairs(message_history) do
      local new_message = {}
      for k, v in pairs(message) do
        new_message[k] = v
      end

      -- Remove the is_context field in the clone
      new_message.is_context = nil

      cloned_history[i] = new_message
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
        return self:backgroudRequest(groq_settings.base_url, headers, requestBody)
    end
    
    local status, code, response = self:makeRequest(groq_settings.base_url, headers, requestBody)
    if status then
        local success, responseData = pcall(json.decode, response)
        if success and responseData and responseData.choices and responseData.choices[1] then
            return responseData.choices[1].message.content
        end
        
        -- server response error message
        logger.warn("API Error", code, response)
        if success and responseData and responseData.error and responseData.error.message then
            return nil, responseData.error.message 
        end
    end
    
    if code == BaseHandler.CODE_CANCELLED then
        return nil, response
    end
    logger.warn("groq API Error", response)
    return nil, "Error: " .. (code or "unknown") .. " - " .. response
end

return groqHandler
