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
local API_CALL_DEBOUNCE_DELAY = time.s(15)

function groqHandler:setHandlerOption(groq_settings)
    local groq_wait_seconds = koutil.tableGetValue(groq_settings, "additional_parameters", "groq_wait_seconds")
    if groq_wait_seconds then
        API_CALL_DEBOUNCE_DELAY = time.s(groq_wait_seconds)
    end
end

function groqHandler:query(message_history, groq_settings, query_option)
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

    return OpenAIHandler.query(self, message_history, groq_settings, query_option)
end

return groqHandler
