local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OpenAIHandler = BaseHandler:new()

--- Build a JSON request body for the OpenAI-compatible API.
--- @param messages  table   message history
--- @param settings  table   provider settings
--- @param tools     table|nil  tool definitions (nil → no tool_calls)
--- @param stream    bool|nil
--- @return string   JSON-encoded request body
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
    return json.encode(body)
end

function OpenAIHandler:query(message_history, openai_settings, query_option)

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. openai_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"

    -- External search: resolve before deciding on stream/non-stream.
    -- resolveExternalSearch is always non-streaming (stage-1 synchronous request).
    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, openai_settings, query_option,
            function(msgs, tools)
                return buildRequestBody(msgs, openai_settings, tools, false)
            end,
            headers, openai_settings.base_url, "openai")
        if not augmented then return nil, err end
        if augmented.__direct_content then return augmented.__direct_content end
        message_history = augmented
    end

    -- -----------------------------------------------------------------------
    -- STREAM path: build body and return a background function immediately.
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        local requestBody = buildRequestBody(message_history, openai_settings, nil, true)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(openai_settings.base_url, headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path: synchronous makeRequest, may return tool_call table.
    -- -----------------------------------------------------------------------
    local requestBody = buildRequestBody(message_history, openai_settings, nil, false)
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
