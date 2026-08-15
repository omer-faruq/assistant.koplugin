local OpenAIHandler = require("api_handlers.openai")
local OpenRouterHandler = OpenAIHandler:new({ name = "OpenRouterHandler", })

-- OpenRouter: list only models the key is allowed to use (guardrails/model
-- allowlist). Fall back to the full catalog if the filtered endpoint 404s.
function OpenRouterHandler:getModelsUrl()
    return self.base_url .. "/models/user"
end

return OpenRouterHandler
