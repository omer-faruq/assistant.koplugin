-- helper.lua
-- Sets up KOReader environment, mocks problematic modules, provides assertions.
--
-- Usage in test files:
--   local helper = require("test.helper")
--   local assert = helper.assert
--   helper.mockFetchJSON(returns)  -- configure mock responses

-- 1. Set up KOReader's package.path
require("setupkoenv")

-- 2. Add project root to package.path so test files can require plugin modules
local project_root = debug.getinfo(1).source:match("@(.*/)test/")
if project_root then
    package.path = project_root .. "?.lua;" .. project_root .. "?/init.lua;" .. package.path
end

-- 3. Stub problematic KOReader modules that can't load headless
--    (UI widgets, android, etc.)
local stubs = {
    ["ui/uimanager"]           = { close = function() end, schedule = function() end, show = function() end },
    ["ui/trapper"]             = { dismissableRunInSubprocess = function(self, fn) return fn() end, clear = function() end, wrap = function(self, fn) return fn() end },
    ["ui/widget/infomessage"]  = { new = function(_, o) return o end },
    ["ui/widget/multiinputdialog"] = { new = function(_, o) return o end },
    ["ui/widget/textboxwidget"] = {},
    ["ui/widget/textwidget"]    = {},
    ["ui/widget/button"]        = {},
    ["ui/widget/container"]     = {},
    ["ui/widget/widget"]        = {},
    ["ui/widget"]               = {},
    ["ui/rendertext"]           = {},
    ["ui/device"]               = {},
    ["ui/gesturedetector"]      = {},
    ["ui/input"]                = {},
    ["ui/geometry"]             = {},
    ["ui/font"]                 = { getFace = function() return {} end },
    ["ui/component"]            = {},
    ["ui/size"]                 = {},
    ["ui/widget/trapwidget"]    = {},
    ["ui/widget/notification"]  = { notify = function() end, SOURCE_ALWAYS_SHOW = 1 },
    -- Real widget modules pulled in by assistant_utils -> assistant_notebook
    -- and assistant_search_registry. They require the real "device" module,
    -- whose android probe (pcall(require, "android")) is satisfied by the
    -- empty android stub above, making device.lua load the Android
    -- implementation and crash. Stub them so the real device module is
    -- never required by the test chain.
    ["ui/widget/inputdialog"]   = {},
    ["ui/widget/menu"]          = {},
    ["ui/widget/confirmbox"]    = {},
    ["ui/widget/buttontable"]   = {},
    ["ui"]                      = {},
    ["android"]                 = {},
    -- for assistant_gettext: datastorage mock
    ["datastorage"]             = {
        getDataDir = function() return "/tmp" end,
    },
    -- for assistant_gettext: gettext mock (language)
    ["gettext"]                 = {
        current_lang = "C",
        changeLang = function() end,
        translation = {},
        wrapUntranslated = function(t) return t end,
    },
    -- for socket (if not available)
    ["socket"]                  = {},
    ["socket.http"]             = {},
    ["ssl.https"]               = {},
    ["ltn12"]                   = {},
    ["socketutil"]              = {},
    ["socket.url"]              = {},
    -- for ffi/zlib
    ["ffi/zlib_h"]              = {},
    -- for logger
    ["logger"] = {
        dbg = function(...) end,
        info = function(...) end,
        warn = function(...) end,
        err = function(...) end,
    },
}

-- Install stubs into package.preload so they take effect before the real require
for modname, stub in pairs(stubs) do
    package.preload[modname] = function() return stub end
end

-- 4. Import the real modules we need
local ASUtils = require("assistant_utils")
local extools = require("assistant_exttools")

-- 5. Assertion helpers
local M = {}

M.ASSERTION_FAILED = "ASSERTION_FAILED"

local function fail(msg)
    error(M.ASSERTION_FAILED .. ": " .. msg, 2)
end

M.assert = {
    equal = function(actual, expected, msg)
        if actual ~= expected then
            fail(string.format("%s\nexpected: %s\ngot:      %s", msg or "assertion failed",
                tostring(expected), tostring(actual)))
        end
    end,
    notNil = function(value, msg)
        if value == nil then
            fail(msg or "expected non-nil value, got nil")
        end
    end,
    isTrue = function(value, msg)
        if value ~= true then
            fail(msg or "expected true, got " .. tostring(value))
        end
    end,
    isFalse = function(value, msg)
        if value ~= false then
            fail(msg or "expected false, got " .. tostring(value))
        end
    end,
    matches = function(value, pattern, msg)
        if not value or not value:find(pattern) then
            fail(string.format("%s\nexpected pattern: %s\ngot: %s", msg or "assertion failed",
                pattern, tostring(value)))
        end
    end,
    notMatches = function(value, pattern, msg)
        if value and value:find(pattern) then
            fail(string.format("%s\nexpected NOT to match: %s\ngot: %s", msg or "assertion failed",
                pattern, tostring(value)))
        end
    end,
}

-- 6. Mock for fetchJSON
--    Each test can configure a queue of {parsed, err} responses.
--    The mock returns them in FIFO order.
M.fetchJSON_responses = {}

function M.mockFetchJSON(responses)
    M.fetchJSON_responses = responses
    M.fetchJSON_call_index = 0
end

-- Override ASUtils.fetchJSON with our mock
local originalFetchJSON = ASUtils.fetchJSON
function ASUtils.fetchJSON(url, header, trap_widget, timeout, maxtime, post_body)
    M.fetchJSON_call_index = (M.fetchJSON_call_index or 0) + 1
    local resp = M.fetchJSON_responses[M.fetchJSON_call_index]
    if resp then
        return resp.parsed, resp.err
    end
    -- fallback: call original (for integration tests)
    return originalFetchJSON(url, header, trap_widget, timeout, maxtime, post_body)
end

M.extools = extools
M.ASUtils = ASUtils

-- 7. Test runner
function M.runTests(name, tests)
    local passed = 0
    local failed = 0
    local errors = {}

    print("\n== " .. name .. " ==")

    for _, test in ipairs(tests) do
        local ok, err = pcall(test.fn)
        if ok then
            passed = passed + 1
            print("  PASS: " .. test.name)
        else
            failed = failed + 1
            local msg = err
            -- strip assertion prefix for cleaner output
            if msg:find(M.ASSERTION_FAILED, 1, true) then
                msg = msg:gsub(M.ASSERTION_FAILED .. ": ", "")
            end
            table.insert(errors, { name = test.name, error = msg })
            print("  FAIL: " .. test.name .. " -- " .. msg)
        end
    end

    print(string.format("\n%s: %d passed, %d failed", name, passed, failed))
    return passed, failed, errors
end

return M