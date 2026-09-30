-- test_base_sync_options.lua
-- Tests for BaseHandler:SyncOptions per-model parameter presets
-- (model_parameters full-replace semantics) and the runtime reasoning
-- overlay merged on top of the synced parameters.
local helper = require("test.helper")
local assert = helper.assert
local BaseHandler = require("api_handlers.base")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Mirror the production contract: SyncOptions reads
-- querier.settings:readSetting("selected_model_" .. querier.provider_name)
-- and, for the reasoning overlay, "reasoning_option_" .. provider_name.
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

-- Sync once with a reasoning overlay stored under the provider's overlay key.
-- Only catalog-whitelisted keys may reach additional_parameters.
local function syncWithOverlay(provider_name, provider_setting, overlay)
    local querier = makeQuerier(provider_name, provider_setting)
    local overlay_key = "reasoning_option_" .. provider_name
    querier.settings.readSetting = function(_, key)
        if key == overlay_key then
            return overlay
        end
        return nil
    end
    local handler = BaseHandler:new{}
    handler:SyncOptions(querier)
    return handler
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
                -- an empty preset must clear every shared key
                ["model-c"] = {},
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

        handler:SyncOptions(makeQuerier("p2", setting, "model-c"))
        assert.equal(nil, handler.additional_parameters.temperature,
            "empty preset must fully replace shared parameters")
        assert.equal(nil, handler.additional_parameters.max_tokens)
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

    test("SyncOptions: switching back to a non-keyed model resets the applied preset", function()
        -- Regression: a provider with model_parameters must not keep the last
        -- applied preset once the selection returns to the shared default --
        -- neither when shared defaults exist nor when they do not.
        local with_shared = {
            model = "model-default",
            base_url = "https://example.com/v1",
            additional_parameters = { temperature = 0.7, max_tokens = 4096 },
            model_parameters = {
                ["model-big"] = { temperature = 0.5, max_tokens = 9000 },
            },
        }
        local without_shared = {
            model = "m-default",
            base_url = "https://example.com/v1",
            model_parameters = {
                ["m-big"] = { temperature = 0.5, max_tokens = 9000 },
            },
        }

        local querier = makeQuerier("p4", with_shared)
        local handler = BaseHandler:new{}

        querier.settings.readSetting = function() return "model-big" end
        handler:SyncOptions(querier)
        assert.equal(9000, handler.additional_parameters.max_tokens)

        querier.settings.readSetting = function() return nil end
        handler:SyncOptions(querier)
        assert.equal("model-default", handler.model)
        assert.equal(4096, handler.additional_parameters.max_tokens,
            "stale preset must be reset to shared defaults")

        local bare = makeQuerier("p5", without_shared)
        handler:SyncOptions(bare)
        assert.equal(nil, handler.additional_parameters.temperature)

        bare.settings.readSetting = function() return "m-big" end
        handler:SyncOptions(bare)
        assert.equal(0.5, handler.additional_parameters.temperature)

        bare.settings.readSetting = function() return nil end
        handler:SyncOptions(bare)
        assert.equal(nil, handler.additional_parameters.temperature,
            "stale preset must not survive when there are no shared defaults")
        assert.equal(nil, handler.additional_parameters.max_tokens)
    end),

    test("SyncOptions: non-table preset entries are skipped", function()
        -- The guard is on the entry type, not its truthiness: both a string
        -- and a boolean must fall back to the shared defaults.
        local function sync_with_preset(provider_name, garbage)
            local setting = {
                model = "m-garbage",
                base_url = "https://example.com/v1",
                additional_parameters = { temperature = 0.7 },
                model_parameters = {
                    ["m-garbage"] = garbage,
                },
            }
            local handler = BaseHandler:new{}
            handler:SyncOptions(makeQuerier(provider_name, setting))
            return handler.additional_parameters.temperature
        end

        assert.equal(0.7, sync_with_preset("p6", "oops"),
            "garbage preset entry must fall back to shared defaults")
        assert.equal(0.7, sync_with_preset("p6b", false),
            "false preset entry must fall back to shared defaults")
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

    test("SyncOptions: reasoning overlay merges only whitelisted keys", function()
        local setting = {
            model = "model-a",
            base_url = "https://example.com/v1",
            handler = "openai",
            additional_parameters = { temperature = 0.7, max_tokens = 4096 },
        }
        local overlay = {
            reasoning = { effort = "low" },
            reasoning_effort = "high",
            not_in_catalog = { sneaky = true },
        }
        local handler = syncWithOverlay("openai", setting, overlay)

        -- openai's catalog allows reasoning and reasoning_effort...
        assert.equal("low", handler.additional_parameters.reasoning.effort)
        assert.equal("high", handler.additional_parameters.reasoning_effort)
        -- ...and rejects everything else.
        assert.equal(nil, handler.additional_parameters.not_in_catalog,
            "non-whitelisted overlay keys must be dropped")
        -- The overlay is layered over the synced parameters, not a replacement.
        assert.equal(0.7, handler.additional_parameters.temperature)
        assert.equal(4096, handler.additional_parameters.max_tokens)
        -- The stored provider setting stays untouched.
        assert.equal(nil, setting.additional_parameters.reasoning)
        assert.equal(nil, overlay.temperature)
    end),

    test("SyncOptions: reasoning overlay is deep-copied (no aliasing into settings)", function()
        local setting = {
            model = "model-a",
            base_url = "https://example.com/v1",
            handler = "openai",
            additional_parameters = {},
        }
        local overlay = { thinking = { type = "disabled" } }
        local handler = syncWithOverlay("openai", setting, overlay)
        handler.additional_parameters.thinking.type = "enabled"
        assert.equal("disabled", overlay.thinking.type,
            "handler mutation must not leak back into the stored overlay")
    end),
}

return helper.runTests("test_base_sync_options", tests)
