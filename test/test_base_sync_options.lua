-- test_base_sync_options.lua
-- Tests for BaseHandler:SyncOptions per-model parameter presets
-- (model_parameters full-replace semantics).
local helper = require("test.test_helper")
local assert = helper.assert
local BaseHandler = require("api_handlers.base")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Mirror the production contract: SyncOptions reads
-- querier.settings:readSetting("selected_model_" .. querier.provider_name)
local function makeQuerier(provider_name, provider_setting, selected_model)
    return {
        provider_name = provider_name,
        handler_name = "openai",
        provider_setting = provider_setting,
        settings = {
            readSetting = function(_, key)
                if key == "selected_model_" .. provider_name then
                    return selected_model
                end
                return nil
            end,
        },
    }
end

local tests = {

    test("SyncOptions: no model_parameters keeps shared additional_parameters", function()
        local setting = {
            model = "model-a",
            base_url = "https://example.com/v1",
            additional_parameters = { temperature = 0.7, max_tokens = 4096 },
        }
        local handler = BaseHandler:new{}
        handler:SyncOptions(makeQuerier("p1", setting))
        assert.equal("model-a", handler.model)
        assert.equal(0.7, handler.additional_parameters.temperature)
        assert.equal(4096, handler.additional_parameters.max_tokens)
    end),

    test("SyncOptions: keyed model fully replaces additional_parameters", function()
        local setting = {
            model = "model-a",
            base_url = "https://example.com/v1",
            additional_parameters = {
                temperature = 0.7,
                max_tokens = 4096,
                reasoning = { enabled = false },
            },
            model_parameters = {
                ["model-b"] = {
                    temperature = 0.5,
                    max_tokens = 6000,
                    reasoning = { max_tokens = 3000 },
                },
            },
        }
        local handler = BaseHandler:new{}
        handler:SyncOptions(makeQuerier("p2", setting, "model-b"))
        assert.equal("model-b", handler.model)
        -- full replacement: shared keys must not bleed through
        assert.equal(0.5, handler.additional_parameters.temperature)
        assert.equal(6000, handler.additional_parameters.max_tokens)
        assert.equal(nil, handler.additional_parameters.reasoning.enabled)
        assert.equal(3000, handler.additional_parameters.reasoning.max_tokens)
    end),

    test("SyncOptions: preset is deep-copied (no aliasing into config)", function()
        local preset = { reasoning = { max_tokens = 3000 } }
        local setting = {
            model = "model-x",
            base_url = "https://example.com/v1",
            additional_parameters = {},
            model_parameters = { ["model-x"] = preset },
        }
        local handler = BaseHandler:new{}
        handler:SyncOptions(makeQuerier("p3", setting))
        handler.additional_parameters.reasoning.max_tokens = 9999
        assert.equal(3000, preset.reasoning.max_tokens,
            "handler mutation must not leak back into the provider setting")
    end),

    test("SyncOptions: shared parameters are deep-copied too (no preset branch)", function()
        local setting = {
            model = "model-a",
            base_url = "https://example.com/v1",
            additional_parameters = { temperature = 0.7 },
        }
        local handler = BaseHandler:new{}
        handler:SyncOptions(makeQuerier("p3b", setting))
        handler.additional_parameters.temperature = 42
        assert.equal(0.7, setting.additional_parameters.temperature,
            "handler mutation must not leak into shared additional_parameters")
    end),

    test("SyncOptions: switching back to a non-keyed model restores defaults", function()
        local setting = {
            model = "model-default",
            base_url = "https://example.com/v1",
            additional_parameters = { temperature = 0.7, max_tokens = 4096 },
            model_parameters = {
                ["model-big"] = { temperature = 0.5, max_tokens = 9000 },
            },
        }
        local querier = makeQuerier("p4", setting)
        local handler = BaseHandler:new{}

        querier.settings.readSetting = function() return "model-big" end
        handler:SyncOptions(querier)
        assert.equal(9000, handler.additional_parameters.max_tokens)

        querier.settings.readSetting = function() return nil end
        handler:SyncOptions(querier)
        assert.equal("model-default", handler.model)
        assert.equal(4096, handler.additional_parameters.max_tokens,
            "stale preset must be reset to shared defaults")
    end),

    test("SyncOptions: no shared additional_parameters — switch-back resets to empty", function()
        -- Regression: a provider with model_parameters but no top-level
        -- additional_parameters must not keep the last applied preset.
        local setting = {
            model = "m-default",
            base_url = "https://example.com/v1",
            model_parameters = {
                ["m-big"] = { temperature = 0.5, max_tokens = 9000 },
            },
        }
        local querier = makeQuerier("p5", setting)
        local handler = BaseHandler:new{}

        handler:SyncOptions(querier)
        assert.equal(nil, handler.additional_parameters.temperature)

        querier.settings.readSetting = function() return "m-big" end
        handler:SyncOptions(querier)
        assert.equal(0.5, handler.additional_parameters.temperature)

        querier.settings.readSetting = function() return nil end
        handler:SyncOptions(querier)
        assert.equal(nil, handler.additional_parameters.temperature,
            "stale preset must not survive when there are no shared defaults")
        assert.equal(nil, handler.additional_parameters.max_tokens)
    end),

    test("SyncOptions: non-table preset entries are skipped", function()
        local setting = {
            model = "m-garbage",
            base_url = "https://example.com/v1",
            additional_parameters = { temperature = 0.7 },
            model_parameters = {
                ["m-garbage"] = "oops",
            },
        }
        local handler = BaseHandler:new{}
        handler:SyncOptions(makeQuerier("p6", setting))
        assert.equal(0.7, handler.additional_parameters.temperature,
            "garbage preset entry must fall back to shared defaults")
    end),

    test("SyncOptions: stale model_parameters must not leak across providers sharing a handler", function()
        -- Production hands the same module-level handler singleton to every
        -- provider using that handler; provider B has no model_parameters and
        -- must not inherit provider A's presets.
        local setting_a = {
            model = "shared-model",
            base_url = "https://example.com/v1",
            additional_parameters = { temperature = 0.1 },
            model_parameters = {
                ["shared-model"] = { temperature = 0.1, max_tokens = 12345 },
            },
        }
        local setting_b = {
            model = "shared-model",
            base_url = "https://other.example.com/v1",
            additional_parameters = { temperature = 0.9 },
        }
        local handler = BaseHandler:new{} -- one instance, reused like in production

        handler:SyncOptions(makeQuerier("pa", setting_a))
        assert.equal(12345, handler.additional_parameters.max_tokens)

        handler:SyncOptions(makeQuerier("pb", setting_b))
        assert.equal(0.9, handler.additional_parameters.temperature,
            "provider B must not inherit provider A's preset")
        assert.equal(nil, handler.additional_parameters.max_tokens)
        assert.equal(nil, handler.model_parameters,
            "preset map must be cleared from the handler after each sync")
    end),

    test("SyncOptions: empty-table preset discards all shared parameters", function()
        local setting = {
            model = "m-bare",
            base_url = "https://example.com/v1",
            additional_parameters = { temperature = 0.7, max_tokens = 4096 },
            model_parameters = {
                ["m-bare"] = {},
            },
        }
        local handler = BaseHandler:new{}
        handler:SyncOptions(makeQuerier("p10", setting))
        assert.equal(nil, handler.additional_parameters.temperature,
            "empty preset must fully replace shared parameters")
        assert.equal(nil, handler.additional_parameters.max_tokens)
    end),

    test("SyncOptions: rapidjson.null config values fall back to defaults", function()
        local rapidjson = require("rapidjson")
        local setting = {
            model = "model-a",
            base_url = "https://example.com/v1",
            additional_parameters = rapidjson.null,
            model_parameters = rapidjson.null,
        }
        local handler = BaseHandler:new{}
        handler:SyncOptions(makeQuerier("p7", setting))
        assert.equal(nil, handler.additional_parameters.temperature,
            "null additional_parameters must degrade to an empty table")
    end),

    test("SyncOptions: non-table additional_parameters falls back to empty", function()
        local setting = {
            model = "model-a",
            base_url = "https://example.com/v1",
            additional_parameters = "oops",
        }
        local handler = BaseHandler:new{}
        handler:SyncOptions(makeQuerier("p8", setting))
        assert.equal(nil, handler.additional_parameters.temperature,
            "garbage additional_parameters must degrade to an empty table")
    end),

    test("SyncOptions: false-valued preset entry falls back to shared", function()
        local setting = {
            model = "m-false",
            base_url = "https://example.com/v1",
            additional_parameters = { temperature = 0.9 },
            model_parameters = {
                ["m-false"] = false,
            },
        }
        local handler = BaseHandler:new{}
        handler:SyncOptions(makeQuerier("p9", setting))
        assert.equal(0.9, handler.additional_parameters.temperature,
            "false preset must fall back to shared defaults")
    end),
}

