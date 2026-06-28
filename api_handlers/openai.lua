local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OpenAIHandler = BaseHandler:new()

--- Build a JSON request body for the OpenAI-compatible API.
--- @param messages  table   message history
--- @param settings  table   provider settings
--- @param tools     table|nil  tool definitions (nil → no tool_calls)
--- @param stream    boolean|nil
--- @return table    requestBody 
local function buildRequestBody(messages, settings, tools, stream)
    local body = {
        model      = settings.model,
        messages   = messages,
        max_tokens = settings.max_tokens,
        stream     = stream or false,
    }
    if tools then
        body.tools       = tools
        body.tool_choice = "auto"
    end
    return body
end

function OpenAIHandler:query(message_history, openai_settings, query_option)

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. openai_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"

    -- -----------------------------------------------------------------------
    -- STREAM path: build body and return a background function immediately.
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        local tools
        if ws_mode == "serpapi" or ws_mode == "tavilyapi" or ws_mode == "searxng" then
            tools = { self:buildExternalSearchToolDef("openai") }
        end
        local body = buildRequestBody(message_history, openai_settings, tools, true)

        local requestBody = json.encode(body)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(openai_settings.base_url, headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path: synchronous makeRequest, may return tool_call table.
    -- -----------------------------------------------------------------------
    -- In non-stream mode, inject tool definitions if web_search is enabled.
    -- Let the Querier handle the tool-call loop and search execution.
    local requestBody
    if ws_mode == "serpapi" or ws_mode == "tavilyapi" or ws_mode == "searxng" then
        local search_tool = { self:buildExternalSearchToolDef("openai") }
        requestBody = buildRequestBody(message_history, openai_settings, search_tool, false)
    else
        requestBody = buildRequestBody(message_history, openai_settings, nil, false)
    end

    local status, code, response = self:makeRequest(openai_settings.base_url, headers, requestBody)

    if not status then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        -- Try to surface a structured error message from the response body
        if response and #response > 0 then
            local ok, rd = pcall(json.decode, response)
            if ok then
                local err_msg = koutil.tableGetValue(rd, "error", "message")
                if err_msg then return nil, err_msg end
            end
        end
        return nil, "Error: " .. tostring(code or "unknown") .. " - " .. tostring(response)
    end

    local ok, responseData = pcall(json.decode, response)
    if not ok or not responseData then
        logger.warn("OpenAI: failed to parse response:", response)
        return nil, "Error: failed to parse API response"
    end

    -- Delegate content / tool-call extraction to the unified base method
    return self:parseToolCalls(responseData, "openai")
end

return OpenAIHandler
