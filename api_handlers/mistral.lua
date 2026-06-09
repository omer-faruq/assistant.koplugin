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
        return json.encode(body)
    end

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. mistral_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"

    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, mistral_settings, query_option, buildRequestBody, headers,
            mistral_settings.base_url, "openai")
        if not augmented then return nil, err end
        if augmented.__direct_content then return augmented.__direct_content end
        message_history = augmented
    end

    local requestBodyTable = json.decode(buildRequestBody(message_history, nil))
    requestBodyTable.stream = query_option.use_stream_mode
    local requestBody = json.encode(requestBodyTable)
    -- Mistral requires Content-Length
    headers["Content-Length"] = tostring(#requestBody)

    if requestBodyTable.stream then
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(mistral_settings.base_url, headers, requestBody)
    end

    local status, code, response = self:makeRequest(mistral_settings.base_url, headers, requestBody)

    if status then
        local success, responseData = pcall(json.decode, response)
        if success then
            local content = koutil.tableGetValue(responseData, "choices", 1, "message", "content")
            if content then return content end
        end

        logger.warn("API Error", code, response)
        local err_msg = koutil.tableGetValue(responseData, "message") or ""
        if err_msg then return nil, "API Error: " .. err_msg end
    end

    if code == BaseHandler.CODE_CANCELLED then
        return nil, response
    end
    return nil, "Error: " .. (code or "unknown") .. " - " .. response
end

return MistralHandler
