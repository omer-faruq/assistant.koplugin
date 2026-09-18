-- test_fetchjson_args.lua
-- Static guard: ASUtils.fetchJSON(url, header, widget, timeout, maxtime,
-- post_body, extractor_fn) takes the error extractor as the 7th argument.
-- Passing it 4th (the timeout slot) makes socketutil:set_timeout receive a
-- function and Browse Models crashes with "bad argument #1 to 'settimeout'".
-- This test fails if any handler FetchModels call puts `function` where the
-- timeout number belongs.
local helper = require("test.helper")
local assert = helper.assert

local function test(name, fn)
    return { name = name, fn = fn }
end

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local HANDLERS = {
    "api_handlers/openai.lua",
    "api_handlers/anthropic.lua",
    "api_handlers/gemini.lua",
    "api_handlers/responses.lua",
}

local function read_file(path)
    local fh = io.open(project_root .. path, "r")
    assert.notNil(fh, "cannot open " .. path)
    local src = fh:read("*a")
    fh:close()
    return src
end

local tests = {}
for _, path in ipairs(HANDLERS) do
    tests[#tests + 1] = test(path .. ": extractor is 7th fetchJSON arg", function()
        local src = read_file(path)
        -- buggy shape: `}, infomsg, function` (extractor in timeout slot)
        assert.notMatches(src, "},%s*infomsg,%s*function",
            path .. " passes extractor as timeout")
        -- fixed shape: `}, infomsg, nil, nil, nil, function`
        assert.matches(src, "fetchJSON%s*%([^)]-infomsg,%s*nil,%s*nil,%s*nil,%s*function",
            path .. " must pass extractor as 7th arg")
    end)
end

return helper.runTests("fetchjson_args", tests)
