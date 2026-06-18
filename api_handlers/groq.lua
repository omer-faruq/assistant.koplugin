local BaseHandler = require("api_handlers.base")
local json = require("rapidjson")
local koutil = require("util")
local logger = require("logger")

local groqHandler = BaseHandler:new()

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

    -- -----------------------------------------------------------------------
    -- STREAM path
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        local body = buildRequestBody(message_history, groq_settings, nil, true)

        -- Built-in web search for groq/compound* models
        if ws_mode == "builtin" and groq_settings.model:find("^groq/compound") then
            body.compound_custom = { tools = { enabled_tools = { "web_search", "visit_website" } } }
        elseif ws_mode == "serpapi" or ws_mode == "tavilyapi" then
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
    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
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
