local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local AnthropicHandler = BaseHandler:new()

local function prepare_anthropic_messages(message_history)
    local anthropic_messages = {}
    local system_content = ""
    
    -- Extract and concatenate all system prompts
    for i, msg in ipairs(message_history) do
        if msg.role == "system" then
            system_content = system_content .. msg.content .. "\n\n"
        end
    end

    -- Remove trailing newlines
    system_content = system_content:gsub("\n\n$", "")
    
    -- Process non-system messages (user and assistant)
    for i, msg in ipairs(message_history) do
        if msg.role ~= "system" then
            table.insert(anthropic_messages, {
                role = msg.role,
                content = msg.content
            })
        end
    end
    
    -- Return structured data for Anthropic API
    return {
        messages = anthropic_messages,
        system = system_content
    }
end

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


function AnthropicHandler:query(message_history, anthropic_settings, query_option)

    local headers = {
        ["Content-Type"]     = "application/json",
        ["x-api-key"]        = anthropic_settings.api_key,
        ["anthropic-version"] = koutil.tableGetValue(anthropic_settings, "additional_parameters", "anthropic_version"),
    }

    -- build_request_fn for Anthropic.
    -- tools is a list of tool definitions (or nil); assigned to body.tools directly.
    local function buildRequestBody(messages, tools)
        local prepared = prepare_anthropic_messages(messages)
        local body = {
            model      = anthropic_settings.model,
            system     = prepared.system,
            messages   = prepared.messages,
            max_tokens = koutil.tableGetValue(anthropic_settings, "additional_parameters", "max_tokens"),
        }
        -- tools is a list passed from resolveExternalSearch, or nil for the final request
        if tools then
            body.tools       = tools
            body.tool_choice = { type = "auto" }
        else
            -- Carry over any user-configured tools when not injecting search tool
            local user_tools = koutil.tableGetValue(anthropic_settings, "additional_parameters", "tools")
            if type(user_tools) == "table" and next(user_tools) ~= nil then
                body.tools = user_tools
            end
        end
        return json.encode(body)
    end

    local ws_mode = query_option.use_websearch or "none"

    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, anthropic_settings, query_option, buildRequestBody, headers,
            anthropic_settings.base_url, "anthropic")
        if not augmented then return nil, err end
        if augmented.__direct_content then return augmented.__direct_content end
        message_history = augmented
    end

    -- Final request (no search tool injection)
    local requestBodyTable = json.decode(buildRequestBody(message_history, nil))
    requestBodyTable.stream = query_option.use_stream_mode
    local requestBody = json.encode(requestBodyTable)

    if requestBodyTable.stream then
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(anthropic_settings.base_url, headers, requestBody)
    end

    local success, code, response = self:makeRequest(anthropic_settings.base_url, headers, requestBody)

    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: Failed to connect to Anthropic API - " .. tostring(response)
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

    local err_msg = koutil.tableGetValue(parsed, "error", "message") or "Error: Unexpected response format from API"
    return nil, err_msg
end

return AnthropicHandler