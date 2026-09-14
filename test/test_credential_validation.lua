-- test_credential_validation.lua
-- Tests for the shared credential/field normalization helpers in
-- assistant_utils.lua (validate_credential_field / trimDialogFields).
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {

    -- =========================================================================
    -- validate_credential_field
    -- =========================================================================

    test("validate_credential_field: trims surrounding whitespace and returns true", function()
        local record = { api_key = "  sk-abc123\n" }
        local ok, err = ASUtils.validate_credential_field(record, "api_key", {
            required = "API key is required.",
            whitespace = "API key must not contain spaces.",
        })
        assert.isTrue(ok, "clean value should validate")
        assert.equal(err, nil)
        assert.equal(record.api_key, "sk-abc123", "field should be trimmed in place")
    end),

    test("validate_credential_field: whitespace-only value fails with required message", function()
        local record = { api_key = "   \n\t " }
        local ok, err = ASUtils.validate_credential_field(record, "api_key", {
            required = "API key is required.",
            whitespace = "API key must not contain spaces.",
        })
        assert.isFalse(ok)
        assert.equal(err, "API key is required.")
        assert.equal(record.api_key, "", "field should be normalized to empty")
    end),

    test("validate_credential_field: internal whitespace fails with whitespace message", function()
        local record = { api_key = "sk-abc 123" }
        local ok, err = ASUtils.validate_credential_field(record, "api_key", {
            required = "API key is required.",
            whitespace = "API key must not contain spaces.",
        })
        assert.isFalse(ok)
        assert.equal(err, "API key must not contain spaces.")
    end),

    test("validate_credential_field: scheme enforced when opts.scheme is set", function()
        local record = { base_url = "example.com/v1" }
        local ok, err = ASUtils.validate_credential_field(record, "base_url", {
            required = "Base URL is required.",
            scheme = "Base URL must start with http:// or https://",
            whitespace = "Base URL must not contain spaces.",
        })
        assert.isFalse(ok)
        assert.equal(err, "Base URL must start with http:// or https://")

        local record_ok = { base_url = " https://example.com/v1 " }
        local ok2, err2 = ASUtils.validate_credential_field(record_ok, "base_url", {
            required = "Base URL is required.",
            scheme = "Base URL must start with http:// or https://",
            whitespace = "Base URL must not contain spaces.",
        })
        assert.isTrue(ok2)
        assert.equal(err2, nil)
        assert.equal(record_ok.base_url, "https://example.com/v1")
    end),

    test("validate_credential_field: non-string value fails with required message", function()
        local record = {}
        local ok, err = ASUtils.validate_credential_field(record, "api_key", {
            required = "API key is required.",
            whitespace = "API key must not contain spaces.",
        })
        assert.isFalse(ok)
        assert.equal(err, "API key is required.")
    end),

    -- =========================================================================
    -- trimDialogFields
    -- =========================================================================

    test("trimDialogFields: trims every field of a mock dialog", function()
        local dialog = {
            getFields = function()
                return { "  a  ", "b\n", "   " }
            end,
        }
        local fields = ASUtils.trimDialogFields(dialog)
        assert.equal(fields[1], "a")
        assert.equal(fields[2], "b")
        assert.equal(fields[3], "")
    end),
}

return helper.runTests("credential_validation", tests)
