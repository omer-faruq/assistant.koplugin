local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OpenRouterProvider = BaseHandler:new()

-- Build the openrouter:web_search server tool entry.
-- Merges any caller-supplied options (engine, max_results, etc.)
-- from additional_parameters.web_search into the tool parameters.
local function buildWebSearchTool(additional_parameters)
    local tool = { type = "openrouter:web_search" }

    local ws_opts = koutil.tableGetValue(additional_parameters or {}, "web_search")
    if ws_opts then
        local params = {}
        for _, key in ipairs({
            "engine", "max_results", "max_total_results",
            "search_context_size", "allowed_domains", "excluded_domains"
        }) do
            if ws_opts[key] ~= nil then
                params[key] = ws_opts[key]
            end
        end
        if next(params) then
            tool.parameters = params
        end
    end

    return tool
end

function OpenRouterProvider:query(message_history, openrouter_settings, query_option)
    
    local requestBodyTable = {
        model = openrouter_settings.model,
        messages = message_history,
        max_tokens = openrouter_settings.max_tokens,
        temperature = openrouter_settings.temperature,
        stream = query_option.use_stream_mode
    }
    
    -- Handle reasoning tokens configuration
    local reasoning = koutil.tableGetValue(openrouter_settings, "additional_parameters", "reasoning")
    if reasoning then
        -- Create a copy of the reasoning configuration to avoid modifying the original settings
        requestBodyTable.reasoning = {}
        for k, v in pairs(reasoning) do
            requestBodyTable.reasoning[k] = v
        end

        -- Set exclude to true by default if not explicitly set
        if requestBodyTable.reasoning.exclude == nil then
            requestBodyTable.reasoning.exclude = true
        end
    end

    -- Enable web search via the openrouter:web_search server tool when requested.
    -- Supports optional configuration through additional_parameters.web_search:
    --   { engine, max_results, max_total_results, search_context_size,
    --     allowed_domains, excluded_domains }
    if query_option.use_websearch then
        requestBodyTable.tools = { buildWebSearchTool(openrouter_settings.additional_parameters) }
    end

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. openrouter_settings.api_key,
        ["HTTP-Referer"] = "https://github.com/omer-faruq/assistant.koplugin",
        ["X-Title"] = "assistant.koplugin"
    }

    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(openrouter_settings.base_url, headers, requestBody)
    end
    
    local status, code, response = self:makeRequest(openrouter_settings.base_url, headers, requestBody)

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

return OpenRouterProvider
