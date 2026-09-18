local BaseHandler = require("api_handlers.base")
local json = require("rapidjson")
local koutil = require("util")
local logger = require("logger")
local ToolExecutor = require("assistant_tool_executor")
local ASUtils = require("assistant_utils")
local UIManager = require("ui/uimanager")
local _ = require("assistant_gettext")
local InfoMessage = require("ui/widget/infomessage")

local OpenAIHandler = BaseHandler:new({
    name = "openai",
    can_fetch_models = true,
})

-- Parameters whitelisted for pass-through into /chat/completions request body.
-- Each entry denotes the handler will forward it from additional_parameters without
-- transformation (see buildRequestBody).  All values are injected as-is.
--
-- Source annotations below help identify platform/model-specific options so
-- future maintainers don't accidentally remove or blindly duplicate them.
OpenAIHandler.SupportedOptions = {
    -- ---- common OpenAI-compatible sampling ----
    -- These are widely implemented, but individual providers/models may impose
    -- different ranges or reject them for reasoning models.
    ["temperature"]             = true,   -- common sampling parameter
    ["top_p"]                   = true,   -- common nucleus-sampling parameter
    ["max_completion_tokens"]   = true,   -- newer OpenAI/Groq-style completion limit
    ["max_tokens"]              = true,   -- legacy completion limit; still widely supported

    -- ---- provider-specific extensions ----
    ["search_settings"]         = true,   -- Groq web-search settings; not an OpenAI standard field
    ["reasoning_format"]        = true,   -- Groq: raw/parsed/hidden reasoning output format
    ["reasoning_effort"]        = true,   -- OpenAI, OpenRouter, Groq, DeepSeek; supported values are model-specific
    ["reasoning"]               = true,   -- OpenAI/OpenRouter-style reasoning object, e.g. { effort = "..." }

    -- ---- reasoning/thinking controls (non-standard, model-dependent) ----
    ["thinking"]                = true,   -- DeepSeek: { type = "disabled" } or { type = "enabled" }
    ["thinking_budget"]         = true,   -- SiliconFlow, Alibaba/Qwen, and other reasoning-model APIs; max CoT tokens
    ["enable_thinking"]         = true,   -- SiliconFlow, Alibaba/Qwen, and other APIs; toggles thinking mode
    ["think"]                   = true,   -- Ollama: boolean or "low"/"medium"/"high"/"max" thinking toggle

    -- References:
    -- OpenRouter: https://openrouter.ai/docs/api/api-reference/chat/create-a-chat-completion
    -- Groq:       https://console.groq.com/docs/reasoning
    -- SiliconFlow: https://docs.siliconflow.com/en/api-reference/chat-completions/chat-completions
    -- Alibaba:    https://help.aliyun.com/zh/model-studio/deep-thinking
    -- DeepSeek:   https://api-docs.deepseek.com/guides/thinking_mode
}

function OpenAIHandler:SyncOptions(querier)
    BaseHandler.SyncOptions(self, querier)
    self.reasoning_key = nil
end

--- Return the full API endpoint URL by appending the chat completions path.
function OpenAIHandler:getApiUrl()
    return self.base_url .. "/chat/completions"
end

