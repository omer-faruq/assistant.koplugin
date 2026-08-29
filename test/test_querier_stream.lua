-- test_querier_stream.lua
-- Regression tests for the streaming UI update logic in assistant_querier.lua
-- (showStremDialog).
--
-- Background: commit 6f4b134 introduced a regression where the
-- stream_mode_auto_scroll=false branch still called addTextToInput(delta),
-- which inserts at the cursor and forces the view to follow it to the bottom.
-- The fix restores the pre-6f4b134 behavior for that branch: resyncPos() +
-- setText(full_text, true), preserving the current scroll/cursor position.
--
-- The real flush logic is a local closure inside showStremDialog that needs
-- the full KOReader UI stack, so (per project testing policy) we inline a copy
-- of the pure helper and a driver that mirrors the closure, and test those.
local helper = require("test.helper")
local assert = helper.assert
local strbuf = require("string.buffer")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- =========================================================================
-- Inlined copy of assistant_querier.lua's local `updateStreamText` helper.
-- When auto_scroll=false: manually appends delta to the END of charlist,
-- restores the user's saved charpos+top_line_num, then calls initTextBox.
-- scrollViewToCharPos receives the saved values so the view stays put.
-- =========================================================================
local function updateStreamText(streamDialog, delta, auto_scroll)
    if auto_scroll then
        streamDialog:addTextToInput(delta)
    else
        local widget = streamDialog._input_widget
        widget:resyncPos()
        local saved_top = widget.top_line_num
        local saved_charpos = widget.charpos
        -- Append delta to the end of charlist
        -- (in test we use a simple char-by-char loop instead of koutil.splitToChars)
        for i = 1, #delta do
            table.insert(widget.charlist, delta:sub(i, i))
        end
        widget.charpos = saved_charpos
        widget.top_line_num = saved_top
        widget:initTextBox(nil, true)
    end
end

-- Mock InputDialog that records every UI call made on it.
local function makeMockDialog()
    local calls = { addTextToInput = {}, addChars = {}, setText = {}, resyncPos = 0, initTextBox = {} }
    local inner_widget = { vertical_string_list = { "line" }, lines_per_page = 1, virtual_line_num = 1 }
    local input_widget = {
        charlist = {},
        charpos = 1,
        top_line_num = nil,
        text_widget = { text_widget = inner_widget, updateScrollBar = function() end },
        resyncPos = function(self)
            calls.resyncPos = calls.resyncPos + 1
            self.top_line_num = inner_widget.virtual_line_num
        end,
        addChars = function(_, chars)
            table.insert(calls.addChars, chars)
        end,
        setText = function(_, text, keep_edited_state)
            table.insert(calls.setText, { text = text, keep = keep_edited_state })
        end,
        initTextBox = function(_, text, keep_edited_state)
            table.insert(calls.initTextBox, { text = text, keep = keep_edited_state })
        end,
    }
    local dialog = {
        _input_widget = input_widget,
        addTextToInput = function(_, text)
            table.insert(calls.addTextToInput, text)
        end,
    }
    return dialog, calls
end

-- Driver that mirrors the pending_delta/flush closure and the
-- reasoning->answer transition in assistant_querier.lua showStremDialog.
local function makeStreamDriver(dialog, auto_scroll)
    local pending_delta = strbuf.new() -- delta since the last UI flush
    local flush_scheduled = false
    local reasoning_was_ended = false

    local function flush_to_ui()
        flush_scheduled = false
        local delta = pending_delta:get()
        if #delta == 0 then return end
        updateStreamText(dialog, delta, auto_scroll)
    end

    return {
        -- Mirror of the processStream trunk_callback (coalesced 500ms updates).
        onContent = function(content, reasoning_phase_ended)
            if reasoning_phase_ended and not reasoning_was_ended then
                reasoning_was_ended = true
                if flush_scheduled then
                    flush_scheduled = false
                    flush_to_ui()
                end
                dialog._input_widget.charlist = {}
                dialog._input_widget.charpos = 1
                dialog._input_widget:initTextBox("", true)
            end
            pending_delta:put(content or "")
            if not flush_scheduled then
                flush_scheduled = true
            end
        end,
        -- Mirror of the final unschedule+flush in showStremDialog.
        flush = function()
            if flush_scheduled then
                flush_scheduled = false
                flush_to_ui()
            end
        end,
    }
