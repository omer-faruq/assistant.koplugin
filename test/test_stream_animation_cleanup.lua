-- test_stream_animation_cleanup.lua
-- Guards the waiting animation lifecycle in Querier:showStremDialog.
-- UIManager:scheduleIn returns nothing, so the animation must be cancelled
-- through the function reference, and every exit path after processStream
-- must unschedule it. A surviving callback keeps re-queuing itself and
-- blocks Kobo suspend (KOReader HWTCON EPD timer, koreader/assistant issue #215).
-- Headless-safe: the querier pulls the full UI stack, so the source is read
-- as text and the ordering is checked by byte offset.
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

local querier_src = read_source("assistant_querier.lua")

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("animation: scheduleIn return value is not stored", function()
        assert.isFalse(querier_src:find("animation_task = UIManager:scheduleIn", 1, true) ~= nil,
            "animation_task must not capture the nil return of scheduleIn")
    end),

    test("animation: function reference is kept for unschedule", function()
        assert.notNil(querier_src:find("animation_task = updateAnimation", 1, true),
            "animation_task must hold the updateAnimation reference")
    end),

    test("close: animation is cancelled before interrupting the stream", function()
        local close_pos = querier_src:find("local function _closeStreamDialog()", 1, true)
        assert.notNil(close_pos, "_closeStreamDialog missing")
        local unsched_pos = querier_src:find("UIManager:unschedule(animation_task)", close_pos, true)
        local interrupt_pos = querier_src:find("self.interrupt_stream()", close_pos, true)
        assert.notNil(unsched_pos, "close must unschedule the animation")
        assert.notNil(interrupt_pos, "close must interrupt the stream")
        assert.isTrue(unsched_pos < interrupt_pos, "animation must be cancelled before interrupt")
    end),

    test("exit: animation is cancelled after processStream on every path", function()
        local pcall_pos = querier_src:find("pcall(self.processStream, self, res", 1, true)
        assert.notNil(pcall_pos, "processStream pcall missing")
        local cleanup_pos = querier_src:find("-- Cancel the waiting animation on every exit path", pcall_pos, true)
        assert.notNil(cleanup_pos, "post-processStream animation cleanup missing")
        local tool_pos = querier_src:find("type(tool_calls_or_err) == \"table\"", pcall_pos, true)
        assert.notNil(tool_pos, "tool-call branch missing")
        assert.isTrue(cleanup_pos < tool_pos, "cleanup must run before the tool-call early return")
    end),
}

return helper.runTests("stream_animation_cleanup.lua", tests)
