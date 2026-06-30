local BaseHandler = require("api_handlers.base")
local json = require("rapidjson")
local koutil = require("util")
local logger = require("logger")
local UIManager = require("ui/uimanager")  
local Trapper = require("ui/trapper")
local time = require("ui/time")  
local ToolExecutor = require("assistant_tool_executor")

local groqHandler = BaseHandler:new()
local LAST_CALLED = 0
local API_CALL_DEBOUNCE_DELAY = time.s(15)

local function sleepWithInfo(seconds, info_text)
    local _coroutine = coroutine.running()
    local refresh_interval = 1
    local remaining = seconds
    while remaining > 0 do
        local wait_time = math.min(remaining, refresh_interval)
        local display_text = string.format("%s (%d seconds)", info_text, math.ceil(remaining))
        local go_on = Trapper:info(display_text, remaining < seconds)
        if not go_on then
            Trapper:clear()
            return false
        end
        local resume_func = function() coroutine.resume(_coroutine, true) end
        UIManager:scheduleIn(wait_time, resume_func)
        local result = coroutine.yield()
        UIManager:unschedule(resume_func)
        if not result then
            Trapper:clear()
            return false
        end
        remaining = remaining - wait_time
    end
    Trapper:clear()
    return true
end

--- Build the Groq request body.
--- @param messages  table
--- @param settings  table
--- @param tools     table|nil
--- @param stream    boolean|nil
--- @return table    requestBody 
local function buildRequestBody(messages, settings, tools, stream)
    local body = {
        model    = settings.model,
        messages = messages,
        stream   = stream or false,
    }
    if settings.additional_parameters then
        for _, option in ipairs({
                "temperature", "top_p", "max_completion_tokens", "max_tokens",
                "reasoning_effort", "reasoning_format", "search_settings" }) do
            if settings.additional_parameters[option] then
                body[option] = settings.additional_parameters[option]
            end
        end
    end
    if tools then
        body.tools       = tools
        body.tool_choice = "auto"
    end
    return body
end

function groqHandler:query(message_history, groq_settings, query_option)

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. groq_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"

    if ws_mode ~= "none" and ws_mode ~= "builtin" then
        -- TOOL CALLS are likely trigger groq API Free-tier rate limits (8k tokens/minutes)
        local current_time = UIManager:getElapsedTimeSinceBoot()
        if current_time - LAST_CALLED < API_CALL_DEBOUNCE_DELAY then
            local time_since_last_request = current_time - LAST_CALLED
            local delay_secs = time.to_number(API_CALL_DEBOUNCE_DELAY - time_since_last_request)
            if not sleepWithInfo(delay_secs, string.format("Groq API Wait", delay_secs)) then
                return nil, self.CODE_CANCELLED
            end
        end
        LAST_CALLED = UIManager:getElapsedTimeSinceBoot()
    end

    -- -----------------------------------------------------------------------
    -- STREAM path
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        local body = buildRequestBody(message_history, groq_settings, nil, true)

        -- Built-in web search for groq/compound* models
        if ws_mode == "builtin" and groq_settings.model:find("^groq/compound") then
            body.compound_custom = { tools = { enabled_tools = { "web_search", "visit_website" } } }
        elseif ToolExecutor.IsExtSearch(ws_mode) then
            body.tools = { self:buildExternalSearchToolDef("openai") }
        end
        local requestBody = json.encode(body)

        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(groq_settings.base_url, headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path
    -- -----------------------------------------------------------------------
    -- In non-stream mode, inject tool definitions if web_search is enabled.
    -- Let the Querier handle the tool-call loop and search execution.
    local tools
    if ToolExecutor.IsExtSearch(ws_mode) then
        tools = { self:buildExternalSearchToolDef("openai") }
    end
    local body = buildRequestBody(message_history, groq_settings, tools, false)

    if ws_mode == "builtin" and groq_settings.model:find("^groq/compound") then
        body.compound_custom = {
            tools = { enabled_tools = { "web_search", "visit_website" } }
        }
    end

    local requestBody = json.encode(body)
    local status, code, response = self:makeRequest(groq_settings.base_url, headers, requestBody)

    if not status then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        if response and #response > 0 then
            local ok, rd = pcall(json.decode, response)
            if ok then
                local err_msg = koutil.tableGetValue(rd, "error", "message")
                if err_msg then return nil, err_msg end
            end
        end
        logger.warn("Groq API error:", code, response)
        return nil, "Error: " .. (code or "unknown") .. " - " .. tostring(response)
    end

    local ok, responseData = pcall(json.decode, response)
    if not ok or not responseData then
        logger.warn("Groq: failed to parse response:", response)
        return nil, "Error: failed to parse API response"
    end

    return self:parseToolCalls(responseData, "openai")
end

return groqHandler
