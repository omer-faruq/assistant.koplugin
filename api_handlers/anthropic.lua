local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")
local AnthropicMessages = require("api_handlers.anthropic_messages")

local AnthropicHandler = BaseHandler:new()

local function extract_text_from_content(content_blocks)
    if type(content_blocks) ~= "table" then
        return nil
    end

    local text_chunks = {}
    for _, block in ipairs(content_blocks) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            table.insert(text_chunks, block.text)
        end
    end

    if #text_chunks > 0 then
        return table.concat(text_chunks, "\n\n")
    end
end


function AnthropicHandler:query(message_history, anthropic_settings)
    
    local requestBodyTable = AnthropicMessages.prepare(message_history)
    requestBodyTable.model = anthropic_settings.model
    requestBodyTable.max_tokens = koutil.tableGetValue(anthropic_settings, "additional_parameters", "max_tokens")
    requestBodyTable.stream = koutil.tableGetValue(anthropic_settings, "additional_parameters", "stream") or false
    local tools = koutil.tableGetValue(anthropic_settings, "additional_parameters", "tools")
    if type(tools) == "table" and next(tools) ~= nil then
        requestBodyTable.tools = tools
    end

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = anthropic_settings.api_key,
        ["anthropic-version"] = koutil.tableGetValue(anthropic_settings, "additional_parameters", "anthropic_version")
    }
    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(anthropic_settings.base_url, headers, requestBody)
    end

    local success, code, response = self:makeRequest(anthropic_settings.base_url, headers, requestBody)

    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil,"Error: Failed to connect to Anthropic API - " .. tostring(response)
    end

    local success_parse, parsed = pcall(json.decode, response)
    if not success_parse then
        logger.warn("JSON Decode Error:", parsed)
        return nil, "Error: Failed to parse Anthropic API response"
    end

    local content = extract_text_from_content(parsed.content)
    if type(content) ~= "string" or #content == 0 then
        content = koutil.tableGetValue(parsed, "content", 1, "text")
    end
    if type(content) == "string" and #content > 0 then
        return content
    end

    local err_msg = koutil.tableGetValue(parsed, "error", "message")
    if err_msg then
        return nil, err_msg
    else
        return nil, "Error: Unexpected response format from API"
    end
end

return AnthropicHandler