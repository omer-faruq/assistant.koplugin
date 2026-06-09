local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OllamaHandler = BaseHandler:new()

function OllamaHandler:query(message_history, ollama_settings, query_option)

    local required_settings = {"base_url", "model", "api_key"}
    for _, setting in ipairs(required_settings) do
        if not ollama_settings[setting] then
            return "Error: Missing " .. setting .. " in configuration"
        end
    end

    local function buildRequestBody(messages, tools)
        local body = {
            model    = ollama_settings.model,
            messages = messages,
        }
        if tools then
            body.tools = tools
        end
        return json.encode(body)
    end

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. ollama_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"

    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, ollama_settings, query_option, buildRequestBody, headers,
            ollama_settings.base_url, "openai")
        if not augmented then return nil, err end
        if augmented.__direct_content then return augmented.__direct_content end
        message_history = augmented
    end

    local requestBodyTable = json.decode(buildRequestBody(message_history, nil))
    requestBodyTable.stream = query_option.use_stream_mode
    local requestBody = json.encode(requestBodyTable)

    if requestBodyTable.stream then
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

    -- Ollama uses message.content (not choices[].message.content)
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