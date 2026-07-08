local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")
local ToolExecutor = require("assistant_tool_executor")
local ASUtils = require("assistant_utils")
local UIManager = require("ui/uimanager")
local _ = require("assistant_gettext")
local InfoMessage = require("ui/widget/infomessage")

local GeminiHandler = BaseHandler:new({
    name = "Gemini",
    can_fetch_models = true,
})
GeminiHandler.SupportedOptions = {
    ["maxOutputTokens"] = true,
    ["temperature"] = true,
    ["topP"] = true,
    ["topK"] =true,
    ["thinking_config"]=true,
}

function GeminiHandler:FetchModels()
    local model_url = self.base_url:gsub("v1beta/models/", "v1beta/models")

    logger.info("fetch", model_url)
    local infomsg = InfoMessage:new{
        text = _("Fetching models..."),
    }
    UIManager:show(infomsg)
    local models, err = ASUtils.fetchJSON(model_url, {
        ["Content-Type"]  = "application/json",
        ["x-goog-api-key"] = self.api_key,
    }, infomsg)

    -- logger.info("ret", models, err)

    if err then return nil, err end
    if not models or not models.models or #models.models == 0 then
        return nil, _("Failed to fetch models")
    end

    local model_list = {}
    for _, m in ipairs(models.models) do
        if koutil.arrayContains(m.supportedGenerationMethods, "generateContent") then
            table.insert(model_list, { id = m.name:gsub("^models/", "") })
        end
    end

    if #model_list == 0 then return nil, _("Failed to fetch models") end
    table.sort(model_list, function(a, b)
        return a.id < b.id -- sort by id's alphabeta
    end)
    return model_list, nil
end

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
local function buildGenerationConfig(additional_parameters)
    local gc = nil
    if additional_parameters then
        if type(additional_parameters) == "table" and next(additional_parameters) then
            gc = gc or {}
            for o, v in pairs(additional_parameters) do
                if GeminiHandler.SupportedOptions[o] then gc[o] = v end
            end
        end
        
        if additional_parameters.thinking_budget then
            gc = gc or {}
            gc.thinking_config = { thinking_budget = additional_parameters.thinking_budget }
        end
    end
    return gc
end

--- Build a JSON request body for the Gemini API.
--- @param messages  table       message history
--- @param tool_def  table|nil   Gemini-format tool object (or nil)
--- @return table    body
function GeminiHandler:buildRequestBody(messages, tool_def)
    local contents, system_content = toGeminiContents(messages)

    local system_instruction = { parts = {}}
    if system_content ~= "" then
        table.insert(system_instruction.parts, { text = system_content:gsub("\n$", "") })
    end

    local tools = tool_def and { tool_def } or nil
    local gc = buildGenerationConfig(self.additional_parameters)
    if self.model:find("gemma-4", 1, true) then
        if gc and gc.thinking_config and gc.thinking_config.thinking_budget then
            -- gemma-4 does not support thinking_budget config
            gc.thinking_config.thinking_budget = nil
            gc.thinking_config.include_thoughts = false
            table.insert(system_instruction.parts, { text = "**DIRECT RESPONSE**: Respond directly to the user without generating any internal thinking, chain of thought, or reasoning channels." })
        end
    end

    local body = {
        contents           = contents,
        system_instruction = system_instruction,
        safetySettings     = {
            { category = "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HATE_SPEECH",       threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HARASSMENT",        threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_DANGEROUS_CONTENT", threshold = "BLOCK_NONE" },
        },
        generationConfig   = gc,
        tools              = tools,
    }
    return body
end

function GeminiHandler:query(message_history, query_option)

    local model    = self.model
    local base_url = self.base_url
                  or "https://generativelanguage.googleapis.com/v1beta/models/"

    local url_sync   = string.format("%s%s:generateContent",            base_url, model)
    local url_stream = string.format("%s%s:streamGenerateContent?alt=sse", base_url, model)

    local headers = {
        ["Content-Type"]   = "application/json",
        ["x-goog-api-key"] = self.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"

    -- Apply built-in Google Search grounding if requested
    local tools = nil
    if ws_mode == "builtin" then
        tools = { google_search = {} }
    elseif ToolExecutor.IsExtSearch(ws_mode) then
        tools = self:buildExternalSearchToolDef("gemini")
    end
    local requestBody = self:buildRequestBody(message_history, tools)

    -- -----------------------------------------------------------------------
    -- STREAM path: return background function immediately.
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(url_stream, headers, json.encode(requestBody))
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path
    -- -----------------------------------------------------------------------
    -- In non-stream mode, inject tool definitions if web_search is enabled.
    -- Let the Querier handle the tool-call loop and search execution.
    logger.dbg("Gemini API request to model:", model)
    local success, code, response = self:makeRequest(url_sync, headers, json.encode(requestBody))
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
    if not ok or not parsed or not parsed.candidates then
        local err = koutil.tableGetValue(parsed, "error", "message")
        if err then
            return nil, err
        end
        logger.warn("Gemini: JSON decode error:", response)
        return nil, "Error: Failed to parse Gemini API response"
    end

    -- Delegate tool-call / error detection to the unified base method
    return self:parseToolCalls(parsed, "gemini")
end

return GeminiHandler
