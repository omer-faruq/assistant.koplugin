local BaseHandler = require("api_handlers.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local Device = require("device")

local OpenAIHandler = BaseHandler:new()

function OpenAIHandler:makeRequest(url, headers, body)
    logger.dbg("Attempting OpenAI API request:", {
        url = url,
        headers = headers and "present" or "missing",
        body_length = #body
    })
    
    -- Try using curl first (more reliable on Kindle)
    if Device:isKindle() then
        local tmp_request = "/tmp/openai_request.json"
        local tmp_response = "/tmp/openai_response.json"
        
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
            -- Assuming curl success implies HTTP 200 for now, might need refinement if curl can return error bodies
            return true, response
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
    
    if status and code < 400 then
        return true, table.concat(response) -- Success
    elseif status and code >= 400 then
        return false, code, table.concat(response) -- HTTP error
    else
        return false, code or "Connection failed" -- Connection error (code might be nil or error string)
    end
end

function OpenAIHandler:query(message_history, config)
    local openai_settings = config.provider_settings and config.provider_settings.openai
    
    local requestBodyTable = {
        model = openai_settings.model,
        messages = message_history,
        max_tokens = openai_settings.max_tokens
    }

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (openai_settings.api_key)
    }

    local ok, data, err_body = self:makeRequest(openai_settings.base_url, headers, requestBody)

    if not ok then
        local error_message = "Error: Unknown error during OpenAI API request."
        if type(data) == "number" and err_body then -- HTTP error code and body
            local decode_ok, parsed_error = pcall(json.decode, err_body)
            if decode_ok and parsed_error and parsed_error.error and parsed_error.error.message then
                error_message = "Error: OpenAI API returned HTTP " .. data .. " - " .. parsed_error.error.message
            else
                error_message = "Error: OpenAI API request failed with HTTP status " .. data
            end
        elseif type(data) == "string" then -- Connection error string
             error_message = "Error: Failed to connect to OpenAI API - " .. data
        end
        logger.warn("OpenAI API request failed:", {
            error = error_message,
            status_code = type(data) == "number" and data or nil,
            response_body = err_body,
            model = openai_settings.model,
            base_url = openai_settings.base_url,
        })
        return error_message -- Return only the error message string
    end

    -- If ok, data contains the successful response body
    local response = data
    local success, responseData = pcall(json.decode, response)
    if success and responseData and responseData.choices and responseData.choices[1] then
        return responseData.choices[1].message.content
    else
        -- Handle cases where JSON decoding failed or response structure is unexpected
        if not success then
            logger.warn("OpenAI JSON Decode Error:", responseData) -- responseData contains the error message on pcall failure
            return "Error: Failed to parse OpenAI API response"
        else
            logger.warn("Unexpected OpenAI API response format:", response)
            return "Error: Unexpected response format from OpenAI API"
        end
    end
end

return OpenAIHandler