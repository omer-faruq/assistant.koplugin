local koutil = require("util")
local _ = require("core/gettext")
local T = require("ffi/util").template
local strbuf = require("string.buffer")
local json = require("rapidjson")
local ASUtils = require("utils/base")
local NetUtils = require("utils/net")
local json_default = ASUtils.json_default

-- ---------------------------------------------------------------------------
-- Search API helpers
-- ---------------------------------------------------------------------------

local MAX_SERPAPI_REFS    = 5
local MAX_SEARXNG_RESULTS = 5

local function extract_domain(url)
    url = json_default(url)
    if type(url) ~= "string" then
        return nil
    end
    local host = url:match("^https?://([^/:?#]+)")
    if host then
        host = host:gsub("^www%.", "")
    end
    return (host and host ~= "") and host or nil
end

local function trim_date(date_str)
    date_str = json_default(date_str)
    if type(date_str) ~= "string" or date_str == "" then
        return nil
    end
    return date_str:match("^(%d%d%d%d%-%d%d%-%d%d)") or date_str
end

local function put_source_header(segments, idx, title, source, date)
    title = json_default(title, "Untitled")
    source = json_default(source)
    date = trim_date(date)
    segments:put("---\n")
    if source and source ~= "" and date then
        segments:putf("### Source %d: %s (%s, %s)\n", idx, title, source, date)
    elseif source and source ~= "" then
        segments:putf("### Source %d: %s (%s)\n", idx, title, source)
    elseif date then
        segments:putf("### Source %d: %s (%s)\n", idx, title, date)
    else
        segments:putf("### Source %d: %s\n", idx, title)
    end
end

local function extract_text_blocks(blocks)
    if type(blocks) ~= "table" then
        return nil
    end
    local buf = strbuf.new()
    for idx, block in ipairs(blocks) do
        if type(block) == "table" then
            local snippet = json_default(block.snippet)
            if type(snippet) == "string" and snippet ~= "" then
                buf:put(snippet)
                buf:put("\n")
            end
            if type(block.list) == "table" then
                for ldx, item in ipairs(block.list) do
                    if type(item) == "table" then
                        local item_snippet = json_default(item.snippet)
                        if type(item_snippet) == "string" and item_snippet ~= "" then
                            buf:putf("- %s\n", item_snippet)
                        end
                    end
                end
            end
        end
    end
    local out = buf:get()
    return out ~= "" and out or nil
end

local SearchToolBase = {
    name = "",
    is_external = false,
}
function SearchToolBase:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function SearchToolBase:SearchKeywords(keywords, trap_widget, config)
    return true, ""
end
function SearchToolBase:AccoutInfo()
    return true, T("%1", self.name)
end


