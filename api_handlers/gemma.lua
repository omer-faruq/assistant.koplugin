local OpenAIHandler = require("api_handlers.openai")
local GeminiHandler = require("api_handlers.gemini")

local GemmaHandler = {}

function GemmaHandler:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    return o
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

function GemmaHandler:query(message_history, gemma_settings)
    local content, err
    
    -- Detect API type based on base_url
    local base_url = gemma_settings.base_url or ""
    
    -- Check if using Google's OpenAI-compatible endpoint or native Gemini API
    if base_url:match("generativelanguage%.googleapis%.com") and 
       not (base_url:match("/openai/") or base_url:match("/chat/completions")) then
        -- Use Gemini handler for native Gemini API format
        -- (e.g., https://generativelanguage.googleapis.com/v1beta/models/)
        content, err = GeminiHandler:query(message_history, gemma_settings)
    else
        -- Use OpenAI handler for OpenAI-compatible APIs:
        -- - Google's OpenAI-compatible endpoint (v1beta/openai/ or v1beta/chat/completions)
        -- - Ollama, LM Studio, etc.
        content, err = OpenAIHandler.query(self, message_history, gemma_settings)
    end
    
    -- Filter thought tags from response
    content = filterThoughtTags(content)
    
    return content, err
end

return GemmaHandler:new()
