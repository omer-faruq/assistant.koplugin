local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local AnthropicHandler = BaseHandler:new()

--- Convert OpenAI-style message_history into Anthropic's wire format.
--- Returns { messages = [...], system = "..." }
local function prepareAnthropicMessages(message_history)
    local anthropic_messages = {}
    local system_content = ""

    for _, msg in ipairs(message_history) do
        if msg.role == "system" then
            system_content = system_content .. msg.content .. "\n\n"
        end
    end
    system_content = system_content:gsub("\n\n$", "")

    for _, msg in ipairs(message_history) do
        if msg.role ~= "system" then
            table.insert(anthropic_messages, { role = msg.role, content = msg.content })
        end
    end

    return { messages = anthropic_messages, system = system_content }
end

--- Extract plain text from Anthropic content-blocks array.
local function extractTextFromContent(content_blocks)
    if type(content_blocks) ~= "table" then return nil end
    local chunks = {}
    for _, block in ipairs(content_blocks) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            table.insert(chunks, block.text)
        end
    end
    return #chunks > 0 and table.concat(chunks, "\n\n") or nil
end

--- Build a JSON request body for the Anthropic API.
--- @param messages  table       message history (OpenAI style; will be converted)
--- @param settings  table       provider settings
--- @param tools     table|nil   tool definitions to inject (nil → use settings.tools or none)
--- @param stream    bool|nil
--- @return string   JSON-encoded body
local function buildRequestBody(messages, settings, tools, stream)
    local prepared = prepareAnthropicMessages(messages)
    local body = {
        model      = settings.model,
        system     = prepared.system,
        messages   = prepared.messages,
        max_tokens = koutil.tableGetValue(settings, "additional_parameters", "max_tokens"),
        stream     = stream or false,
    }

    if tools then
        -- Injected tools (e.g. from resolveExternalSearch)
        body.tools       = tools
        body.tool_choice = { type = "auto" }
    else
        -- Carry over any user-configured tools (e.g. native web_search_20250305)
        local user_tools = koutil.tableGetValue(settings, "additional_parameters", "tools")
        if type(user_tools) == "table" and next(user_tools) ~= nil then
            body.tools = user_tools
        end
    end

    return json.encode(body)
end

function AnthropicHandler:query(message_history, anthropic_settings, query_option)

    local headers = {
        ["Content-Type"]      = "application/json",
        ["x-api-key"]         = anthropic_settings.api_key,
        ["anthropic-version"] = koutil.tableGetValue(
            anthropic_settings, "additional_parameters", "anthropic_version"),
    }

    local ws_mode = query_option.use_websearch or "none"

    -- External search: always non-streaming stage-1.
    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, anthropic_settings, query_option,
            function(msgs, tools)
                return buildRequestBody(msgs, anthropic_settings, tools, false)
            end,
            headers, anthropic_settings.base_url, "anthropic")
        if not augmented then return nil, err end
        if augmented.__direct_content then return augmented.__direct_content end
        message_history = augmented
    end

    -- -----------------------------------------------------------------------
    -- STREAM path
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        local requestBody = buildRequestBody(message_history, anthropic_settings, nil, true)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(anthropic_settings.base_url, headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path
    -- -----------------------------------------------------------------------
    local requestBody = buildRequestBody(message_history, anthropic_settings, nil, false)
    local success, code, response = self:makeRequest(
        anthropic_settings.base_url, headers, requestBody)

    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: Failed to connect to Anthropic API - " .. tostring(response)
    end

    local ok, parsed = pcall(json.decode, response)
    if not ok or not parsed then
        logger.warn("Anthropic: JSON decode error:", response)
        return nil, "Error: Failed to parse Anthropic API response"
    end

    -- Fast-path: plain text answer (no tool calls)
    local content = extractTextFromContent(parsed.content)
    if type(content) == "string" and #content > 0 then
        return content
    end
    -- Fallback scalar
    local scalar = koutil.tableGetValue(parsed, "content", 1, "text")
    if type(scalar) == "string" and #scalar > 0 then
        return scalar
    end

    -- Delegate tool-call / error detection to the unified base method
    return self:parseToolCalls(parsed, "anthropic")
end

return AnthropicHandler
