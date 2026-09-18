-- test_querier_error_header.lua
-- Regression tests for the err_header first-line composition in
-- Querier:processStream's non-200 block (assistant_querier.lua): the HTTP
-- code goes first as "[NNN]", and a non-numeric socket-layer reason
-- (e.g. "wantread") must stay visible instead of vanishing under "[0]".
-- The composition is inline in source, so tests mirror it per
-- docs/TESTING.md and call the real BaseHandler.prefixHttpCode.
local helper = require("test.helper")
local assert = helper.assert
local BaseHandler = require("api_handlers.base")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Inline mirror of the source composition; branch structure kept identical.
local function header_first_line(code, status, endpoint)
    local codeNum = tonumber(code) or tonumber(status:match("(%d%d%d)"))
    local reason = status
    if reason == "" and type(code) == "string" and not tonumber(code) and code ~= "" then
        reason = code
    end
    local base = reason ~= "" and reason or endpoint
    if endpoint ~= "" and base ~= endpoint then
        base = base .. " (" .. endpoint .. ")"
    end
    return BaseHandler.prefixHttpCode(codeNum, base)
end

local tests = {
    test("socket reason kept visible (wantread)", function()
        assert.equal(
            header_first_line("wantread", "", "https://host/api"),
            "[0] wantread (https://host/api)")
    end),

    test("http error keeps status and endpoint", function()
        assert.equal(
            header_first_line(400, "HTTP/1.1 400 Bad Request", "https://host/api"),
            "[400] HTTP/1.1 400 Bad Request (https://host/api)")
    end),

    test("string numeric code works", function()
        assert.equal(
            header_first_line("429", "HTTP/1.1 429 Too Many Requests", "https://h"),
            "[429] HTTP/1.1 429 Too Many Requests (https://h)")
    end),

    test("no reason falls back to endpoint", function()
        assert.equal(
            header_first_line("", "", "https://host/api"),
            "[0] https://host/api")
    end),
}

return helper.runTests("querier_error_header", tests)
