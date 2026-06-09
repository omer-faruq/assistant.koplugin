local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OpenAIHandler = BaseHandler:new()

function OpenAIHandler:query(message_history, openai_settings, query_option)

    local function buildRequestBody(messages, tools)
        local body = {
            model      = openai_settings.model,
            messages   = messages,
            max_tokens = openai_settings.max_tokens,
        }
        if tools then
            body.tools       = tools
            body.tool_choice = "auto"
        end
        return json.encode(body)
    end

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. openai_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"

    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, openai_settings, query_option, buildRequestBody, headers,
            openai_settings.base_url, "openai")
        if not augmented then return nil, err end
        if augmented.__direct_content then return augmented.__direct_content end
        message_history = augmented
    end

    local requestBodyTable = json.decode(buildRequestBody(message_history, nil))
    requestBodyTable.stream = query_option.use_stream_mode
    local requestBody = json.encode(requestBodyTable)

    if requestBodyTable.stream then
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(openai_settings.base_url, headers, requestBody)
    end

    local status, code, response = self:makeRequest(openai_settings.base_url, headers, requestBody)

    if status then
        local success, responseData = pcall(json.decode, response)
        if success then
            local content = koutil.tableGetValue(responseData, "choices", 1, "message", "content")
            if content then return content end
        end
    end

    if type(code) == "number" then
        local success, responseData = pcall(json.decode, response)
        if success then
            local err_msg = koutil.tableGetValue(responseData, "error", "message")
            if err_msg then return nil, err_msg end
        end
    end

    if code == BaseHandler.CODE_CANCELLED then
        return nil, response
    end
    return nil, "Error: " .. tostring(code or "unknown") .. " - " .. tostring(response)
end

return OpenAIHandler