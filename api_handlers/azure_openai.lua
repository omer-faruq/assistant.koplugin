local BaseHandler = require("api_handlers.base")
local koutil = require("util")
local json = require("json")
local logger = require("logger")

local AzureOpenAIHandler = BaseHandler:new()

function AzureOpenAIHandler:query(message_history, azure_settings, query_option)

    -- Check required settings
    for _, setting in ipairs({"api_key", "endpoint", "deployment_name", "api_version"}) do
        if not azure_settings or not azure_settings[setting] then
            return nil, "Error: Missing " .. setting .. " in configuration"
        end
    end

    -- Construct the Azure OpenAI API URL
    local api_url = string.format(
        "%s/openai/deployments/%s/chat/completions?api-version=%s",
        azure_settings.endpoint:gsub("/$", ""),
        azure_settings.deployment_name,
        azure_settings.api_version
    )

    local function buildRequestBody(messages, tools)
        local body = {
            messages    = messages,
            max_tokens  = azure_settings.max_tokens,
            temperature = azure_settings.temperature or 0.7,
        }
        if tools then
            body.tools       = tools
            body.tool_choice = "auto"
        end
        return json.encode(body)
    end

    local headers = {
        ["Content-Type"]  = "application/json",
        ["api-key"]       = azure_settings.api_key,
        ["HTTP-Referer"]  = "https://github.com/omer-faruq/assistant.koplugin",
        ["X-Title"]       = "assistant.koplugin",
    }

    local ws_mode = query_option.use_websearch or "none"

    -- In non-stream mode, inject tool definitions if web_search is enabled.
    -- Let the Querier handle the tool-call loop and search execution.
    local tools
    if not query_option.use_stream_mode and (ws_mode == "serpapi" or ws_mode == "tavilyapi" or ws_mode == "searxng") then
        tools = { self:buildExternalSearchToolDef("openai") }
    end

    local requestBodyTable = json.decode(buildRequestBody(message_history, tools))
    requestBodyTable.stream = query_option.use_stream_mode
    local requestBody = json.encode(requestBodyTable)

    if requestBodyTable.stream then
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(api_url, headers, requestBody)
    end

    local status, code, response = self:makeRequest(api_url, headers, requestBody)

    if not status or code ~= 200 then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: " .. (code or "unknown") .. " - " .. response
    end

    local success, responseData = pcall(json.decode, response)
    if not success or not responseData then
        logger.warn("API Error", code, response)
        return nil, "Error: Failed to parse Mistral API response"
    end

    -- Delegate tool-call / error detection to the unified base method
    if koutil.tableGetValue(responseData, "choices", 1, "message", "tool_calls") then
        return self:parseToolCalls(responseData, "openai")
    end

    return koutil.tableGetValue(responseData, "choices", 1, "message", "content")
end

return AzureOpenAIHandler