local logger = require("logger")
local BaseHandler = require("api_handlers.base")

local GemmaHandler = BaseHandler:new({ name = "GemmaHandler" })
local openai_hdl = require("api_handlers.openai"):new{}
local gemini_hdl = require("api_handlers.gemini"):new{}

local PARENT_METATABLES = {
    openai = { __index = openai_hdl },
    gemini = { __index = gemini_hdl },
}

local function FormatByURL(base_url)
    if base_url:match("generativelanguage%.googleapis%.com") and not (base_url:match("/openai")) then
        return "gemini"
    end
    return "openai"
end

function GemmaHandler:SyncOptions(querier)
    local base_url = querier.provider_setting.base_url
    local metatab = PARENT_METATABLES[FormatByURL(base_url)]
    setmetatable(self, metatab)
    self.__parent_handler = metatab.__index
    self.__parent_handler.SyncOptions(self, querier)
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
