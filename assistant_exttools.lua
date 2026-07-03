local logger = require("logger")
local koutil = require("util")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local strbuf = require("string.buffer")
local Trapper = require("ui/trapper")
local json = require("rapidjson")
local ASUtils = require("assistant_utils")
local json_default = ASUtils.json_default

-- ---------------------------------------------------------------------------
-- Search API helpers
-- ---------------------------------------------------------------------------

local SearchToolBase = {
    name = "", base_url = "", api_key = "",
    is_external = false,
}
function SearchToolBase:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function SearchToolBase:SearchKeywords(keywords, trap_widget)
    return true, ""
end
function SearchToolBase:AccoutInfo()
    return true, T("%1:\n%2", self.name, self.base_url)
end


local serpapi = SearchToolBase:new({ 
    name = "SerpAPI", base_url = "https://serpapi.com",
    is_external = true,
})
function serpapi:SearchKeywords(keywords, trap_widget)
    local search_url = self.base_url .. "/search"
    local key      = self.api_key
    local q        = koutil.urlEncode(keywords)
    local url      = T("%1?engine=google_ai_mode&api_key=%2&q=%3", search_url, key, q)

    local timeout = 45
    local maxtime = 120

    local completed, success, code, content =
        Trapper:dismissableRunInSubprocess(function()
            return ASUtils.httpRequest(url, timeout, maxtime, nil, nil, nil)
        end, trap_widget)

    if not completed then return false, ASUtils.HANDLERCODE.CODE_CANCELLED end
    if not success or code ~= 200 then return false, content end

    local ok, parsed = pcall(json.decode, content)
    if not ok or not parsed then
        return false, "fail to parse serpapi return"
    end

    if not parsed.reconstructed_markdown and not parsed.references then
        return false, "No relevant search or AI summary results found."
    end

    local segments = strbuf.new()
    if json_default(parsed.reconstructed_markdown) then
        segments:put("## Google AI Summary:\n")
        segments:put(parsed.reconstructed_markdown)
        segments:put("\n")
    end
    if parsed.references and #parsed.references > 0 then
        segments:put( "## Verified Sources (References):")
        for _, ref in ipairs(parsed.references) do
            local idx         = json_default(ref.index, 0)
            local title       = json_default(ref.title, "Untitled Source")
            local source_name = json_default(ref.source, "Web")
            segments:putf("[%d] %s (%s)", idx, title, source_name)
        end
    end
    segments:put("\n")
    return true, segments:get()
end
function serpapi:AccoutInfo()
    local acc_url  = self.base_url .. "/account"
    local key      = self.api_key
    local url      = T("%1?api_key=%2", acc_url, key)
    local completed, success, code, content =
        Trapper:dismissableRunInSubprocess(function()
            return ASUtils.httpRequest(url, 30, 60, nil, nil, nil)
        end, "loading...")
    if not completed then return false, ASUtils.HANDLERCODE.CODE_CANCELLED end
    if not success or code ~= 200 then return false, content end
    local ok, parsed = pcall(json.decode, content)
    if not ok or not parsed then
        return false, "fail to parse serpapi return"
    end
    local ret = T("SerpAPI\n\n%1/%2\nUsed: %3\nLeft: %4",
        json_default(parsed.plan_name, ""),
        json_default(parsed.account_email, ""),
        json_default(parsed.this_month_usage, ""),
        json_default(parsed.plan_searches_left), "")
    return true, ret
end

local tarvily = SearchToolBase:new({ 
    name = "Tarvily", base_url = "https://api.tavily.com",
    is_external = true,
})
function tarvily:SearchKeywords(keywords, trap_widget)
    local search_url = self.base_url .. "/search"
    local requestBodyTable = {
        api_key              = self.api_key,
        auto_parameters      = true,
        max_results          = 3,
        search_depth         = "basic",
        include_answer       = true,
        include_raw_content  = false,
        query                = keywords,
    }
    local requestBody = json.encode(requestBodyTable)

    local timeout = 45
    local maxtime = 120

    local completed, success, code, content =
        Trapper:dismissableRunInSubprocess(function()
            return ASUtils.httpRequest(search_url, timeout, maxtime, requestBody, "application/json", nil)
        end, trap_widget)

    if not completed then return false, ASUtils.HANDLERCODE.CODE_CANCELLED end
    if not success or code ~= 200 then return false, content end

    local ok, parsed = pcall(json.decode, content)
    if not ok or not parsed or not parsed.results then
        return false, "fail to parse tavily return"
    end

    local segments = strbuf.new()
    if json_default(parsed.answer) then
        segments:put("## Summary\n")
        segments:put(parsed.answer)
        segments:put("\n")
    end
    segments:put("Here are the verified search results:\n")
    for i, item in ipairs(parsed.results) do
        segments:put("---")
        segments:putf("### Source %d: %s", i, json_default(item.title, "Untitled"))
        -- segments:put( string.format("* URL: %s", json_default(item.url, "N/A")))
        segments:put("* Summary: ")
        segments:put(json_default(item.content, ""))
        segments:put("\n")
    end
    segments:put("\n")
    return true, segments:get()
end

function tarvily:AccoutInfo()
    local acc_url  = self.base_url .. "/usage"
    local reqHeaders = { ["Authorization"]="Bearer " .. self.api_key }
    local completed, success, code, content =
        Trapper:dismissableRunInSubprocess(function()
            return ASUtils.httpRequest(acc_url, 30, 60, nil, nil, reqHeaders)
        end, "loading...")
    if not completed then return false, ASUtils.HANDLERCODE.CODE_CANCELLED end
    if not success or code ~= 200 then return false, content end
    local ok, parsed = pcall(json.decode, content)
    if not ok or not parsed then
        return false, "fail to parse serpapi return"
    end
    local ret = T("Tarvily API\n\nPlan: %1\nUsed: %2\nLimits: %3",
        json_default(parsed.account.current_plan, ""),
        json_default(parsed.account.plan_usage, ""),
        json_default(parsed.account.plan_limit), "")
    return true, ret
end

local searxng = SearchToolBase:new({ 
    name = "SearXNG", base_url = "http://localhost",
    is_external = true,
})
function searxng:SearchKeywords(keywords, trap_widget)
    local search_url = self.base_url .. "/search"
    local q        = koutil.urlEncode(keywords)
    local url      = T("%1?q=%2&format=json", search_url, q)

    local timeout = 45
    local maxtime = 120

    local completed, success, code, content =
        Trapper:dismissableRunInSubprocess(function()
            return ASUtils.httpRequest(url, timeout, maxtime, nil, nil, nil)
        end, trap_widget)

    if not completed then return false, ASUtils.HANDLERCODE.CODE_CANCELLED end
    if not success or code ~= 200 then return false, content end

    local ok, parsed = pcall(json.decode, content)
    if not ok or not parsed or not parsed.results then
        return false, "fail to parse searxng return"
    end

    local segments = strbuf.new()
    segments:put("## Web Search Results:\n")
    for i, item in ipairs(parsed.results) do
        segments:put("---")
        segments:putf("### Source %d: %s", i, json_default(item.title, "Untitled"))
        segments:put("* URL: ")
        segments:put(json_default(item.url, "N/A"))
        segments:put("\n")
        segments:put("* Summary: ")
        segments:put(json_default(item.content, ""))
        segments:put("\n")
    end
    segments:put("\n")
    return true, segments:get()
end


return {
    none = SearchToolBase:new{name = _("None")},
    builtin = SearchToolBase:new{name = _("Model Built-In")},
    serpapi   = serpapi,
    tavilyapi = tarvily,
    searxngapi = searxng,
}