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

    -- Build an OpenRouter request body table from messages, with an optional tools list.
    -- Used both for normal requests and for the external-search stage-1 request.
    local function buildRequestBody(messages, tools)
        local body = {
            model       = openrouter_settings.model,
            messages    = messages,
            max_tokens  = openrouter_settings.max_tokens,
            temperature = openrouter_settings.temperature,
        }

        -- Handle reasoning tokens configuration
        local reasoning = koutil.tableGetValue(openrouter_settings, "additional_parameters", "reasoning")
        if reasoning then
            body.reasoning = {}
            for k, v in pairs(reasoning) do
                body.reasoning[k] = v
            end
            if body.reasoning.exclude == nil then
                body.reasoning.exclude = true
            end
        end

        if tools then
            body.tools       = tools
            body.tool_choice = "auto"
        end

        return json.encode(body)
    end

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. openrouter_settings.api_key,
        ["HTTP-Referer"]  = "https://github.com/omer-faruq/assistant.koplugin",
        ["X-Title"]       = "assistant.koplugin",
    }

    local ws_mode = query_option.use_websearch or "none"

    -- External search modes: two-stage tool-call flow, always non-streaming for stage 1
    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, openrouter_settings, query_option, buildRequestBody, headers,
            openrouter_settings.base_url, "openai")
        if not augmented then
            return nil, err
        end
        -- Model answered directly without issuing a tool_call
        if augmented.__direct_content then
            return augmented.__direct_content
        end
        -- Replace message_history with the augmented messages for the final request
        message_history = augmented
    end

    -- Assemble the final request body
    local requestBodyTable = json.decode(buildRequestBody(message_history, nil))

    -- Built-in OpenRouter web search server tool
    -- https://openrouter.ai/docs/guides/features/tool-calling
    if ws_mode == "builtin" then
        requestBodyTable.tools = { buildWebSearchTool(openrouter_settings.additional_parameters) }
    end

    requestBodyTable.stream = query_option.use_stream_mode

    local requestBody = json.encode(requestBodyTable)

    if requestBodyTable.stream then
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
