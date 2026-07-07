local logger = require("logger")
local BaseHandler = require("api_handlers.base")

local GemmaHandler = BaseHandler:new({ name = "GemmaHandler" })

local function HandlerByURL(base_url)
    if base_url:match("generativelanguage%.googleapis%.com") and 
            not (base_url:match("/openai/") or base_url:match("/chat/completions")) then
        return require("api_handlers.gemini"):new{}
    end
    return require("api_handlers.openai"):new{}
end

function GemmaHandler:SetHandlerOption(querier)
    local base_url = querier.provider_setting.base_url
    local handler = HandlerByURL(base_url)
    self.__parent_handler = handler
    setmetatable(self, { __index = handler } )
    handler.SetHandlerOption(self, querier)
end

local function filterThoughtTags(content)
    if not content then return content end
    
    -- Gemma 4 models include <|channel>thought...<channel|> tags for reasoning
    -- Even when thinking is disabled, empty tags are still generated
    -- Filter them out from the response (Gemma 2 models don't have this issue)
    content = content:gsub("<|channel>thought.-<channel|>", "")
    -- Also handle alternative format if present
    content = content:gsub("<thought>.-</thought>", "")
    
    return content
end

function GemmaHandler:query(message_history, query_option)
    local content, err = self.__parent_handler.query(self, message_history, query_option)
    -- Filter thought tags from response
    if type(content) == "string" then
        content = filterThoughtTags(content)
    end
    return content, err
end

return GemmaHandler
