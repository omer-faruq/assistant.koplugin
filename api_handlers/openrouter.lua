local BaseHandler = require("api_handlers.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local Device = require("device")

local OpenRouterProvider = BaseHandler:new()

function OpenRouterProvider:makeRequest(url, headers, body)
    logger.dbg("Attempting OpenRouter API request:", {
        url = url,
        headers = headers and "present" or "missing",
        body_length = #body
    })
    
    -- Try using curl first (more reliable on Kindle)
    if Device:isKindle() then
        local tmp_request = "/tmp/openrouter_request.json"
        local tmp_response = "/tmp/openrouter_response.json"
        
        -- Write request body
        local f = io.open(tmp_request, "w")
        if f then
            f:write(body)
            f:close()
        end
        
        -- Construct curl command with proper headers
        local header_args = ""
        for k, v in pairs(headers) do
            header_args = header_args .. string.format(' -H "%s: %s"', k, v)
        end
        
        local curl_cmd = string.format(
            'curl -k -s -X POST%s --connect-timeout 30 --retry 2 --retry-delay 3 '..
            '--data-binary @%s "%s" -o %s',
            header_args, tmp_request, url, tmp_response
        )
        
        logger.dbg("Executing curl command:", curl_cmd:gsub(headers["Authorization"], "Bearer ***")) -- Hide API key in logs
        local curl_result = os.execute(curl_cmd)
        logger.dbg("Curl execution result:", curl_result)
        
        -- Read response
        local response = nil
        f = io.open(tmp_response, "r")
        if f then
            response = f:read("*all")
            f:close()
            logger.dbg("Curl response length:", #response)
        else
            logger.warn("Failed to read curl response file")
        end
        
        -- Cleanup
        os.remove(tmp_request)
        os.remove(tmp_response)
        
        if response then
            return true, 200, response
        end
    end
    
    -- Fallback to standard HTTPS if curl fails or not on Kindle
    logger.dbg("Attempting HTTPS fallback request")
    local response = {}
    local status, code, responseHeaders = https.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
        protocol = "tlsv1_2",
        verify = "none", -- Disable SSL verification for Kindle
        timeout = 30
    }
    
    return status, code, table.concat(response)
end

function OpenRouterProvider:query(message_history, config)
    local openrouter_settings = config.provider_settings and config.provider_settings.openrouter
    
    local requestBodyTable = {
        model = openrouter_settings.model,
        messages = message_history,
        max_tokens = openrouter_settings.max_tokens,
        temperature = openrouter_settings.temperature
    }
    
    -- Handle reasoning tokens configuration
    if openrouter_settings.additional_parameters and openrouter_settings.additional_parameters.reasoning ~= nil then
        -- Create a copy of the reasoning configuration
        requestBodyTable.reasoning = {}
        for k, v in pairs(openrouter_settings.additional_parameters.reasoning) do
            requestBodyTable.reasoning[k] = v
        end
        
        -- Set exclude to true by default if not explicitly set
        if requestBodyTable.reasoning.exclude == nil then
            requestBodyTable.reasoning.exclude = true
        end
    end

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (openrouter_settings.api_key or config.api_key),
        ["HTTP-Referer"] = "https://github.com/omer-faruq/assistant.koplugin",
        ["X-Title"] = "assistant.koplugin"
    }

    local status, code, response = self:makeRequest(openrouter_settings.base_url, headers, requestBody)

    if status and code == 200 then
        local success, responseData = pcall(json.decode, response)
        if success and responseData and responseData.choices and responseData.choices[1] then
            return responseData.choices[1].message.content
        end
    end
    
    return nil, "Error: " .. (code or "unknown") .. " - " .. response
end

return OpenRouterProvider
