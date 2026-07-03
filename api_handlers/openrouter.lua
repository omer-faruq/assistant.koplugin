local OpenAIHandler = require("api_handlers/openai")
local o = OpenAIHandler:new({ name = "OpenRouterHandler", })
o.SupportedOptions["reasoning"] = true
return o