local serpapi = SearchToolBase:new({
    name = "SerpAPI",
    is_external = true,
})
function serpapi:SearchKeywords(keywords, trap_widget, config)
    config = config or {}
    local search_url = (config.base_url or "https://serpapi.com") .. "/search"
    local key        = config.api_key
    local q          = koutil.urlEncode(keywords)
    local restrictor = "reconstructed_markdown,text_blocks,references,error"
    local url        = T("%1?engine=google_ai_mode&json_restrictor=%2&api_key=%3&q=%4",
        search_url, restrictor, key, q)

    local parsed, err = NetUtils.fetchJSON(url, nil, trap_widget, 45, 120)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end

    local summary = json_default(parsed.reconstructed_markdown)
    if type(summary) ~= "string" or summary == "" then
        summary = extract_text_blocks(parsed.text_blocks)
    end
    local refs = type(parsed.references) == "table" and parsed.references or nil

    if not summary and not refs then
        return false, "No relevant search or AI summary results found."
    end

    local segments = strbuf.new()
    if summary then
        segments:put("## Google AI Summary:\n")
        segments:put(summary)
        segments:put("\n")
    end
    if refs and #refs > 0 then
        segments:put("## Verified Sources (References):\n")
        for i = 1, math.min(#refs, MAX_SERPAPI_REFS) do
            local ref = refs[i]
            if type(ref) == "table" then
                local idx         = json_default(ref.index, i)
                local title       = json_default(ref.title, "Untitled Source")
                local source_name = json_default(ref.source) or extract_domain(ref.link) or "Web"
                local snippet     = not summary and json_default(ref.snippet) or nil
                if type(snippet) == "string" and snippet ~= "" then
                    segments:putf("[%d] %s (%s): %s\n", idx, title, source_name, snippet)
                else
                    segments:putf("[%d] %s (%s)\n", idx, title, source_name)
                end
            end
        end
    end
    segments:put("\n")
    return true, segments:get()
end
function serpapi:AccoutInfo(config)
    config = config or {}
    local acc_url  = (config.base_url or "https://serpapi.com") .. "/account"
    local key      = config.api_key
    local url      = T("%1?api_key=%2", acc_url, key)
    local parsed, err = NetUtils.fetchJSON(url, nil, "loading...", 30, 60)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end
    local ret = T("SerpAPI\n\n%1/%2\nUsed: %3\nLeft: %4",
        json_default(parsed.plan_name, ""),
        json_default(parsed.account_email, ""),
        json_default(parsed.this_month_usage, ""),
        json_default(parsed.plan_searches_left), "")
    return true, ret
end

local tavily = SearchToolBase:new({
    name = "Tavily",
    is_external = true,
})
function tavily:SearchKeywords(keywords, trap_widget, config)
    config = config or {}
    local search_url = (config.base_url or "https://api.tavily.com") .. "/search"
    local requestBodyTable = {
        api_key              = config.api_key,
        max_results          = 3,
        chunks_per_source    = 2,
        search_depth         = "basic",
        include_answer       = true,
        include_raw_content  = false,
        query                = keywords,
    }
    local requestBody = json.encode(requestBodyTable)

    local parsed, err = NetUtils.fetchJSON(search_url, nil, trap_widget, 45, 120, requestBody)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end
    if type(parsed.results) ~= "table" then
        return false, "fail to parse tavily return"
    end

    local segments = strbuf.new()
    local answer = json_default(parsed.answer)
    if type(answer) == "string" and answer ~= "" then
        segments:put("## Summary\n")
        segments:put(answer)
        segments:put("\n")
    end
    segments:put("Here are the verified search results:\n")
    for i, item in ipairs(parsed.results) do
        if type(item) == "table" then
            put_source_header(segments, i, item.title, extract_domain(item.url), item.published_date)
            local content = json_default(item.content, "")
            if content ~= "" then
                segments:put("* Summary: ")
                segments:put(content)
                segments:put("\n")
            end
        end
    end
    segments:put("\n")
    return true, segments:get()
end

function tavily:AccoutInfo(config)
    config = config or {}
    local acc_url  = (config.base_url or "https://api.tavily.com") .. "/usage"
    local reqHeaders = { ["Authorization"]="Bearer " .. config.api_key }
    local parsed, err = NetUtils.fetchJSON(acc_url, reqHeaders, "loading...", 30, 60)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end
    local ret = T("Tavily API\n\nPlan: %1\nUsed: %2\nLimits: %3",
        json_default(parsed.account.current_plan, ""),
        json_default(parsed.account.plan_usage, ""),
        json_default(parsed.account.plan_limit), "")
    return true, ret
end

local searxng = SearchToolBase:new({
    name = "SearXNG",
    is_external = true,
})
function searxng:SearchKeywords(keywords, trap_widget, config)
    config = config or {}
    local search_url = (config.base_url or "http://localhost") .. "/search"
    local q        = koutil.urlEncode(keywords)
    local url      = T("%1?q=%2&format=json", search_url, q)

    local parsed, err = NetUtils.fetchJSON(url, nil, trap_widget, 45, 120)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end
    if type(parsed.results) ~= "table" then
        return false, "fail to parse searxng return"
    end

    local segments = strbuf.new()
    if type(parsed.answers) == "table" and #parsed.answers > 0 then
        segments:put("## Direct Answers:\n")
        for idx, ans in ipairs(parsed.answers) do
            local text = type(ans) == "table" and json_default(ans.answer) or json_default(ans)
            if type(text) == "string" and text ~= "" then
                segments:putf("- %s\n", text)
            end
        end
    end
    local infobox = koutil.tableGetValue(parsed, "infoboxes", 1)
    if type(infobox) == "table" then
        local ib_title   = json_default(infobox.infobox)
        local ib_content = json_default(infobox.content)
        if type(ib_content) == "string" and ib_content ~= "" then
            if type(ib_title) == "string" and ib_title ~= "" then
                segments:putf("## Infobox: %s\n%s\n", ib_title, ib_content)
            else
                segments:putf("## Infobox:\n%s\n", ib_content)
            end
        end
    end

    segments:put("## Web Search Results:\n")
    local count = 0
    for i, item in ipairs(parsed.results) do
        if type(item) == "table" then
            local content = json_default(item.content, "")
            local title = json_default(item.title)
            if content ~= "" or title then
                count = count + 1
                local host = json_default(koutil.tableGetValue(item, "parsed_url", 2))
                if type(host) == "string" then
                    host = host:gsub("^www%.", "")
                else
                    host = extract_domain(item.url)
                end
                local pub_date = json_default(item.publishedDate) or json_default(item.pubdate)
                put_source_header(segments, count, title, host, pub_date)
                if content ~= "" then
                    segments:put("* Summary: ")
                    segments:put(content)
                    segments:put("\n")
                end
                if count >= MAX_SEARXNG_RESULTS then
                    break
                end
            end
        end
    end
    segments:put("\n")
    return true, segments:get()
end


local exaai = SearchToolBase:new({
    name = "Exa.ai",
    is_external = true,
})
function exaai:SearchKeywords(keywords, trap_widget, config)
    config = config or {}
    local search_url = (config.base_url or "https://api.exa.ai") .. "/search"
    local requestBodyTable = {
        query      = keywords,
        type       = "auto",
        numResults = 5,
        contents   = {
            highlights = {
                maxCharacters = 800,
            },
        },
    }
    local requestBody = json.encode(requestBodyTable)
    local reqHeaders = { ["x-api-key"] = config.api_key }

    local parsed, err = NetUtils.fetchJSON(search_url, reqHeaders, trap_widget, 45, 120, requestBody)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end
    if type(parsed.results) ~= "table" then
        return false, "fail to parse exa.ai return"
    end

    local segments = strbuf.new()
    segments:put("## Exa.ai Search Results:\n\n")
    for i, item in ipairs(parsed.results) do
        if type(item) == "table" then
            put_source_header(segments, i, item.title, extract_domain(item.url), item.publishedDate)
            local summary = json_default(item.summary)
            if type(summary) == "string" and summary ~= "" then
                segments:put("* Summary: ")
                segments:put(summary)
                segments:put("\n")
            end
            if type(item.highlights) == "table" and #item.highlights > 0 then
                segments:put("* Key Excerpts:\n")
                for hdx, hl in ipairs(item.highlights) do
                    local excerpt = json_default(hl)
                    if type(excerpt) == "string" and excerpt ~= "" then
                        segments:putf("  - %s\n", excerpt)
                    end
                end
            end
            segments:put("\n")
        end
    end
    segments:put("\n")
    return true, segments:get()
end

return {
    none = SearchToolBase:new{name = _("None")},
    builtin = SearchToolBase:new{name = _("Model Built-In")},
    serpapi   = serpapi,
    tavilyapi = tavily,
    searxngapi = searxng,
    exaapi    = exaai,
}