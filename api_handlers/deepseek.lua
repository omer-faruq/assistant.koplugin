local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local DeepSeekHandler = BaseHandler:new()

function DeepSeekHandler:query(message_history, deepseek_settings, query_option)

    if not deepseek_settings or not deepseek_settings.api_key then
        return "Error: Missing API key in configuration"
    end

    local function buildRequestBody(messages, tools)
        local body = {
            model    = deepseek_settings.model,
            messages = messages,
        }
        if deepseek_settings.additional_parameters then
            -- Available request body args: https://api-docs.deepseek.com/api/create-chat-completion
            for _, option in ipairs({"temperature", "top_p", "max_tokens", "max_completion_tokens",
                                        "frequency_penalty", "presence_penalty", "stop",
                                        "thinking", "logprobs", "top_logprobs", "response_format"}) do
                if deepseek_settings.additional_parameters[option] then
                    body[option] = deepseek_settings.additional_parameters[option]
                end
            end
        end
        if tools then
            body.tools       = tools
            body.tool_choice = "auto"
        end
        return body
    end

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. deepseek_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"

    -- -----------------------------------------------------------------------
    -- STREAM path
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        -- Inject tool definition so the LLM can issue a tool_call in the stream.
        -- The Querier's stream tool-call loop will detect it and execute the search.
        local stream_tools = nil
        if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
            stream_tools = { self:buildExternalSearchToolDef("openai") }
        end
        local requestBodyTable = buildRequestBody(message_history, stream_tools)
        requestBodyTable.stream = true
        local requestBody = json.encode(requestBodyTable)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(deepseek_settings.base_url, headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path
    -- -----------------------------------------------------------------------
    -- In non-stream mode, inject tool definitions if web_search is enabled.
    -- Let the Querier handle the tool-call loop and search execution.
    local tools
    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        tools = { self:buildExternalSearchToolDef("openai") }
    end
    local requestBodyTable = buildRequestBody(message_history, tools)
    requestBodyTable.stream = false
    local requestBody = json.encode(requestBodyTable)

    local request_timeout, request_maxtime
    if #requestBody > 10000 then
        request_timeout = 500
        request_maxtime = 500
    else
        request_timeout = 45
        request_maxtime = 90
    end

    local success, code, response = self:makeRequest(
        deepseek_settings.base_url, headers, requestBody, request_timeout, request_maxtime)

    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: Failed to connect to DeepSeek API - " .. tostring(response)
    end

    local success_parse, parsed = pcall(json.decode, response)
    if not success_parse then
        return nil, "Error: Failed to parse DeepSeek API response: " .. response
    end

    -- Delegate tool-call / error detection to the unified base method
    if koutil.tableGetValue(parsed, "choices", 1, "message", "tool_calls") then
        return self:parseToolCalls(parsed, "openai")
    end

    return koutil.tableGetValue(parsed, "choices", 1, "message", "content")
end

return DeepSeekHandler
