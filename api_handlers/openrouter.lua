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

    -- -----------------------------------------------------------------------
    -- STREAM path
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        -- Determine which tools to inject for this stream request.
        local stream_tools = nil
        if ws_mode == "builtin" then
            -- OpenRouter native web-search server tool
            stream_tools = { buildWebSearchTool(openrouter_settings.additional_parameters) }
        elseif ws_mode == "serpapi" or ws_mode == "tavilyapi" then
            -- Inject standard tool definition so the LLM can issue a tool_call in the stream.
            -- The Querier's stream tool-call loop will detect it and execute the search.
            stream_tools = { self:buildExternalSearchToolDef("openai") }
        end

        local requestBodyTable = json.decode(buildRequestBody(message_history, stream_tools))
        requestBodyTable.stream = true
        local requestBody = json.encode(requestBodyTable)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(openrouter_settings.base_url, headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path
    -- -----------------------------------------------------------------------
    -- External search two-stage flow: only in non-stream mode.
    -- -----------------------------------------------------------------------
    -- NON-STREAM path
    -- -----------------------------------------------------------------------
    -- In non-stream mode, inject tool definitions if web_search is enabled.
    -- Let the Querier handle the tool-call loop and search execution.
    local tools
    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        tools = { self:buildExternalSearchToolDef("openai") }
    end

    local requestBodyTable = json.decode(buildRequestBody(message_history, tools))

    -- Built-in OpenRouter web search server tool (non-stream)
    -- https://openrouter.ai/docs/guides/features/tool-calling
    if ws_mode == "builtin" then
        requestBodyTable.tools = { buildWebSearchTool(openrouter_settings.additional_parameters) }
    end

    requestBodyTable.stream = false
    local requestBody = json.encode(requestBodyTable)

    local status, code, response = self:makeRequest(openrouter_settings.base_url, headers, requestBody)

    if not status then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: " .. (code or "unknown") .. " - " .. response
    end

    local success, responseData = pcall(json.decode, response)
    if not success or not responseData then
        logger.warn("API Error", code, response)
        return nil, "Error: Failed to parse OpenRouter API response"
    end

    -- Fast-path: plain text answer (no tool calls)
    local content = koutil.tableGetValue(responseData, "choices", 1, "message", "content")
    if content then return content end

    -- Delegate tool-call / error detection to the unified base method
    return self:parseToolCalls(responseData, "openai")
end

return OpenRouterProvider
