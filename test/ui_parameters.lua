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
local Registry = require("core/provider_registry")

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

-- Exercise the Test (probe) callback: it must run against the checked
-- selection without persisting anything. The probe itself is stubbed (no
-- network in a widget test); the wiring and the "no save" contract are not.
UIManager:scheduleIn(1, function()
    local vgroup = dialog[1][1][1][1] -- CenterContainer > Movable > Frame > VerticalGroup
    local button_table = vgroup[#vgroup][1]
    -- Flip the first catalog checkbox so the probe carries real content.
    vgroup[3][1]:toggleCheck()

    local probed
    local real_probe = Registry.testReasoningOptions
    Registry.testReasoningOptions = function(assistant, provider_id, overlay)
        probed = { provider_id = provider_id, overlay = overlay }
    end
    local saved = false
    local real_save = mock_assistant.settings.saveSetting
    local real_del = mock_assistant.settings.delSetting
    mock_assistant.settings.saveSetting = function() saved = true end
    mock_assistant.settings.delSetting = function() saved = true end

    button_table:getButtonById("test").callback()

    Registry.testReasoningOptions = real_probe
    mock_assistant.settings.saveSetting = real_save
    mock_assistant.settings.delSetting = real_del

    assert(probed, "Test must run the probe")
    assert(probed.provider_id == "custom:1", "Test must probe the dialog's provider")
    assert(probed.overlay and probed.overlay.reasoning_effort == "none",
        "Test must probe the checked selection")
    assert(not saved, "Test must not persist the overlay")
    print("ui_parameters: Test callback probed the checked selection without saving")
end)

-- Exercise the OK (apply) callback programmatically (regression: it once
-- indexed a nil global after a refactor). The first catalog entry was checked
-- by the probe above, so applying must persist exactly that one option.
UIManager:scheduleIn(1.5, function()
    local vgroup = dialog[1][1][1][1]
    local button_table = vgroup[#vgroup][1]
    button_table:getButtonById("ok").callback()
    local store = mock_assistant.settings:readSetting("reasoning_option_custom:1")
    assert(type(store) == "table", "OK must persist the overlay")
    assert(store.reasoning_effort == "none", "OK must persist the checked option")
    print("ui_parameters: OK callback ran, overlay persisted")
end)

-- Auto-quit: first paint reproduces any layout crash; 2s gives time to eyeball it.
UIManager:scheduleIn(2, function()
    UIManager:forceRePaint()
    UIManager:quit()
end)
UIManager:run()