-- Inlined snippet of groq.lua's debounce-selection branch (module-level
-- closure state, not exported — AGENTS.md testing policy allows snippet
-- testing for pure logic). NOTE: returns plain seconds; production converts
-- through time.s() — a future unit/clamping change in groq.lua will not be
-- caught here.
local GROQ_DEFAULT_DEBOUNCE = 15
local function groqDebounceSeconds(additional_parameters)
    local wait_seconds = tonumber(additional_parameters.groq_wait_seconds)
    if wait_seconds and wait_seconds >= 0 then
        return wait_seconds
    end
    return GROQ_DEFAULT_DEBOUNCE
end

table.insert(tests, test("groq debounce: absent resets to default, explicit values respected", function()
    assert.equal(60, groqDebounceSeconds({ groq_wait_seconds = 60 }))
    assert.equal(15, groqDebounceSeconds({}), "missing key must reset to default")
    assert.equal(0, groqDebounceSeconds({ groq_wait_seconds = 0 }),
        "explicit 0 must disable the debounce (paid-tier opt-out)")
    assert.equal(15, groqDebounceSeconds({ groq_wait_seconds = -5 }),
        "negative is invalid and resets to default")
    assert.equal(15, groqDebounceSeconds({ groq_wait_seconds = "abc" }))
    assert.equal(30, groqDebounceSeconds({ groq_wait_seconds = "30" }),
        "numeric strings are accepted")
end))

return helper.runTests("test_base_sync_options", tests)
