local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")
local ToolExecutor = require("assistant_tool_executor")

local OpenAIHandler = BaseHandler:new()
OpenAIHandler.SupportedOptions = {
    ["temperature"] = true,
    ["top_p"] = true,
    ["max_completion_tokens"] = true,
    ["max_tokens"] = true,
    ["reasoning_effort"] = true,
    ["thinking_budget"] = true,
    ["reasoning_format"] = true,
    ["search_settings" ] = true,
    ["enable_thinking"] = true,
    ["thinking_budget"] = true,
}

function OpenAIHandler:SetHandlerOption(querier)
    BaseHandler.SetHandlerOption(self, querier)
    self.reasoning_key = nil
end

--- Build a JSON request body for the OpenAI-compatible API.
--- @param messages  table   message history
--- @param tools     table|nil  tool definitions (nil → no tool_calls)
--- @return table    requestBody 
function OpenAIHandler:buildRequestBody(messages, query_option, tools)
    local body = {
        model      = self.model,
        messages   = messages,
    }
    if type(self.additional_parameters) == "table" and next(self.additional_parameters) then
        for o, v in pairs(self.additional_parameters) do
            if self.SupportedOptions[o] then body[o] = v end
        end
    end
    if tools then
        body.tools       = tools
        body.tool_choice = "auto"
    end
    if query_option.use_stream_mode then
        body.stream = true
    end
    return body
end

function OpenAIHandler:query(message_history, query_option)

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. self.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"
    local tools
    if ToolExecutor.IsExtSearch(ws_mode) then
        tools = { self:buildExternalSearchToolDef("openai") }
    end
    local body = self:buildRequestBody(message_history, query_option, tools)

    -- -----------------------------------------------------------------------
    -- STREAM path: build body and return a background function immediately.
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        local requestBody = json.encode(body)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(self.base_url, headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path: synchronous makeRequest, may return tool_call table.
    -- -----------------------------------------------------------------------
    local requestBody = json.encode(body)
    local status, code, response = self:makeRequest(self.base_url, headers, requestBody)

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
        logger.warn(self.name, "failed to parse response:", response)
        return nil, "Error: failed to parse API response"
    end

    -- Delegate content / tool-call extraction to the unified base method
    return self:parseToolCalls(responseData, "openai")
end

return OpenAIHandler
