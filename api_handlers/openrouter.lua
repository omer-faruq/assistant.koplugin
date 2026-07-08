local OpenAIHandler = require("api_handlers.openai")
local OpenRouterHandler = OpenAIHandler:new({ name = "OpenRouterHandler", })
return OpenRouterHandler
