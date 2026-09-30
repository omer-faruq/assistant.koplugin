-- test_stream_status.lua
-- Guards the streaming dialog's status row (assistant_querier.lua).
--
-- showStremDialog renders a StreamDialog (an InputDialog subclass) whose init
-- reserves a status row's height via the `_added_widgets` budget and then
-- moves it directly below the title bar (the provider/model line). The row
-- flips waiting -> reasoning -> answer as processChunk records each channel on
-- self.stream_phase.
--
-- The dialog needs the full KOReader widget stack, so (per docs/TESTING.md) the
-- UI wiring is checked by source scan and the phase -> label selection by a
-- mirror of the updateStatusRow closure.
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

-- Mirror of showStremDialog's updateStatusRow selection (an unknown/nil phase
-- falls back to "waiting"). Glyphs live outside _() in the source; they are
-- reproduced here so the expected label matches the rendered one.
local STREAM_GLYPHS = { waiting = "⌛ ", reasoning = "☕ ", answer = "✍ " }
local STREAM_TEXTS  = {
    waiting   = "Waiting for the model ...",
    reasoning = "Thinking ...",
    answer    = "Composing answer ...",
}
local function pick_label(phase)
    phase = phase or "waiting"
    return STREAM_GLYPHS[phase] .. STREAM_TEXTS[phase]
end

local tests = {
    test("StreamDialog subclass provides a live status row", function()
        assert.matches(querier_src, "local StreamDialog = InputDialog:extend{}",
            "StreamDialog must extend InputDialog")
        assert.matches(querier_src, "function StreamDialog:setStatus%(label%)",
            "setStatus must update the row")
        assert.matches(querier_src, "function StreamDialog:init%(%)",
            "init must build/reposition the row")
    end),

    test("the stream dialog is built as a StreamDialog", function()
        assert.matches(querier_src, "streamDialog = StreamDialog:new%{",
            "showStremDialog must instantiate StreamDialog")
        assert.notMatches(querier_src, "streamDialog = InputDialog:new%{",
            "the plain InputDialog constructor must be gone")
    end),

    test("init budgets the row height and moves it below the title bar", function()
        assert.matches(querier_src, "self%._added_widgets = %{ self%._status_row %}",
            "row must be reserved through the _added_widgets height budget")
        assert.matches(querier_src, "table%.insert%(self%.vgroup, 2, self%._status_row%)",
            "row must be moved to vgroup[2], directly under the title bar")
    end),

    test("processChunk records the reasoning and answer channels", function()
        assert.matches(querier_src, 'self%.stream_phase = "reasoning"',
            "reasoning chunks must set the reasoning phase")
        assert.matches(querier_src, 'self%.stream_phase = "answer"',
            "answer chunks must set the answer phase")
        assert.matches(querier_src, "updateStatusRow%(%)",
            "the trunk callback must refresh the row")
    end),

    test("status labels cover waiting/reasoning/answer", function()
        for i = 1, #STREAM_TEXTS do
            local escaped = (STREAM_TEXTS[i]:gsub("%p", "%%%0"))
            assert.matches(querier_src, escaped, "missing status label: " .. STREAM_TEXTS[i])
        end
    end),

    test("labels lead with the requested glyphs, outside the gettext msgid", function()
        local pairs_ = {
            { "⌛", "Waiting for the model ..." },
            { "☕", "Thinking ..." },
            { "✍", "Composing answer ..." },
        }
        for i = 1, #pairs_ do
            local needle = '"' .. pairs_[i][1] .. ' " .. _("' .. pairs_[i][2] .. '")'
            assert.notNil(querier_src:find(needle, 1, true),
                "source must lead the label with " .. pairs_[i][1])
        end
    end),

    test("phase selection falls back to waiting", function()
        assert.equal(pick_label(nil), "⌛ Waiting for the model ...")
        assert.equal(pick_label("reasoning"), "☕ Thinking ...")
        assert.equal(pick_label("answer"), "✍ Composing answer ...")
    end),
}

return helper.runTests("assistant_querier.lua (stream status row)", tests)
