-- test_prompt_registry.lua
-- Tests for core/prompt_registry.lua: load/save, validation, add/update/
-- delete of UI prompts, merge with file prompts and the Config mutators.
local helper = require("test.helper")
local assert = helper.assert
local PromptRegistry = require("core/prompt_registry")
local Config = require("core/config")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function mockSettings(initial)
    local store = initial or {}
    return {
        readSetting = function(_, key) return store[key] end,
        saveSetting = function(_, key, val) store[key] = val end,
        _store = store,
    }
end

local function mockAssistant(file_prompts)
    local settings = mockSettings()
    local assistant = { settings = settings }
    assistant.config = Config:new{
        assistant = assistant,
        data = { features = { prompts = file_prompts or {} } },
    }
    assistant.config:buildEffectiveConfig()
    return assistant
end

local tests = {
    test("load: missing and corrupt entries give an empty structure", function()
        local data = PromptRegistry.load(mockSettings())
        assert.equal(next(data.prompts), nil)
        assert.equal(data._next_id, 1)
        data = PromptRegistry.load(mockSettings({ ui_prompts = "{not json" }))
        assert.equal(next(data.prompts), nil)
    end),

    test("add + save + load: round trip keeps the record", function()
        local settings = mockSettings()
        local data = PromptRegistry.load(settings)
        local id = PromptRegistry.add(data, { text = "  Mine  ", user_prompt = "Explain {highlight}" })
        assert.equal(id, "custom_1")
        assert.isTrue(PromptRegistry.save(settings, data))
        local again = PromptRegistry.load(settings)
        assert.equal(again.prompts[id].text, "Mine")
        assert.equal(again.prompts[id].use_book_context, true)
        assert.equal(again.prompts[id].show_on_main_popup, true)
        assert.equal(again._next_id, 2)
    end),

    test("validate: name and text are required", function()
        local ok, err = PromptRegistry.validate({ text = " ", user_prompt = "x" })
        assert.isFalse(ok)
        assert.notNil(err)
        ok, err = PromptRegistry.validate({ text = "A", user_prompt = "" })
        assert.isFalse(ok)
        assert.notNil(err)
    end),

    test("validate: appends {highlight} when the prompt lacks it", function()
        local record = { text = "A", user_prompt = "Translate to Bengali" }
        assert.isTrue(PromptRegistry.validate(record))
        assert.matches(record.user_prompt, "{highlight}", "selection placeholder appended")
        local kept = { text = "A", user_prompt = "Only {highlight} please" }
        PromptRegistry.validate(kept)
        assert.equal(kept.user_prompt, "Only {highlight} please")
    end),

    test("update: a rejected edit leaves the stored record untouched", function()
        local data = PromptRegistry.load(mockSettings())
        local id = PromptRegistry.add(data, { text = "A", user_prompt = "p {highlight}" })
        local ok = PromptRegistry.update(data, id, { text = "", user_prompt = "q" })
        assert.isFalse(ok)
        assert.equal(data.prompts[id].text, "A")
        assert.isTrue(PromptRegistry.update(data, id, { text = "B", user_prompt = "q {highlight}", use_book_context = false }))
        assert.equal(data.prompts[id].text, "B")
        assert.equal(data.prompts[id].use_book_context, false)
    end),

    test("delete: unknown id is rejected", function()
        local data = PromptRegistry.load(mockSettings())
        assert.isFalse(PromptRegistry.delete(data, "custom_9"))
    end),

    test("merge: file prompt wins on an id collision, UI prompts get source=ui", function()
        local data = PromptRegistry.load(mockSettings())
        local id = PromptRegistry.add(data, { text = "UI", user_prompt = "a {highlight}" })
        local merged = PromptRegistry.merge({ [id] = { text = "File" }, other = { text = "O" } }, data)
        assert.equal(merged[id].text, "File")
        data.prompts.custom_7 = { text = "Seven", user_prompt = "s {highlight}", order = 207 }
        merged = PromptRegistry.merge({}, data)
        assert.equal(merged.custom_7.source, "ui")
        assert.isTrue(PromptRegistry.is_editable(merged.custom_7))
        assert.isFalse(PromptRegistry.is_editable({ text = "File" }))
    end),

    test("sortedIds: numeric order, not lexical", function()
        local data = PromptRegistry.load(mockSettings())
        data.prompts.custom_10 = { text = "ten" }
        data.prompts.custom_2 = { text = "two" }
        local ids = PromptRegistry.sortedIds(data)
        assert.equal(ids[1], "custom_2")
        assert.equal(ids[2], "custom_10")
    end),

    test("install/update/delete: effective getFeature('prompts') follows", function()
        local assistant = mockAssistant({ mine = { text = "From File" } })
        local id = PromptRegistry.installPrompt(assistant, "Bengali", "Explain in Bengali")
        local prompts = assistant.config:getFeature("prompts")
        assert.equal(prompts.mine.text, "From File")
        assert.equal(prompts[id].text, "Bengali")
        assert.equal(prompts[id].source, "ui")
        assert.matches(prompts[id].user_prompt, "{highlight}")

        assert.isTrue(PromptRegistry.updatePrompt(assistant, id, { text = "Bangla", user_prompt = "Explain {highlight}" }))
        assert.equal(assistant.config:getFeature("prompts")[id].text, "Bangla")

        assert.isTrue(PromptRegistry.deletePrompt(assistant, id))
        assert.equal(assistant.config:getFeature("prompts")[id], nil)
        assert.equal(assistant.config:getFeature("prompts").mine.text, "From File")
    end),

    test("persistence: a new Config restores installed prompts", function()
        local assistant = mockAssistant()
        local id = PromptRegistry.installPrompt(assistant, "Keep", "Keep {highlight}")
        local second = { settings = assistant.settings }
        second.config = Config:new{ assistant = second, data = {} }
        second.config:buildEffectiveConfig()
        assert.equal(second.config:getFeature("prompts")[id].text, "Keep")
    end),
}

return helper.runTests("prompt_registry", tests)
