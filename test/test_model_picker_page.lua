-- test_model_picker_page.lua
-- Guards the picker fresh-open page jump (assistant_model_picker.lua):
-- the dialog must open on the page holding the model in effect, with that
-- row checked -- otherwise it strands on page 1 where RadioButtonTable
-- force-checks the first row though nothing was staged.
-- Headless-safe: the picker module pulls UI widgets, so the pure index ->
-- page snippet is inlined here and the source wiring is pinned by scan.
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

-- Inline copy of initialPage's core: model index -> page, 1 on miss.
local function pageOfModel(all_models, model_id, per_page)
    if model_id and model_id ~= "" and type(all_models) == "table" then
        for idx, m in ipairs(all_models) do
            if type(m) == "table" and m.id == model_id then
                return math.ceil(idx / per_page)
            end
        end
    end
    return 1
end

local function make_models(n)
    local t = {}
    for i = 1, n do
        table.insert(t, { id = "model-" .. i })
    end
    return t
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("first page model opens on page 1", function()
        assert.equal(pageOfModel(make_models(25), "model-1", 10), 1)
        assert.equal(pageOfModel(make_models(25), "model-10", 10), 1)
    end),

    test("later page model opens on its own page", function()
        assert.equal(pageOfModel(make_models(25), "model-11", 10), 2)
        assert.equal(pageOfModel(make_models(25), "model-21", 10), 3)
        assert.equal(pageOfModel(make_models(25), "model-25", 10), 3)
    end),

    test("missing model falls back to page 1", function()
        assert.equal(pageOfModel(make_models(25), "custom-manual-id", 10), 1)
        assert.equal(pageOfModel(make_models(25), "", 10), 1)
        assert.equal(pageOfModel(make_models(25), nil, 10), 1)
        assert.equal(pageOfModel({}, "model-1", 10), 1)
    end),

    test("non-table entries are skipped", function()
        local models = { "stray", { id = "model-2" } }
        assert.equal(pageOfModel(models, "model-2", 10), 1)
        assert.equal(pageOfModel(models, "stray", 10), 1)
    end),

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
