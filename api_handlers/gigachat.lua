local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local DEFAULT_UPDATE_INTERVAL = 3
local DEFAULT_TOKEN_EXPIRY = 1800 -- 30 minutes
-- GigaChat API requires UUID in RqUID header, but accepts an empty UUID
local UUID_EMPTY = "00000000-0000-0000-0000-000000000000"

local GigaChatHandler = BaseHandler:new()

function GigaChatHandler:query(message_history, gigachat_settings, query_option)
    if not gigachat_settings or not gigachat_settings.base_url then
        return "Error: Missing base_url in configuration"
    end

    local token, err = self:getAccessToken(gigachat_settings)
    if not token then
        return nil, "Error obtaining access token: " .. tostring(err)
    end

    local function buildRequestBody(messages, tools)
        local body = {
            model           = gigachat_settings.model,
            messages        = messages,
            update_interval = koutil.tableGetValue(gigachat_settings, "additional_parameters", "update_interval") or
                                DEFAULT_UPDATE_INTERVAL,
            max_tokens      = koutil.tableGetValue(gigachat_settings, "additional_parameters", "max_tokens"),
        }
        if tools then
            body.tools       = tools
            body.tool_choice = "auto"
        end
        return json.encode(body)
    end

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. token,
        ["RqUID"]         = UUID_EMPTY,
    }

    local ws_mode = query_option.use_websearch or "none"

    -- In non-stream mode, inject tool definitions if web_search is enabled.
    -- Let the Querier handle the tool-call loop and search execution.
    local tools
    if ws_mode == "serpapi" or ws_mode == "tavilyapi" then
        tools = { self:buildExternalSearchToolDef("openai") }
    end

    local requestBodyTable = json.decode(buildRequestBody(message_history, tools))
    requestBodyTable.stream = query_option.use_stream_mode
    local requestBody = json.encode(requestBodyTable)

    if requestBodyTable.stream then
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(gigachat_settings.base_url, headers, requestBody)
    end

    local request_timeout, request_maxtime
    if #requestBody > 10000 then
        request_timeout = 500
        request_maxtime = 500
    else
        request_timeout = 45
        request_maxtime = 90
    end

    local success, code, response = self:makeRequest(
        gigachat_settings.base_url, headers, requestBody, request_timeout, request_maxtime)

    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: Failed to connect to GigaChat API - " .. tostring(response)
    end

    local success_parse, parsed = pcall(json.decode, response)
    if not success_parse then
        return nil, "Error: Failed to parse GigaChat API response: " .. response
    end

    local content = koutil.tableGetValue(parsed, "choices", 1, "message", "content")
    if content then return content end

    local apiError = koutil.tableGetValue(parsed, "error")
    if apiError and apiError.message then
        logger.warn("API Error:", code, response)
        return nil, "GigaChat API Error: [" .. (apiError.code or "unknown") .. "]: " .. apiError.message
    else
        logger.warn("API Error:", code, response)
        return nil, "GigaChat API Error: Unexpected response format from API: " .. response
    end
end

--- Get access token for GigaChat API
--- @param gigachat_settings table: GigaChat settings
--- @return string? accessToken, string? error
function GigaChatHandler:getAccessToken(gigachat_settings)
    -- Return cached token if valid
    if self.tokenInfo and self.tokenInfo.accessToken and self.tokenInfo.expiresAt and self.tokenInfo.expiresAt > os.time() then
        return self.tokenInfo.accessToken
    end

    -- Obtain a new token via authorize
    local newToken, err = self:authorize(gigachat_settings)
    if not newToken then
        return nil, err
    end

    self.tokenInfo = {
        accessToken = newToken.accessToken,
        expiresAt = newToken.expiresAt,
    }

    return self.tokenInfo.accessToken
end

--- Authorize with GigaChat to obtain an access token
--- @param gigachat_settings table: GigaChat settings
--- @return table? response, string? error
function GigaChatHandler:authorize(gigachat_settings)
    if not gigachat_settings or not gigachat_settings.auth_url then
        return nil, "Missing auth_url in gigachat settings"
    end

    if not gigachat_settings.api_key then
        return nil, "Missing authorizationKey (or api_key) in gigachat settings"
    end

    local headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["Authorization"] = "Basic " .. gigachat_settings.api_key,
        ["RqUID"] = UUID_EMPTY,
    }

    local body = "scope=GIGACHAT_API_PERS"

    local success, code, response = self:makeRequest(gigachat_settings.auth_url, headers, body, 20, 45)
    if not success then
        return nil, string.format("Auth request failed (%s): %s", tostring(code), tostring(response))
    end

    local ok, parsed = pcall(json.decode, response)
    if not ok or type(parsed) ~= "table" then
        return nil, "Failed to parse auth response: " .. tostring(response)
    end

    if not parsed.access_token or type(parsed.access_token) ~= "string" then
        return nil, "Auth response missing access_token"
    end

    local expiresAt = parsed.expires_at and math.floor(parsed.expires_at / 1000) or os.time() + DEFAULT_TOKEN_EXPIRY

    return {
        accessToken = parsed.access_token,
        expiresAt = expiresAt,
    }
end

return GigaChatHandler