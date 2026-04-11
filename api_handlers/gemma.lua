local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OpenAIHandler = BaseHandler:new()

function OpenAIHandler:query(message_history, openai_settings)

-- This will print the entire call hierarchy
    print("--- CALL HIERARCHY ---")
    print(debug.traceback())
    print("----------------------")
    
    print("Handler Used: OpenAIHandler")
    local requestBodyTable = {
        model = openai_settings.model,
        messages = message_history,
        max_tokens = openai_settings.max_tokens,
        --stream = koutil.tableGetValue(openai_settings, "additional_parameters", "stream") or false,
        stream = false,
    }

    local requestBody = json.encode(requestBodyTable)
    print("requestBody", requestBody)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (openai_settings.api_key)
    }
    print("headers", headers)

    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(openai_settings.base_url, headers, requestBody)
    end
    

    local status, code, response = self:makeRequest(openai_settings.base_url, headers, requestBody)
    print("Status", status)
    if response then
    response = response:gsub("<thought>.-</thought>", "")
	end
	local file = io.open("/home/stefanr/Documents/Kindle Jailbreak/debug_response.json", "w")
	if file then
		file:write(response)
		file:close()
	end
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

return OpenAIHandler
