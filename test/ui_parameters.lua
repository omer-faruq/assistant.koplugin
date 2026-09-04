-- Reasoning options (hand-built) dialog widget test
-- Usage: ./test/runui.sh ui_parameters

-- Add project root to path before requiring wbuilder
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test/wbuilder")
local UIManager = wb.UIManager
local LuaSettings = require("luasettings")
local Registry = require("assistant_provider_registry")

-- ── Mock assistant object ──

local mock_record = {
    display_name = "Test Provider",
    handler = "openai",
    model = "test-model",
    base_url = "https://api.example.com/v1",
    api_key = "sk-test",
    additional_parameters = {},
    source = "ui",
}

local mock_assistant = {
    settings = LuaSettings:open("/tmp/assistant_ut.lua"),
    _ui_provider_data = {
        providers = { ["custom:1"] = mock_record },
    },
    config = {
        getProvider = function(self, id) return mock_record end,
        setProvider = function(self, id, record)
            for k, v in pairs(record) do mock_record[k] = v end
        end,
    },
    querier = { provider_name = "custom:1" },
}

local dialog = Registry.showParametersDialog(mock_assistant, "custom:1")

-- Exercise the Save callback programmatically (regression: it once indexed
-- a nil global after a refactor). Nothing is checked, so the record's
-- additional_parameters must stay an empty table after saving.
UIManager:scheduleIn(1, function()
    local vgroup = dialog[1][1][1][1] -- CenterContainer > Movable > Frame > VerticalGroup
    local button_table = vgroup[#vgroup][1]
    button_table:getButtonById("save").callback()
    local params = mock_record.additional_parameters or {}
    assert(type(params) == "table", "additional_parameters should stay a table")
    for k in pairs(params) do
        error("unexpected param saved without checkboxes: " .. k)
    end
    print("ui_parameters: Save callback OK, record unchanged")
end)

-- Auto-quit: first paint reproduces any layout crash; 2s gives time to eyeball it.
UIManager:scheduleIn(2, function()
    UIManager:forceRePaint()
    UIManager:quit()
end)
UIManager:run()
