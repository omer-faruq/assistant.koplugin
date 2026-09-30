-- test/ui/stream_status.lua
-- Renders the real streaming dialog (Querier:showStremDialog in
-- assistant_querier.lua) and asserts on the pixels that the status row is
-- there, that it sits in the gap between the title bar and the composing
-- window, and that each phase paints its own label.
--
-- The phase -> label table (STREAM_STATUS_LABELS) is a file-local in
-- assistant_querier.lua and is only ever read from inside the updateStatusRow
-- closure, so it cannot be called as a function from anywhere. This script
-- therefore drives the shipped entry point instead: it hands showStremDialog a
-- stub processStream that records one phase and pushes one chunk, which is
-- exactly the seam the real processChunk uses. Everything below the entry
-- point is the shipped code -- StreamDialog:init's _added_widgets height
-- budget, the move to vgroup[2], the updateStatusRow closure and setStatus.
--
-- Everything is checked differentially: the phase shots carry the same answer
-- text and differ only in self.stream_phase, so the rows whose ink changes
-- between two shots *are* the status row. Nothing here hardcodes a label or a
-- glyph, so this script owns the phase -> label mapping and the headless suite
-- needs no mirror of it.
--
-- Usage: SDL_VIDEODRIVER=dummy ./test/runui.sh ui/stream_status
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local shot = require("test/screenshot")
local wb = require("test/wbuilder")
local UIManager = wb.UIManager
local Screen = wb.Screen
local Querier = require("assistant_querier")
local InputDialog = require("ui/widget/inputdialog")

local W, H = Screen:getWidth(), Screen:getHeight()

-- One chunk of answer text, identical in every phase shot: the row is then the
-- only thing that can differ between them.
local CONTENT = "The answer streams into the composing window one chunk at a time,"
    .. " while the status row above it reports which channel is being read."

local IDENTITY = { label = "Test Provider", model = "test-model" }

-- ── Stubs for the two collaborators showStremDialog reaches out to ────────

local SETTINGS = {
    large_stream_dialog = true,
    stream_mode_auto_scroll = true,
    response_font_size = 20,
    show_reasoning = false,
}

local mock_settings = {
    readSetting = function(dummy, key, def)
        local value = SETTINGS[key]
        if value ~= nil then return value end
        return def
    end,
    toggle = function() end,
}

local mock_assistant = {
    settings = mock_settings,
    showProviderDialog = function() end,
}

-- ── Drivers ─────────────────────────────────────────────────────────────

--- Build the shipped stream dialog in one phase and hand back the live widget.
---showStremDialog closes the dialog before it returns (every code path does),
--- so UIManager.close is muted for the duration of the call and the widget is
--- kept on screen for the harness to shoot.
---@param phase string|nil value for self.stream_phase (nil == "waiting")
---@param text string|nil chunk handed to the trunk callback
---@return table the live StreamDialog

-- Dialogs built so far: the shots are captured on later ticks, so the widget
-- the geometry comes from has to outlive its build function.
local built = {}

local function build_stream_dialog(phase, text)
    local captured
    local saved_show = UIManager.show
    local saved_close = UIManager.close

    Querier.settings = mock_settings
    Querier.assistant = mock_assistant
    Querier.processStream = function(self, res, trunk)
        self.stream_phase = phase
        trunk(text or CONTENT)
        return nil
    end

    UIManager.show = function(self, widget, ...)
        captured = widget
        return saved_show(self, widget, ...)
    end
    UIManager.close = function(self, widget, ...)
        if widget == captured then return end
        return saved_close(self, widget, ...)
    end
    local ok, err = pcall(function()
        Querier:showStremDialog(function() return nil end, "AI is responding", IDENTITY)
    end)
    UIManager.show = saved_show
    UIManager.close = saved_close
    if not ok then error(err) end
    if not captured then error("showStremDialog never showed a dialog") end
    built.stream_dialog = captured
    return captured
