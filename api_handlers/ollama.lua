local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OllamaHandler = BaseHandler:new()

function OllamaHandler:query(message_history, ollama_settings, query_option)

    local required_settings = {"base_url", "model", "api_key"}
    for _, setting in ipairs(required_settings) do
        if not ollama_settings[setting] then
            return "Error: Missing " .. setting .. " in configuration"
        end
    end

    local function buildRequestBody(messages, tools)
        local body = {
            model    = ollama_settings.model,
            messages = messages,
        }
        if tools then
            body.tools = tools
        end
        return json.encode(body)
    end

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. ollama_settings.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"


    -- -----------------------------------------------------------------------
    -- STREAM path
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        -- Inject tool definition so the LLM can issue a tool_call in the stream.
        -- The Querier's stream tool-call loop will detect it and execute the search.
        -- Note: tool-call support depends on the specific Ollama model in use.
        local stream_tools = nil
        if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
            stream_tools = { self:buildExternalSearchToolDef("openai") }
        end
        local requestBodyTable = json.decode(buildRequestBody(message_history, stream_tools))
        requestBodyTable.stream = true
        local requestBody = json.encode(requestBodyTable)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(ollama_settings.base_url, headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path
    -- -----------------------------------------------------------------------
    -- External search two-stage flow: only in non-stream mode.
    -- In stream mode the Querier's tool-call loop handles search execution.
    if not query_option.use_stream_mode
       and (ws_mode == "serpapi" or ws_mode == "tavilyapi") then
        local augmented, err = self:resolveExternalSearch(
            message_history, ollama_settings, query_option, buildRequestBody, headers,
            ollama_settings.base_url, "openai")
        if not augmented then return nil, err end
        if augmented.__direct_content then return augmented.__direct_content end
        message_history = augmented
    end
    local requestBodyTable = json.decode(buildRequestBody(message_history, nil))
    requestBodyTable.stream = false
    local requestBody = json.encode(requestBodyTable)

    local success, code, response = self:makeRequest(ollama_settings.base_url, headers, requestBody)
    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: Failed to connect to Ollama API - " .. tostring(response)
    end

    local success_parse, parsed = pcall(json.decode, response)
    if not success_parse then
        logger.warn("JSON Decode Error:", parsed)
        return nil, "Error: Failed to parse Ollama API response"
    end

    -- Ollama uses message.content (not choices[].message.content)
    -- Fast-path: plain text answer (no tool calls)
    local content = koutil.tableGetValue(parsed, "message", "content")
    if content then return content end

    -- Delegate tool-call / error detection to the unified base method.
    -- Ollama follows the OpenAI wire format for tool calls.
    return self:parseToolCalls(parsed, "openai")
end

return OllamaHandler
