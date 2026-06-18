local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local GeminiHandler = BaseHandler:new()

--- Convert OpenAI-style message_history to Gemini contents + system_instruction.
--- Handles augmented messages that may already contain Gemini-native model turns
--- (role="model") or functionResponse user turns (role="user", .parts set).
---
--- @param messages table
--- @return table contents, string system_content
local function toGeminiContents(messages)
    local contents      = {}
    local system_content = ""

    for _, msg in ipairs(messages) do
        if msg.role == "system" then
            system_content = system_content .. msg.content .. "\n"
        elseif msg.role == "user" then
            if msg.parts then
                -- Already a Gemini-native turn (e.g. functionResponse from augmented history)
                table.insert(contents, msg)
            else
                table.insert(contents, { role = "user", parts = {{ text = msg.content }} })
            end
        elseif msg.role == "assistant" then
            table.insert(contents, { role = "model", parts = {{ text = msg.content }} })
        elseif msg.role == "model" then
            -- Gemini model turn replayed from augmented history
            table.insert(contents, msg)
        else
            table.insert(contents, { role = "user", parts = {{ text = msg.content }} })
        end
    end

    return contents, system_content
end

--- Collect Gemini generationConfig from provider settings.
local function buildGenerationConfig(settings)
    local gc = nil
    local thinking_budget = koutil.tableGetValue(settings, "additional_parameters", "thinking_budget")
    if thinking_budget ~= nil then
        gc = gc or {}
        gc.thinking_config = { thinking_budget = thinking_budget }
    end
    if settings.additional_parameters then
        for _, opt in ipairs({ "maxOutputTokens", "temperature", "topP", "topK" }) do
            if settings.additional_parameters[opt] then
                gc = gc or {}
                gc[opt] = settings.additional_parameters[opt]
            end
        end
    end
    return gc
end

--- Build a JSON request body for the Gemini API.
--- @param messages  table       message history
--- @param settings  table       provider settings
--- @param tool_def  table|nil   Gemini-format tool object (or nil)
--- @param stream    boolean|nil
--- @return string   JSON-encoded body
local function buildRequestBody(messages, settings, tool_def, stream)
    local contents, system_content = toGeminiContents(messages)

    local system_instruction = nil
    if system_content ~= "" then
        system_instruction = { parts = {{ text = system_content:gsub("\n$", "") }} }
    end

    local tools = tool_def and { tool_def } or nil

    local body = {
        contents           = contents,
        system_instruction = system_instruction,
        safetySettings     = {
            { category = "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HATE_SPEECH",       threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HARASSMENT",        threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_DANGEROUS_CONTENT", threshold = "BLOCK_NONE" },
        },
        generationConfig   = buildGenerationConfig(settings),
        tools              = tools,
    }
    return json.encode(body)
end

function GeminiHandler:query(message_history, gemini_settings, query_option)

    if not gemini_settings or not gemini_settings.api_key then
        return nil, "Error: Missing API key in configuration"
    end

    local model    = gemini_settings.model or "gemini-2.0-flash"
    local base_url = gemini_settings.base_url
                  or "https://generativelanguage.googleapis.com/v1beta/models/"

    local url_sync   = string.format("%s%s:generateContent",            base_url, model)
    local url_stream = string.format("%s%s:streamGenerateContent?alt=sse", base_url, model)

    local headers = {
        ["Content-Type"]   = "application/json",
        ["x-goog-api-key"] = gemini_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"
    local tool_called = false

    -- -----------------------------------------------------------------------
    -- STREAM path: return background function immediately.
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        -- Apply built-in Google Search grounding if requested
        local tools = nil
        if ws_mode == "builtin" then
            tools = { google_search = {} }
        elseif ws_mode == "serpapi" or ws_mode == "tavilyapi" then
            tools = self:buildExternalSearchToolDef("gemini")
        end
        local requestBody = buildRequestBody(message_history, gemini_settings, tools, true)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(url_stream, headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path
    -- -----------------------------------------------------------------------
    -- External search: always non-streaming stage-1.
    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        local augmented, err = self:resolveExternalSearch(
            message_history, gemini_settings, query_option,
            function(msgs, tools)
                -- tools here is { tool_def } from resolveExternalSearch
                local td = (tools and tools[1]) or nil
                return buildRequestBody(msgs, gemini_settings, td, false)
            end,
            headers, url_sync, "gemini")
        if not augmented then return nil, err end
        if augmented.__direct_content then return augmented.__direct_content end
        message_history = augmented
        tool_called = true
    end

    -- Built-in Google Search grounding for non-stream
    local final_tools = nil
    if ws_mode == "builtin" then
        final_tools = { { google_search = {} } }
    end

    local requestBodyTable = buildRequestBody(message_history, gemini_settings, final_tools, false)
    local requestBody = json.encode(requestBodyTable)

    logger.dbg("Gemini API request to model:", model)
    local success, code, response = self:makeRequest(url_sync, headers, requestBody)
    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        logger.warn("Gemini API request failed:", {
            error         = response,
            model         = model,
            request_size  = #requestBody,
            message_count = #message_history,
        })
        return nil, "Error: Failed to connect to Gemini API - " .. tostring(response)
    end

    local ok, parsed = pcall(json.decode, response)
    if not ok or not parsed then
        logger.warn("Gemini: JSON decode error:", response)
        return nil, "Error: Failed to parse Gemini API response"
    end

    -- Fast-path: plain text answer
    local content = koutil.tableGetValue(parsed, "candidates", 1, "content", "parts", 1, "text")
    if content then return content end

    -- Delegate tool-call / error detection to the unified base method
    return self:parseToolCalls(parsed, "gemini")
end

return GeminiHandler
