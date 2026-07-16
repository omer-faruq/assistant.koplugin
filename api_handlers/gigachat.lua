local BaseHandler = require("api_handlers.base")
local OpenAIHandler = require("api_handlers.openai")
local json = require("json")
local koutil = require("util")

local DEFAULT_UPDATE_INTERVAL = 3
local DEFAULT_TOKEN_EXPIRY = 1800 -- 30 minutes
-- GigaChat API requires UUID in RqUID header, but accepts an empty UUID
local UUID_EMPTY = "00000000-0000-0000-0000-000000000000"

local GigaChatHandler = OpenAIHandler:new({
    name = "GigaChatHandler",
    can_fetch_models = false,
})

function GigaChatHandler:SyncOptions(querier)
    OpenAIHandler.SyncOptions(self, querier)
    self.auth_url = querier.provider_setting.auth_url
end

function GigaChatHandler:query(message_history, query_option)
    -- Pre-fetch the token so that authorization failures are surfaced cleanly
    -- before entering the OpenAI request flow.
    local token, err = self:getAccessToken()
    if not token then
        return nil, "Error obtaining access token: " .. tostring(err)
    end

    return OpenAIHandler.query(self, message_history, query_option)
end

function GigaChatHandler:buildRequestBody(messages, query_option, tools)
    local body = OpenAIHandler.buildRequestBody(self, messages, query_option, tools)
    if body.update_interval == nil then
        body.update_interval = koutil.tableGetValue(self.additional_parameters, "update_interval") or
                                DEFAULT_UPDATE_INTERVAL
    end
    return body
end

function GigaChatHandler:makeRequest(url, headers, body, timeout, maxtime)
    -- Preserve GigaChat-specific timeout defaults when the caller does not pass them.
    if not timeout then
        if body and #body > 10000 then
            timeout = 500
            maxtime = 500
        else
            timeout = 45
            maxtime = 90
        end
    end

    local token, err = self:getAccessToken()
    if not token then
        return false, nil, "Error obtaining access token: " .. tostring(err)
    end

    local giga_headers = {}
    if headers then
        for k, v in pairs(headers) do
            giga_headers[k] = v
        end
    end
    giga_headers["Authorization"] = "Bearer " .. token
    giga_headers["RqUID"] = UUID_EMPTY

    return BaseHandler.makeRequest(self, url, giga_headers, body, timeout, maxtime)
end

function GigaChatHandler:backgroundRequest(url, headers, body)
    local token, err = self:getAccessToken()
    if not token then
        return nil, "Error obtaining access token: " .. tostring(err)
    end

    local giga_headers = {}
    if headers then
        for k, v in pairs(headers) do
            giga_headers[k] = v
        end
    end
    giga_headers["Authorization"] = "Bearer " .. token
    giga_headers["RqUID"] = UUID_EMPTY

    return BaseHandler.backgroundRequest(self, url, giga_headers, body)
end

--- Get access token for GigaChat API
--- @return string? accessToken, string? error
function GigaChatHandler:getAccessToken()
    -- Return cached token if valid
    if self.tokenInfo and self.tokenInfo.accessToken and self.tokenInfo.expiresAt and self.tokenInfo.expiresAt > os.time() then
        return self.tokenInfo.accessToken
    end

    -- Obtain a new token via authorize
    local newToken, err = self:authorize()
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
--- @return table? response, string? error
function GigaChatHandler:authorize()
    if not self.api_key then
        return nil, "Missing authorizationKey (or api_key) in gigachat settings"
    end

    local headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["Authorization"] = "Basic " .. self.api_key,
        ["RqUID"] = UUID_EMPTY,
    }

    local body = "scope=GIGACHAT_API_PERS"

    -- Use BaseHandler.makeRequest directly to avoid recursive token injection
    -- (the overridden makeRequest adds Bearer Authorization/RqUID headers).
    local success, code, response = BaseHandler.makeRequest(self, self.auth_url, headers, body, 20, 45)
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