end

local tests = {

    -- =========================================================================
    -- updateStreamText: auto_scroll=true branch (existing behavior kept)
    -- =========================================================================

    test("auto_scroll=true: appends each delta via addTextToInput", function()
        local dialog, calls = makeMockDialog()
        updateStreamText(dialog, "delta1", true)
        updateStreamText(dialog, "delta2", true)
        assert.equal(#calls.addTextToInput, 2, "addTextToInput should be called for each delta")
        assert.equal(calls.addTextToInput[1], "delta1")
        assert.equal(calls.addTextToInput[2], "delta2")
        assert.equal(#calls.addChars, 0, "addChars must not be used when auto-scroll is on")
        assert.equal(calls.resyncPos, 0, "resyncPos must not be used when auto-scroll is on")
    end),

    -- =========================================================================
    -- updateStreamText: auto_scroll=false branch (regression 6f4b134)
    -- =========================================================================

    test("auto_scroll=false: calls initTextBox instead of addTextToInput", function()
        local dialog, calls = makeMockDialog()
        updateStreamText(dialog, "delta", false)
        assert.equal(#calls.addTextToInput, 0,
            "addTextToInput must NOT be called when auto-scroll is off (regression 6f4b134)")
        assert.equal(calls.resyncPos, 1, "resyncPos preserves the current scroll/cursor position")
        assert.equal(#calls.initTextBox, 1, "initTextBox rebuilds the widget with saved view state")
        assert.equal(calls.initTextBox[1].text, nil)
        assert.equal(calls.initTextBox[1].keep, true)
    end),

    -- =========================================================================
    -- Flush flow: auto_scroll=false preserves view via initTextBox
    -- =========================================================================

    test("flow auto_scroll=false: initTextBox called with coalesced delta", function()
        local dialog, calls = makeMockDialog()
        local driver = makeStreamDriver(dialog, false)
        driver.onContent("Hello ")
        driver.onContent("world")
        driver.flush()
        assert.equal(#calls.addTextToInput, 0,
            "addTextToInput must never be used when auto-scroll is off")
        assert.equal(#calls.initTextBox, 1)
        driver.onContent("!")
        driver.flush()
        assert.equal(#calls.initTextBox, 2)
    end),

    -- =========================================================================
    -- Flush flow: auto_scroll=true keeps existing append behavior
    -- =========================================================================

    test("flow auto_scroll=true: appends coalesced delta via addTextToInput", function()
        local dialog, calls = makeMockDialog()
        local driver = makeStreamDriver(dialog, true)
        driver.onContent("Hello ")
        driver.onContent("world")
        driver.flush()
        -- deltas are coalesced into a single flush (0.5s cadence)
        assert.equal(#calls.addTextToInput, 1)
        assert.equal(calls.addTextToInput[1], "Hello world")
        assert.equal(#calls.addChars, 0)
    end),

    -- =========================================================================
    -- Flush flow: reasoning->answer transition
    -- =========================================================================

    test("flow auto_scroll=false: reasoning->answer transition clears the widget", function()
        local dialog, calls = makeMockDialog()
        local driver = makeStreamDriver(dialog, false)
        -- reasoning phase
        driver.onContent("thinking...")
        driver.flush()
        -- answer phase begins
        driver.onContent("answer one", true)
        driver.onContent(" answer two")
        driver.flush()
        -- Verify transition cleared the widget (initTextBox with text="" and keep=true)
        local found_clear = false
        for _, call in ipairs(calls.initTextBox) do
            if call.text == "" and call.keep == true then
                found_clear = true
                break
            end
        end
        assert.isTrue(found_clear, "transition should clear the input text box")
    end),

    test("flow auto_scroll=false: pending reasoning is flushed before the transition", function()
        local dialog, calls = makeMockDialog()
        local driver = makeStreamDriver(dialog, false)
        driver.onContent("thinking part1")
        driver.onContent(" part2")             -- flush still scheduled
        driver.onContent("answer", true)       -- transition forces the pending flush first
        -- After transition + flush, there should be initTextBox calls both for
        -- the pending reasoning flush and for the transition clear
        assert.isTrue(#calls.initTextBox >= 2,
            "pending reasoning flush + transition clear should each call initTextBox")
    end),
}

return helper.runTests("assistant_querier.lua (stream UI)", tests)
