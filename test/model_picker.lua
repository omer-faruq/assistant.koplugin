-- Model picker widget test
-- Usage: ./test/runui.sh model_picker

-- Add project root to path before requiring wbuilder
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test/wbuilder")
local UIManager = wb.UIManager

-- ── Mock assistant object ──

local mock_assistant = {
    querier = {
        provider_name = "test_provider",
        provider_settings = { model = "gpt-4o" },
        provider_setting = { model = "gpt-4o" },
        handler = {
            SyncOptions = function() end,
        },
    },
    CONFIGURATION = {
        provider_settings = {
            test_provider = { model = "gpt-4o" },
        },
    },
    settings = {
        saveSetting = function(_, key, val) end,
        delSetting = function(_, key) end,
        readSetting = function(_, key) return nil end,
    },
    updated = false,
}

-- ── Mock model data (for testing pagination, search, and selection) ──

local test_models = {}
for i = 1, 50 do
    local providers = { "openai", "anthropic", "google", "meta", "mistral" }
    local names = { "GPT", "Claude", "Gemini", "Llama", "Mistral" }
    local p = providers[(i % #providers) + 1]
    local n = names[(i % #names) + 1]
    table.insert(test_models, {
        id = string.format("%s/%s-%d", p, n:lower(), i),
        name = string.format("%s %d", n, i),
    })
end

-- ── Show Model Picker ──

local showModelPicker = require("assistant_model_picker")
mock_assistant.querier.handler.FetchModels = function()
    return test_models
end
showModelPicker(mock_assistant)

UIManager:run()
