local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local MistralHandler = BaseHandler:new()

function MistralHandler:query(message_history, mistral_settings, query_option)

    local function buildRequestBody(messages, tools)
        local body = {
            model    = mistral_settings.model,
            messages = messages,
        }
        if mistral_settings.additional_parameters then
            --- available req body args: https://docs.mistral.ai/api/
            for _, option in ipairs({"temperature", "top_p", "n", "max_tokens"}) do
                if mistral_settings.additional_parameters[option] then
                    body[option] = mistral_settings.additional_parameters[option]
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
        ["Authorization"] = "Bearer " .. mistral_settings.api_key,
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
        -- Mistral requires Content-Length
        headers["Content-Length"] = tostring(#requestBody)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(mistral_settings.base_url, headers, requestBody)
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
    local requestBodyTable = buildRequestBody(message_history, tools)
    requestBodyTable.stream = false
    local requestBody = json.encode(requestBodyTable)
    -- Mistral requires Content-Length
    headers["Content-Length"] = tostring(#requestBody)

    local status, code, response = self:makeRequest(mistral_settings.base_url, headers, requestBody)

    if not status then
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

return MistralHandler
