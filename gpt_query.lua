local plugin_config = nil
-- Try loading configuration using require, fallback to nil
local config_ok_gpt, config_result_gpt = pcall(require, "configuration")
if config_ok_gpt then
    plugin_config = config_result_gpt
else
    if logger then
        local log_msg = config_result_gpt
        if type(log_msg) == "table" then log_msg = "(table data omitted for security)" end
        logger.info("GPTQuery: configuration.lua not found or error loading via require:", log_msg)
    end
    plugin_config = nil -- Ensure it's nil if loading failed
end
local DataStorage = require("datastorage") -- Added DataStorage
local logger = require("logger") -- Added logger

-- Define handlers table with proper error handling
local handlers = {}
local function loadHandler(name)
    local success, handler = pcall(function()
        return require("api_handlers." .. name)
    end)
    if success then
        handlers[name] = handler
    else
        print("Failed to load " .. name .. " handler: " .. tostring(handler))
    end
end

local provider_handlers = {
    anthropic = function() loadHandler("anthropic") end,
    openai = function() loadHandler("openai") end,
    deepseek = function() loadHandler("deepseek") end,
    gemini = function() loadHandler("gemini") end,
    openrouter = function() loadHandler("openrouter") end,
    ollama = function() loadHandler("ollama") end,
    mistral = function() loadHandler("mistral") end
}

-- Load the required handler based on the locally loaded config

-- API key is accessed directly from config within the handler

local function queryChatGPT(message_history, provider) -- Expect provider as parameter
    -- Provider is now passed as an argument

    if logger then logger.info("Querying using provider:", provider) end
    if not plugin_config then
        return "Error: No configuration found. Please set up configuration.lua"
    end

    -- The 'provider' variable is already set based on assistant_settings.lua (lines 47-50)
    -- Remove the old logic trying to read from G_reader_settings
    
    if not provider then
        return "Error: No provider specified in configuration"
    end

    -- Load the required handler on demand
    if provider and provider_handlers[provider] then
        provider_handlers[provider]() -- This loads the handler into the 'handlers' table
    end
    local handler = handlers[provider]

    if not handler then
        return "Error: Unsupported provider " .. provider .. ". Please check configuration.lua"
    end

    -- Extract the correct API key and add it directly to the config table for the handler
    if plugin_config.provider_settings and plugin_config.provider_settings[provider] then
        plugin_config.api_key = plugin_config.provider_settings[provider].api_key
    else
         plugin_config.api_key = nil -- Ensure it's nil if settings are missing
    end

    if not plugin_config.api_key then
        return "Error: No API key found for provider " .. provider .. ". Please check configuration.lua"
    end

    local success, result = pcall(function()
        return handler:query(message_history, plugin_config)
    end)

    if not success then
        return "Error: " .. tostring(result)
    end

    return result
end

return queryChatGPT
