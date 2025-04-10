local BaseHandler = require("api_handlers.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local socket = require("socket")
local logger = require("logger")
local Device = require("device")

local GeminiHandler = BaseHandler:new()

-- Add fallback HTTP request function
function GeminiHandler:makeRequest(url, headers, body)
    logger.dbg("Attempting Gemini API request:", {
        url = url:gsub("key=[^&]+", "key=***"), -- Mask API key in URL log
        headers = headers,
        body_length = #body
    })
    
    -- Try using curl first (more reliable on Kindle)
    if Device:isKindle() then
        local tmp_request = "/tmp/gemini_request.json"
        local tmp_response = "/tmp/gemini_response.json"
        
        -- Write request body
        local f = io.open(tmp_request, "w")
        if f then
            f:write(body)
            f:close()
        end
        
        -- Construct curl command with proper options for Kindle
        local curl_cmd = string.format(
            'curl -k -s -X POST -H "Content-Type: application/json" '..
            '--connect-timeout 30 --retry 2 --retry-delay 3 '..
            '--data-binary @%s "%s" -o %s',
            tmp_request, url, tmp_response
        )
        
        logger.dbg("Executing curl command:", curl_cmd:gsub("key=[^&]+", "key=***")) -- Mask API key in curl command log
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
            return true, response
        end
    end
    
    -- Fallback to standard HTTPS if curl fails
    logger.dbg("Attempting HTTPS fallback request")
    local responseBody = {}
    local success, code, headers_response = https.request({
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(responseBody),
        timeout = 30,
        verify = "none", -- Disable SSL verification for Kindle
    })
    
    logger.warn("HTTPS request details:", {
        success = success,
        code = code,
        response_headers = headers_response,
        response_length = responseBody and #table.concat(responseBody) or 0,
        error_type = type(code),
        error_message = tostring(code)
    })
    
    if success and code < 400 then -- Success only if HTTP status is OK
        return true, table.concat(responseBody)
    elseif success and code >= 400 then -- HTTP error occurred
        return false, code, table.concat(responseBody) -- Return status code and body
    end
    -- If not success (connection error), code already holds the error string
    
    -- Log detailed error information
    local error_info = {
        error_type = type(code),
        error_message = tostring(code),
        ssl_loaded = package.loaded["ssl"] ~= nil,
        https_loaded = package.loaded["ssl.https"] ~= nil,
        socket_loaded = package.loaded["socket"] ~= nil,
        device_info = {
            is_kindle = Device:isKindle(),
            model = Device:getModel(),
            firmware = Device:getFirmware(),
        }
    }
    
    logger.warn("Gemini API request failed with details:", error_info)
    return false, code -- Return connection error string
end

function GeminiHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    -- Gemini API requires messages with explicit roles
    local contents = {}
    local systemMessage = nil

    for i, msg in ipairs(message_history) do
        -- First message is treated as system message
        if i == 1 and msg.role ~= "user" then
            systemMessage = {
                role = "user",
                parts = {{ text = msg.content }}
            }
        else
            table.insert(contents, {
                role = "user",
                parts = {{ text = msg.content }}
            })
        end
    end

    -- If a system message exists, insert it at the beginning
    if systemMessage then
        table.insert(contents, 1, systemMessage)
    end

    local requestBodyTable = {
        contents = contents,
        safety_settings = {
            { category = "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HATE_SPEECH", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HARASSMENT", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_DANGEROUS_CONTENT", threshold = "BLOCK_NONE" }
        }
    }

    local requestBody = json.encode(requestBodyTable)
    
    local headers = {
        ["Content-Type"] = "application/json"
    }

    local gemini_settings = config.provider_settings and config.provider_settings.gemini or {}
    local model = gemini_settings.model or "gemini-2.5-pro-exp-03-25"
    local base_url = gemini_settings.base_url or "https://generativelanguage.googleapis.com/v1beta/models/"
    
    local url = string.format("%s%s:generateContent?key=%s", base_url, model, config.api_key)
    logger.dbg("Making Gemini API request to model:", model)
    
    local ok, data, err_body = self:makeRequest(url, headers, requestBody)

    if not ok then
        local error_message = "Error: Unknown error during Gemini API request."
        if type(data) == "number" and err_body then -- HTTP error code and body
            local decode_ok, parsed_error = pcall(json.decode, err_body)
            if decode_ok and parsed_error and parsed_error.error and parsed_error.error.message then
                error_message = "Error: Gemini API returned HTTP " .. data .. " - " .. parsed_error.error.message
            else
                error_message = "Error: Gemini API request failed with HTTP status " .. data
            end
        elseif type(data) == "string" then -- Connection error string
             error_message = "Error: Failed to connect to Gemini API - " .. data
        end
        logger.warn("Gemini API request failed:", {
            error = error_message,
            status_code = type(data) == "number" and data or nil,
            response_body = err_body,
            model = model,
            base_url = base_url:gsub(config.api_key, "***"),
            request_size = #requestBody,
            message_count = #message_history
        })
        return error_message
    end
    -- If ok, data contains the successful response body
    local response = data

    local success, parsed = pcall(json.decode, response)
    
    if not success then
        logger.warn("JSON Decode Error:", parsed)
        return "Error: Failed to parse Gemini API response"
    end
    
    -- New response handling logic from example
    if parsed then
        -- Check for explicit error field first
        if parsed.error then
            local err_msg = string.format("Gemini API Error [%s]: %s",
                parsed.error.code or "?",
                parsed.error.message or "Unknown error"
            )
            logger.warn(err_msg, parsed.error) -- Log the full error object
            return err_msg
        end

        local response_text = nil

        -- Format 1: candidates -> content -> parts (Standard)
        if parsed.candidates and #parsed.candidates > 0 then
            local first_candidate = parsed.candidates[1]
            if first_candidate.content and first_candidate.content.parts then
                for _, part in ipairs(first_candidate.content.parts) do
                    if part.text then
                        response_text = part.text
                        break
                    end
                end
            end
        end

        -- Format 2: raw output (alternative response type)
        if not response_text and parsed.output and type(parsed.output) == "string" then
            response_text = parsed.output
        end

        -- Format 3: legacy format with 'answers'
        if not response_text and parsed.answers and #parsed.answers > 0 then
            response_text = parsed.answers[1].content
        end

        if response_text then
            return response_text
        end
    end

    -- If no text found and no explicit error, log and return generic error
    logger.warn("Unexpected Gemini API response format or empty content:", parsed)
    return "Error: Unexpected response format or empty content from Gemini API."
end

return GeminiHandler