--- Return the full models-list endpoint URL.
--- Overridable per-handler (e.g. OpenRouter's guardrail-filtered /models/user).
function OpenAIHandler:getModelsUrl()
    return self.models_url or (self.base_url .. "/models")
end

function OpenAIHandler:FetchModels()
    local model_url = self:getModelsUrl()
    local infomsg = InfoMessage:new{
        text = ASUtils.bold_format(_("<b>Fetching models...</b>")),
    }
    UIManager:show(infomsg)
    local models, err = ASUtils.fetchJSON(model_url, {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. self.api_key,
    }, infomsg, function(body) return self:extractErrorMessage(body) end)

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

--- Extract a human-readable error message from an API response body.
--- Native error.message > flat error, then FastAPI-style proxied
--- detail.error.message > detail.error > detail.message > detail string,
--- then bare message. This is the ONLY place detail.* proxy fallback lives
--- (proxies e.g. DeepSeek wrap upstream errors under detail).
--- @param body string|table|nil raw body or already-decoded JSON
--- @return string|nil error message, or nil if none found
function OpenAIHandler:extractErrorMessage(body)
    local decoded = body
    if type(body) == "string" then
        if #body == 0 then return nil end
        local ok, j = pcall(json.decode, body)
        if not ok or type(j) ~= "table" then return nil end
        decoded = j
    end
    if type(decoded) ~= "table" then return nil end
    local pick = BaseHandler.pickErrorValue
    return pick(koutil.tableGetValue(decoded, "error", "message"))
        or pick(decoded.error)
        or pick(koutil.tableGetValue(decoded, "detail", "error", "message"))
        or pick(koutil.tableGetValue(decoded, "detail", "error"))
        or pick(koutil.tableGetValue(decoded, "detail", "message"))
        or pick(decoded.detail)
        or pick(decoded.message)
end

--- Connection test: minimal non-stream chat request with the static echo
--- instruction. Inherited by the OpenAI-compatible aliases (deepseek,
--- ollama, openrouter, mistral, groq, gigachat).
function OpenAIHandler:Test()
    local body = {
        model    = self.model,
        messages = { { role = "user", content = self.TEST_PROMPT } },
    }
    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. self.api_key,
    }
    return self:testRequest(self:getApiUrl(), headers, body, function(data)
        return koutil.tableGetValue(data, "choices", 1, "message", "content")
    end)
end

--- Build a JSON request body for the OpenAI-compatible API.
--- @param messages  table   message history
--- @param tools     table|nil  tool definitions (nil → no tool_calls)
--- @return table    requestBody 
function OpenAIHandler:buildRequestBody(messages, query_option, tools)
    local body = {
        model      = self.model,
        messages   = messages,
    }
    if type(self.additional_parameters) == "table" and next(self.additional_parameters) then
        for o, v in pairs(self.additional_parameters) do
            if self.SupportedOptions[o] then body[o] = v end
        end
    end
    if tools then
        body.tools       = tools
        body.tool_choice = "auto"
    end
    if query_option.use_stream_mode then
        body.stream = true
    end
    return body
end

function OpenAIHandler:query(message_history, query_option)

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. self.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"
    local tools
    if ToolExecutor.IsExtSearch(ws_mode) then
        tools = { self:buildExternalSearchToolDef("openai") }
    end
    local body = self:buildRequestBody(message_history, query_option, tools)

    -- -----------------------------------------------------------------------
    -- STREAM path: build body and return a background function immediately.
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        local requestBody = json.encode(body)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(self:getApiUrl(), headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path: synchronous makeRequest, may return tool_call table.
    -- -----------------------------------------------------------------------
    local requestBody = json.encode(body)
    local status, code, response = self:makeRequest(self:getApiUrl(), headers, requestBody)

    if not status then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        -- Try to surface a structured error message from the response body
        if response and #response > 0 then
            local ok, rd = pcall(json.decode, response)
            if ok then
                local err_msg = self:extractErrorMessage(rd)
                if err_msg then return nil, BaseHandler.prefixHttpCode(code, err_msg) end
            end
        end
        return nil, BaseHandler.prefixHttpCode(code, "Error: " .. tostring(self.model) .. "\n" .. self:getApiUrl() .. "\n- " .. tostring(code or "unknown") .. " - " .. tostring(response))
    end

    local ok, responseData = pcall(json.decode, response)
    if not ok or not responseData then
        logger.warn(self.name, "failed to parse response:", tostring(response):sub(1, 200))
        return nil, "Error: failed to parse API response"
    end

    -- Delegate content / tool-call extraction to the unified base method
    return self:parseToolCalls(responseData, "openai")
end

return OpenAIHandler
