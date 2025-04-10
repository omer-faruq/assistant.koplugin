local BaseHandler = require("api_handlers.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local Device = require("device")

local AnthropicHandler = BaseHandler:new()

function AnthropicHandler:makeRequest(url, headers, body)
    logger.dbg("Attempting Anthropic API request:", {
        url = url,
        headers = headers and "present" or "missing",
        body_length = #body
    })
    
    -- Try using curl first (more reliable on Kindle)
    if Device:isKindle() then
        local tmp_request = "/tmp/anthropic_request.json"
        local tmp_response = "/tmp/anthropic_response.json"
        
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
        
        logger.dbg("Executing curl command:", curl_cmd:gsub(headers["x-api-key"], "***")) -- Hide API key in logs
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
            -- Assuming curl success implies HTTP 200 for now
            return true, response
        end
    end
    
    -- Fallback to standard HTTPS if curl fails or not on Kindle
    logger.dbg("Attempting HTTPS fallback request")
    local responseBody = {}
    local success, code = https.request({
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(responseBody),
        timeout = 30,
        verify = "none", -- Disable SSL verification for Kindle
    })
    
    if success and code < 400 then
        return true, table.concat(responseBody) -- Success
    elseif success and code >= 400 then
        return false, code, table.concat(responseBody) -- HTTP error
    end
    -- If not success (connection error), code already holds the error string
    
    logger.warn("Anthropic API request failed:", {
        error = code,
        error_type = type(code),
        error_message = tostring(code)
    })
    return false, code -- Return connection error string
end

function AnthropicHandler:query(message_history, config)
    local anthropic_settings = config.provider_settings and config.provider_settings.anthropic

    if not anthropic_settings or not anthropic_settings.api_key then
        return "Error: Missing API key in configuration"
    end
    
    local messages = {}
    for _, msg in ipairs(message_history) do
        if msg.role ~= "system" then
            table.insert(messages, {
                role = msg.role == "assistant" and "assistant" or "user",
                content = msg.content
            })
        end
    end

    local requestBodyTable = {
        model = anthropic_settings.model,
        messages = messages,
        max_tokens = (anthropic_settings.additional_parameters and anthropic_settings.additional_parameters.max_tokens)
    }

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = anthropic_settings.api_key,
        ["anthropic-version"] = (anthropic_settings.additional_parameters and anthropic_settings.additional_parameters.anthropic_version)
    }

    local ok, data, err_body = self:makeRequest(anthropic_settings.base_url, headers, requestBody)

    if not ok then
        local error_message = "Error: Unknown error during Anthropic API request."
        if type(data) == "number" and err_body then -- HTTP error code and body
            local decode_ok, parsed_error = pcall(json.decode, err_body)
            if decode_ok and parsed_error and parsed_error.error and parsed_error.error.type and parsed_error.error.message then
                error_message = "Error: Anthropic API returned HTTP " .. data .. " (" .. parsed_error.error.type .. ") - " .. parsed_error.error.message
            elseif decode_ok and parsed_error and parsed_error.type and parsed_error.detail then -- Handle validation errors etc.
                 error_message = "Error: Anthropic API returned HTTP " .. data .. " (" .. parsed_error.type .. ") - " .. parsed_error.detail
            else
                error_message = "Error: Anthropic API request failed with HTTP status " .. data
            end
        elseif type(data) == "string" then -- Connection error string
             error_message = "Error: Failed to connect to Anthropic API - " .. data
        end
        logger.warn("Anthropic API request failed:", {
            error = error_message,
            status_code = type(data) == "number" and data or nil,
            response_body = err_body,
            model = anthropic_settings.model,
            base_url = anthropic_settings.base_url,
        })
        return error_message -- Return only the error message string
    end
    -- If ok, data contains the successful response body
    local response = data

    local success_parse, parsed = pcall(json.decode, response)
    if not success_parse then
        logger.warn("JSON Decode Error:", parsed)
        return "Error: Failed to parse Anthropic API response"
    end
    
    if parsed and parsed.content and parsed.content[1] and parsed.content[1].text then
        return parsed.content[1].text
    else
        -- Try to extract error from successful response if content is missing
        if parsed and parsed.error and parsed.error.type and parsed.error.message then
             logger.warn("Anthropic API Error in successful response:", parsed.error.message)
             return "Error: Anthropic API (" .. parsed.error.type .. ") - " .. parsed.error.message
        end
        logger.warn("Unexpected Anthropic API response format:", response)
        return "Error: Unexpected response format from Anthropic API"
    end
end

return AnthropicHandler