end

-- The same dialog without a status row: the control the row is measured
-- against. Anything the row takes from the composing window shows up here.
local function build_control_dialog()
    local dialog = InputDialog:new{
        title = "AI is responding",
        description = "✦ " .. IDENTITY.label .. "/" .. IDENTITY.model,
        input_face = require("ui/font"):getFace("infofont", SETTINGS.response_font_size),
        width = W - 2 * require("ui/size").padding.large,
        use_available_height = true,
        is_movable = false,
        readonly = true,
        allow_newline = true,
        add_nav_bar = false,
        cursor_at_end = true,
        add_scroll_buttons = true,
        condensed = true,
        buttons = { { { text = "Close", id = "close" } } },
    }
    dialog._input_widget:setText(CONTENT, true)
    built.control_dialog = dialog
    return dialog
end

-- ── Fingerprint helpers ─────────────────────────────────────────────────

--- Rows whose ink differs between two fingerprints, as first..last.
---@param a table fingerprint
---@param b table fingerprint
---@param tol number|nil per-row ink delta to ignore
---@return number|nil y0, number|nil y1
local function changed_band(a, b, tol)
    tol = tol or 0
    local y0, y1 = nil, nil
    for y = 0, a.h - 1 do
        if math.abs((a.row_ink[y] or 0) - (b.row_ink[y] or 0)) > tol then
            if not y0 then y0 = y end
            y1 = y
        end
    end
    return y0, y1
end

-- VerticalGroup hands out offsets, not dimens, so a row's screen position is
-- the vgroup origin (the title bar paints at offset 0 of the same vgroup) plus
-- the stacked height of everything above it. That is the geometry the row
-- really occupies on screen.
local function geometry(dialog)
    local vgroup = dialog.vgroup
    local origin_y = dialog.title_bar.dimen.y
    local row_index
    for i = 1, #vgroup do
        if vgroup[i] == dialog._status_row then
            row_index = i
            break
        end
    end
    if not row_index then return nil end
    local row_top = origin_y
    for i = 1, row_index - 1 do
        row_top = row_top + vgroup[i]:getSize().h
    end
    local row_size = dialog._status_row:getSize()
    local title = dialog.title_bar.dimen
    local input = dialog._input_widget.dimen
    local frame = dialog.dialog_frame.dimen
    return {
        row_index = row_index,
        row = row_size,
        title = title,
        input = input,
        frame = frame,
        title_bottom = title.y + title.h,
        row_top = row_top,
        row_bottom = row_top + row_size.h,
    }
end

-- The same reading for the control dialog, which has no status row.
local function plain_geometry(dialog)
    return { input = dialog._input_widget.dimen }
end

-- Ink in a band, ignoring the frame's own rules. The dialog border and the
-- composing window's outline paint dark pixels on every row they span -- a few
-- on the sides, a full-width sweep across the top -- so a plain ink total
-- reports an empty band as painted. A glyph row is one that carries ink well
-- above the hairline yet not a full-width rule, which is what the status row's
-- text looks like and what a blank row does not.
local HAIRLINE_INK = 20
-- A rule sweeps essentially the whole width; even a dense line of text stays
-- well short of that.
local RULE_INK = 0.85

--- Whether one row carries glyph ink rather than a frame rule or hairline.
---@param fp table fingerprint
---@param y number row index
---@return boolean
local function is_glyph_row(fp, y)
    local ink = fp.row_ink[y] or 0
    return ink > HAIRLINE_INK and ink < RULE_INK * fp.w
end

--- How many rows of y0..y1 carry glyph ink.
---@param fp table fingerprint
---@param y0 number first row
---@param y1 number last row
---@return number
local function glyph_rows(fp, y0, y1)
    local count = 0
    for y = math.max(0, y0), math.min(fp.h - 1, y1) do
        if is_glyph_row(fp, y) then count = count + 1 end
    end
    return count
end

