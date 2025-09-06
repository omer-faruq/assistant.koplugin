local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OllamaHandler = BaseHandler:new()

function OllamaHandler:query(message_history, ollama_settings)

    local required_settings = {"base_url", "model", "api_key"}
    for _, setting in ipairs(required_settings) do
      if not ollama_settings[setting] then
        return "Error: Missing " .. setting .. " in configuration"
      end
    end

    -- Ollama uses OpenAI-compatible API format
    local requestBodyTable = {
        model = ollama_settings.model,
        messages = message_history,
        stream = koutil.tableGetValue(ollama_settings, "additional_parameters", "stream") or false,
    }

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. ollama_settings.api_key
    }

    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(ollama_settings.base_url, headers, requestBody)
    end
    
    local success, code, response = self:makeRequest(ollama_settings.base_url, headers, requestBody)
    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: Failed to connect to Ollama API - " .. tostring(response)
    end

    local success_parse, parsed = pcall(json.decode, response)
    if not success_parse then
        logger.warn("JSON Decode Error:", parsed)
        return nil, "Error: Failed to parse Ollama API response"
    end

    local content = koutil.tableGetValue(parsed, "message", "content")
    if content then return content end

    local err_msg = koutil.tableGetValue(parsed, "error")
    if err_msg then
        return nil, err_msg
    else
        return nil, "Error: Unexpected response format from API"
    end
end

return OllamaHandler