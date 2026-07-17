local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")
local ToolExecutor = require("assistant_tool_executor")
local ASUtils = require("assistant_utils")
local UIManager = require("ui/uimanager")
local _ = require("assistant_gettext")
local InfoMessage = require("ui/widget/infomessage")

local AnthropicHandler = BaseHandler:new({
    name = "Anthropic",
    can_fetch_models = true,
    has_builtin_websearch = false,
})
AnthropicHandler.SupportedOptions = {
    ["max_tokens"]= true,
}

--- Return the full API endpoint URL by appending the messages path.
function AnthropicHandler:getApiUrl()
    return self.base_url .. "/messages"
end

function AnthropicHandler:FetchModels()

    local model_url = self.base_url .. "/models"
    local infomsg = InfoMessage:new{
        text = _("Fetching models..."),
    }
    UIManager:show(infomsg)
    local models, err = ASUtils.fetchJSON(model_url, {
        ["Content-Type"]  = "application/json",
        ["anthropic-version"] = "2023-06-01",
        ["x-api-key"]         = self.api_key,
    }, infomsg)

    if err then return nil, err end
    if models and models.data then
        local model_list = models.data
        table.sort(model_list, function(a, b)
            return a.id < b.id -- sort by id's alphabeta
        end)
        return model_list, nil
    end
    return nil, _("Failed to fetch models")
    
end

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
--- @param tools     table|nil   tool definitions to inject (nil → use settings.tools or none)
--- @param stream    boolean|nil
--- @return table    body
function AnthropicHandler:buildRequestBody(messages, tools, stream)
    local prepared = prepareAnthropicMessages(messages)
    local body = {
        model      = self.model,
        system     = prepared.system,
        messages   = prepared.messages,
        stream     = stream or false,
    }
    if type(self.additional_parameters) == "table" and next(self.additional_parameters) then
        for o, v in pairs(self.additional_parameters) do
            if self.SupportedOptions[o] then body[o] = v end
        end
    end

    if tools then
        -- Injected tools (e.g. from Querier's web_search support)
        body.tools       = tools
        body.tool_choice = { type = "auto" }
    else
        -- Carry over any user-configured tools (e.g. native web_search_20250305)
        if self.additional_parameters.tools and type(self.additional_parameters.tools) == "table" and next(self.additional_parameters.tools) ~= nil then
            body.tools = self.additional_parameters.tools 
        end
    end

    return body
end

function AnthropicHandler:query(message_history, query_option)

    local headers = {
        ["Content-Type"]      = "application/json",
        ["x-api-key"]         = self.api_key,
    }

    if self.additional_parameters.anthropic_version then
        headers["anthropic-version"] = self.additional_parameters.anthropic_version
    end

    local ws_mode = query_option.use_websearch or "none"

    -- -----------------------------------------------------------------------
    -- STREAM path
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        local stream_tools = nil
        if ToolExecutor.IsExtSearch(ws_mode) then
            stream_tools = { self:buildExternalSearchToolDef("anthropic") }
        end
        local body = self:buildRequestBody(message_history, stream_tools, true)
        local requestBody = json.encode(body)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(self:getApiUrl(), headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path
    -- -----------------------------------------------------------------------
    -- In non-stream mode, inject tool definitions if web_search is enabled.
    -- Let the Querier handle the tool-call loop and search execution.
    local requestBody
    if ToolExecutor.IsExtSearch(ws_mode) then
        local search_tool = { self:buildExternalSearchToolDef("anthropic") }
        requestBody = self:buildRequestBody(message_history, search_tool, false)
    else
        requestBody = self:buildRequestBody(message_history, nil, false)
    end

    local success, code, response = self:makeRequest(
        self:getApiUrl(), headers, json.encode(requestBody))

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
