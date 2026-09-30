-- test_model_picker_page.lua
-- Guards the picker fresh-open page jump (assistant_model_picker.lua):
-- the dialog must open on the page holding the model in effect, with that
-- row checked -- otherwise it strands on page 1 with no checked row to
-- anchor the model in effect.
-- Headless-safe: the picker module cannot be required here (it pulls the
-- focus manager, which needs a live UI), so the index -> page logic
-- (ModelPicker.initialPage) has no executable path in this suite. What is
-- pinned is the wiring: every entry point that opens the picker for a
-- known model must go through initialPage, so the jump cannot be dropped
-- while the logic stays invisible here.
local helper = require("test.helper")
local assert = helper.assert

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("fresh entries wire initialPage, nav passes explicit pages", function()
        local picker_src = read_source("assistant_model_picker.lua")
        assert.matches(picker_src, "showPickerDialog = function",
            "showPickerDialog stays the single dialog entry")
        local registry_src = read_source("assistant_provider_registry.lua")
        assert.matches(registry_src, "mp%.initialPage%(assistant, model_list%)",
            "Browse Models must jump to the model in effect")
        local provider_src = read_source("assistant_provider_dialog.lua")
        assert.matches(provider_src, "ModelPicker%.initialPage%(self%.assistant, models%)",
            "Provider Settings browse must jump to the model in effect")
    end),
}

return helper.runTests("model_picker_page", tests)
