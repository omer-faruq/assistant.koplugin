local logger = require("logger")
local UIManager = require("ui/uimanager")  
local time = require("ui/time")
local ToolExecutor = require("assistant_tool_executor")
local koutil = require("util")
local ASUtils = require("assistant_utils")
local OpenAIHandler = require("api_handlers.openai")
local groqHandler = OpenAIHandler:new({
    name = "GroqHandler",
})

local LAST_CALLED = 0
local GROQ_DEFAULT_DEBOUNCE = time.s(15)
local API_CALL_DEBOUNCE_DELAY = GROQ_DEFAULT_DEBOUNCE

function groqHandler:SyncOptions(querier)
    OpenAIHandler.SyncOptions(self, querier)
    -- Presence-based semantics: an omitted groq_wait_seconds (e.g. after a
    -- per-model preset replaced additional_parameters) resets to the default;
    -- an explicit value is respected, so groq_wait_seconds = 0 disables the
    -- debounce (e.g. on paid tiers). Invalid values also reset to the default.
    local wait_seconds = tonumber(self.additional_parameters.groq_wait_seconds)
    if wait_seconds and wait_seconds >= 0 then
        API_CALL_DEBOUNCE_DELAY = time.s(wait_seconds)
    else
        API_CALL_DEBOUNCE_DELAY = GROQ_DEFAULT_DEBOUNCE
    end
end

function groqHandler:query(message_history, query_option)
    local ws_mode = query_option.use_websearch or "none"
    if ToolExecutor.IsExtSearch(ws_mode) then
        -- Ext TOOL CALLS are likely triggering groq API Free-tier rate limits (8k tokens/minutes)
        local current_time = UIManager:getElapsedTimeSinceBoot()
        if current_time - LAST_CALLED < API_CALL_DEBOUNCE_DELAY then
            local time_since_last_request = current_time - LAST_CALLED
            local delay_secs = time.to_number(API_CALL_DEBOUNCE_DELAY - time_since_last_request)
            if not ASUtils.sleepWithInfo(delay_secs, "Groq API Wait") then
                return nil, self.CODE_CANCELLED
            end
        end
        LAST_CALLED = UIManager:getElapsedTimeSinceBoot()
    end

    return OpenAIHandler.query(self, message_history, query_option)
end

return groqHandler