local function band_text(fp, y0, y1)
    return string.format("changed rows %s..%s, row box y %d..%d",
        tostring(y0), tostring(y1), y0 or -1, y1 or -1)
end

-- ── Cases ───────────────────────────────────────────────────────────────

local PHASES = { "waiting", "reasoning", "answer" }

shot.run({
    -- 1. The row exists, is built by the shipped init(), and paints ink.
    {
        name = "the status row exists",
        shots = {
            { name = "waiting", build = function() return build_stream_dialog(nil) end },
        },
        verify = function(ctx)
            local fp = ctx.shots.waiting
            local dialog = built.stream_dialog
            ctx.check("the stream dialog paints", fp.ink_ratio > 0.005,
                string.format("ink_ratio %.5f", fp.ink_ratio))
            ctx.check("the dialog carries a status row and a label",
                dialog and dialog._status_row and dialog._status_widget ~= nil
                    and type(dialog.status_label) == "string" and #dialog.status_label > 0,
                "no _status_row / no status_label")
            if not dialog then return end
            local g = geometry(dialog)
            if not g then
                ctx.check("the row is in the dialog's vgroup", false,
                    "_status_row is not a vgroup child")
                return
            end
            ctx.check("the row has a real height", g.row.h > 0.01 * H,
                string.format("row height %d of %d", g.row.h, H))
            local painted = glyph_rows(fp, g.row_top, g.row_bottom - 1)
            ctx.check("the row paints glyphs across its own band",
                painted >= 5,
                string.format("%d glyph rows in rows %d..%d",
                    painted, g.row_top, g.row_bottom - 1))
        end,
    },

    -- 2. Each phase paints its own label: three shots, same text, one phase
    --    apart, so every row that changes between two of them is the row.
    {
        name = "phases paint different labels",
        shots = {
            { name = "waiting", build = function() return build_stream_dialog(nil) end },
            { name = "reasoning", build = function() return build_stream_dialog("reasoning") end },
            { name = "answer", build = function() return build_stream_dialog("answer") end },
            -- A phase the label table does not know: the row has to fall back
            -- to the waiting label instead of going blank.
            { name = "unknown", build = function() return build_stream_dialog("nonsense") end },
        },
        verify = function(ctx)
            local g = geometry(built.stream_dialog)
            if not g then
                ctx.check("the row is in the dialog's vgroup", false,
                    "_status_row is not a vgroup child")
                return
            end
            local band = { y0 = g.row_top, y1 = g.row_bottom - 1 }
            for i = 1, #PHASES - 1 do
                local name_a, name_b = PHASES[i], PHASES[i + 1]
                local fp_a, fp_b = ctx.shots[name_a], ctx.shots[name_b]
                local y0, y1 = changed_band(fp_a, fp_b)
                ctx.check(name_a .. " and " .. name_b .. " paint different labels",
                    y0 ~= nil and y1 ~= nil, band_text(fp_a, y0, y1))
                if y0 and y1 then
                    ctx.check("the " .. name_a .. "/" .. name_b
                        .. " difference is the row itself",
                        y0 >= band.y0 - 2 and y1 <= band.y1 + 2,
                        band_text(fp_a, y0, y1))
                    -- Outside the row nothing moves: the composing window is
                    -- byte-identical, so a phase that repainted more than its
                    -- label is caught here.
                    ctx.check("the " .. name_a .. "/" .. name_b
                        .. " change is confined to the row",
                        shot.ink_between(fp_a, 0, band.y0 - 1)
                            == shot.ink_between(fp_b, 0, band.y0 - 1),
                        "content above the row changed")
                end
            end
            -- A phase whose label renders nothing would leave the row blank;
            -- the ink has to be there in every phase, not just differ.
            for i = 1, #PHASES do
                local fp = ctx.shots[PHASES[i]]
                local painted = glyph_rows(fp, band.y0, band.y1)
                ctx.check(PHASES[i] .. " paints glyphs in the row band",
                    painted >= 5,
                    string.format("%d glyph rows in rows %d..%d",
                        painted, band.y0, band.y1))
            end

            -- An unmapped phase must leave a readable row, never a blank one:
            -- the row is the only progress cue the streaming window has.
            local unknown_painted = glyph_rows(ctx.shots.unknown, band.y0, band.y1)
            ctx.check("an unmapped phase leaves the row readable",
                unknown_painted >= 5,
                string.format("%d glyph rows in rows %d..%d",
                    unknown_painted, band.y0, band.y1))
        end,
    },

    -- 3. Placement: the row lives between the title bar and the composing
    --    window, and the height it reserves comes out of the composing window
    --    without clipping it.
    {
        name = "placement and reserved height",
        shots = {
            { name = "stream", build = function() return build_stream_dialog(nil) end },
            { name = "control", build = build_control_dialog },
        },
        verify = function(ctx)
            local dialog = built.stream_dialog
            local control_dialog = built.control_dialog
            if not dialog or not control_dialog then return end
            local g = geometry(dialog)
            if not g then
                ctx.check("the row is in the dialog's vgroup", false,
                    "_status_row is not a vgroup child")
                return
            end
            local control = plain_geometry(control_dialog)

            ctx.check("the row is the second entry of the vgroup",
                g.row_index == 2 and dialog.vgroup[1] == dialog.title_bar,
                "vgroup[1]/[2] are not the title bar and the row")
            ctx.check("the row sits below the title bar",
                g.row_top >= g.title_bottom - 1,
                string.format("title ends at %d, row starts at %d", g.title_bottom, g.row_top))
            ctx.check("the row sits above the composing window",
                g.row_bottom <= g.input.y + 1,
                string.format("row ends at %d, text starts at %d", g.row_bottom, g.input.y))
            ctx.check("the row is inside the dialog frame",
                g.row_top >= g.frame.y and g.row_bottom <= g.frame.y + g.frame.h + 1,
                string.format("frame y %d..%d, row y %d..%d",
                    g.frame.y, g.frame.y + g.frame.h, g.row_top, g.row_bottom))

            -- use_available_height pins the vgroup to the screen, so the row does not
            -- simply add its height: it pushes the composing window down and
            -- takes the room from it. Both edges have to move.
            ctx.check("the row's height comes out of the composing window",
                g.input.y > control.input.y and g.input.h < control.input.h,
                string.format("window y %d..%d against control y %d..%d",
                    g.input.y, g.input.y + g.input.h,
                    control.input.y, control.input.y + control.input.h))
            ctx.check("the composing window keeps its share of the dialog",
                control and g.input.h > 0.5 * control.input.h,
                control and string.format("input height %d of %d", g.input.h, control.input.h)
                    or "no control")
            ctx.check("nothing overflows the frame",
                g.input.y + g.input.h <= g.frame.y + g.frame.h + 2,
                string.format("text ends at %d, frame ends at %d",
                    g.input.y + g.input.h, g.frame.y + g.frame.h))
            -- Not clipped: the first line of the answer is painted inside the
            -- window the row pushed down.
            -- Not clipped: the composing window's own ink starts below the row, and
            -- there is a full line of it, so reserving the row's height pushed
            -- the content down instead of hiding it.
            local first_ink
            for y = g.input.y, g.input.y + 60 do
                if glyph_rows(ctx.shots.stream, y, y) > 0 then first_ink = y break end
            end
            local lines = glyph_rows(ctx.shots.stream, first_ink or g.input.y,
                (first_ink or g.input.y) + 12)
            ctx.check("the answer is painted below the row, not clipped away",
                first_ink ~= nil and first_ink >= g.row_bottom and lines >= 6,
                string.format("first glyph row %s (row ends at %d), %d glyph rows of text",
                    tostring(first_ink), g.row_bottom, lines))
        end,
    },
})