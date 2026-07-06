local OpenAIHandler = require("api_handlers.openai")
local OpenRouterHandler = OpenAIHandler:new({ name = "OpenRouterHandler", })
OpenRouterHandler.SupportedOptions["reasoning"] = true

function OpenRouterHandler:SetHandlerOption(querier)
    OpenAIHandler.SetHandlerOption(self, querier)

    -- Apply saved OpenRouter model override
    local saved_model = querier.settings:readSetting("openrouter_model_" .. self.provider_name)
    if saved_model and saved_model ~= self.model then
        self.model = saved_model
    end
end

return OpenRouterHandler
