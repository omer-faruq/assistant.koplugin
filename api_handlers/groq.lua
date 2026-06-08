local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local groqHandler = BaseHandler:new()

function groqHandler:query(message_history, groq_settings, query_option)

    -- Build a Groq request body table from messages, with an optional tools list.
    -- Used both for normal requests and for the external-search stage-1 request.
    local function buildRequestBody(messages, tools)
        local body = {
            model    = groq_settings.model,
            messages = messages,
        }
        if groq_settings.additional_parameters then
            --- available req body args: https://console.groq.com/docs/api-reference
            for _, option in ipairs({"temperature", "top_p", "max_completion_tokens", "max_tokens",
                                        "reasoning_effort", "reasoning_format", "search_settings"}) do
                if groq_settings.additional_parameters[option] then
                    body[option] = groq_settings.additional_parameters[option]
                end
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
        ["Authorization"] = "Bearer " .. groq_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"

    -- External search modes: two-stage tool-call flow, always non-streaming for stage 1
    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, groq_settings, query_option, buildRequestBody, headers)
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

    -- Assemble the final request body (no tools for the final / non-search request)
    local requestBodyTable = json.decode(buildRequestBody(message_history, nil))

    -- Built-in web search: only for groq/compound* models
    -- https://console.groq.com/docs/tool-use/built-in-tools/web-search
    if ws_mode == "builtin" and groq_settings.model:find("^groq/compound") then
        requestBodyTable.compound_custom = {
            tools = {
                enabled_tools = { "web_search", "visit_website" }
            }
        }
    end

    requestBodyTable.stream = query_option.use_stream_mode

    local requestBody = json.encode(requestBodyTable)

    if requestBodyTable.stream then
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(groq_settings.base_url, headers, requestBody)
    end

    local status, code, response = self:makeRequest(groq_settings.base_url, headers, requestBody)
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
    logger.warn("groq API Error", response)
    return nil, "Error: " .. (code or "unknown") .. " - " .. response
end

return groqHandler