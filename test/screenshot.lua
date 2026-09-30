-- test/screenshot.lua
--
-- Headless screenshot harness: shows a real KOReader widget, captures the
-- framebuffer as a PNG, and reduces it to a small set of numbers a test can
-- assert on. Written for scripts run through test/runui.sh with a dummy video
-- driver:
--
--   SDL_VIDEODRIVER=dummy ./test/runui.sh ui/<script>
--
-- Nothing here writes into the repository: PNGs land in OUTPUT_DIR (override
-- with the ASSISTANT_SHOT_DIR environment variable).
--
-- Public surface:
--   screenshot.run(cases, opts)     drive N cases, then quit with an exit code
--   screenshot.capture(name, dir)   framebuffer -> PNG -> fingerprint
--   screenshot.fingerprint(path)    PNG path -> metrics table
--   screenshot.fake(mod, value)     install a module fake for the whole run
--   screenshot.restore()            undo every fake
--   screenshot.describe(fp)         human-readable summary of a fingerprint
--   screenshot.ink_between(fp, a, b)  dark pixels in rows a..b
--
-- A case is { name, shots = { { name, build|widget }, ... }, verify }, where
-- verify(ctx) receives ctx.shots (shot name -> fingerprint), ctx.paths and
-- ctx.check(name, ok, detail).

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

-- wbuilder first: it runs setupkoenv and the SDL init, which is what installs
-- ffi.loadlib (needed by ffi/png) and the live Screen.
local wb = require("test/wbuilder")
local Png = require("ffi/png")
local koutil = require("util")

local M = {}

M.OUTPUT_DIR = os.getenv("ASSISTANT_SHOT_DIR") or "/tmp/opencode/assistant_shots"

-- Fingerprint defaults. "marked" is any non-white pixel; ink is dark enough to
-- be a glyph stroke; panel is the light grey a styled block paints behind its
-- text (#f4f4f4 bubble, #F0F0F0 thought block / dict excerpt). The panel
-- window is deliberately tight and only counts *runs*, so glyph antialiasing
-- never registers as a block background.
M.INK_MAX = 200
M.MARKED_MAX = 250
M.PANEL_MIN = 225
M.PANEL_MAX = 253

-- A grey row narrower than this (px), or a grey block shorter than this (px),
-- is glyph antialiasing, not a styled block.
M.PANEL_MIN_RUN = 40
M.PANEL_MIN_H = 4

-- Number of horizontal bands and the default grid resolution.
M.BANDS = 10
M.GRID_ROWS = 8
M.GRID_COLS = 4

-- The live Screen the captures come from.
M.Screen = wb.Screen

-- ── Module fakes ───────────────────────────────────────────────────────
-- Mirrors the save/restore dance in test/test_hooks.lua: a fake must not
-- survive the script, or the next script sharing the process inherits it.

-- A module that was not loaded at all has to be cleared again on restore, not
-- resurrected, so "was absent" is recorded explicitly: a nil table entry would
-- simply be skipped by pairs().
local ABSENT = {}
local saved = {}

---Install a fake for `modname` for the rest of the run. `value` is either the
---replacement module value or a loader function.
---@param modname string module name
---@param value table|function replacement value or loader
function M.fake(modname, value)
    if not saved[modname] then
        saved[modname] = {
            loaded = package.loaded[modname] or ABSENT,
            preload = package.preload[modname] or ABSENT,
        }
    end
    package.loaded[modname] = nil
    if type(value) == "function" then
        package.preload[modname] = value
    else
        package.preload[modname] = nil
        package.loaded[modname] = value
    end
end

---Undo every fake installed by M.fake().
function M.restore()
    for modname, entry in pairs(saved) do
        package.loaded[modname] = entry.loaded ~= ABSENT and entry.loaded or nil
        package.preload[modname] = entry.preload ~= ABSENT and entry.preload or nil
    end
    saved = {}
end

-- ── Fingerprint ────────────────────────────────────────────────────────

local function new_profile()
    return { ink = 0, panel = 0, marked = 0 }
end

local function bump(profile, value, ink_max, marked_max)
    if value < ink_max then
        profile.ink = profile.ink + 1
        profile.marked = profile.marked + 1
    elseif value < marked_max then
        profile.marked = profile.marked + 1
    end
end

local function ratio(n, d)
    if d == 0 then return 0 end
    return n / d
end

---Reduce a rendered PNG to a small set of assertable numbers.
---
---Metrics:
---  w, h                        image size
---  ink_ratio                   fraction of dark pixels (glyph strokes)
---  panel_ratio                 fraction of pixels inside a long run of the
---                               styled-block grey (bubble / thought block)
---  marked_ratio                fraction of any non-white pixel
---  ink_rows, first/last_marked_row   vertical extent of the content
---  bands[]                     per horizontal band: ink, panel, marked ratios
---                               and a `populated` flag
---  grid / ink_grid / panel_grid       coarse rows x cols density maps
---  panel_boxes[]               the grey block rectangles found, each
---                               { y0, y1, x0, x1, width, height }, ordered
---                               top to bottom
---@param path string PNG file path
---@param opts table|nil optional thresholds/resolutions
---@return table fingerprint, string|nil err
function M.fingerprint(path, opts)
    opts = opts or {}
    local ink_max = opts.ink_max or M.INK_MAX
    local marked_max = opts.marked_max or M.MARKED_MAX
    local panel_min = opts.panel_min or M.PANEL_MIN
    local panel_max = opts.panel_max or M.PANEL_MAX
    local panel_min_run = opts.panel_min_run or M.PANEL_MIN_RUN
    local panel_min_h = opts.panel_min_h or M.PANEL_MIN_H
    local bands = opts.bands or M.BANDS
    local grid_h = opts.grid_h or M.GRID_ROWS
    local grid_w = opts.grid_w or M.GRID_COLS

    local ok, img = Png.decodeFromFile(path, 1)
    if not ok then return nil, img end
    local w, h, data = img.width, img.height, img.data

    local total = new_profile()
    local row_profiles = {}
    for y = 0, h - 1 do
        row_profiles[y] = new_profile()
    end

    -- grid of accumulated counts, so no per-cell re-scan is needed later
    local marked_grid, ink_grid, panel_grid = {}, {}, {}
    for gy = 0, grid_h - 1 do
        marked_grid[gy], ink_grid[gy], panel_grid[gy] = {}, {}, {}
        for gx = 0, grid_w - 1 do
            marked_grid[gy][gx], ink_grid[gy][gx], panel_grid[gy][gx] = 0, 0, 0
        end
    end

    -- A styled block paints a solid grey rectangle behind its text, so on any of
    -- its rows the grey pixels span the whole box even where glyphs cross it.
    -- Rows with fewer than panel_min_run grey pixels are glyph antialiasing, not
    -- a block, and are discarded. What is left merges into one rectangle per
    -- block, which is exactly the geometry the CSS produced.
    local row_runs = {}
    for y = 0, h - 1 do
        local base = y * w
        local count, x0, x1 = 0, nil, nil
        for x = 0, w - 1 do
            local value = data[base + x]
            if value >= panel_min and value <= panel_max then
                count = count + 1
                if not x0 then x0 = x end
                x1 = x
            end
        end
        if count >= panel_min_run then
            row_runs[y] = { x0 = x0, x1 = x1, count = count }
        end
    end

    -- Merge vertically adjacent rows that overlap horizontally into rectangles.
    local raw_boxes = {}
    local open_box = nil
    for y = 0, h - 1 do
        local run = row_runs[y]
        if run then
            if open_box and y == open_box.y1 + 1 and run.x0 <= open_box.x1 and run.x1 >= open_box.x0 then
                open_box.y1 = y
                open_box.x0 = math.min(open_box.x0, run.x0)
                open_box.x1 = math.max(open_box.x1, run.x1)
            else
                open_box = { y0 = y, y1 = y, x0 = run.x0, x1 = run.x1 }
                raw_boxes[#raw_boxes + 1] = open_box
            end
        else
            open_box = nil
        end
    end

    -- Drop antialiasing slivers, then accumulate the panel counts from what
    -- survived, so `panel` never counts a row that turned out not to be a block.
    local panel_boxes = {}
    for raw_idx = 1, #raw_boxes do
        local box = raw_boxes[raw_idx]
        box.width = box.x1 - box.x0 + 1
        box.height = box.y1 - box.y0 + 1
        if box.height >= panel_min_h then
            panel_boxes[#panel_boxes + 1] = box
            for y = box.y0, box.y1 do
                local run = row_runs[y]
                row_profiles[y].panel = row_profiles[y].panel + run.count
                total.panel = total.panel + run.count
                local panel_row = panel_grid[math.floor(y * grid_h / h)]
                for gx = math.floor(run.x0 * grid_w / w), math.floor(run.x1 * grid_w / w) do
                    panel_row[gx] = panel_row[gx] + 1
                end
            end
        end
    end

    for y = 0, h - 1 do
        local row = row_profiles[y]
        local gx_row, ink_row = marked_grid[math.floor(y * grid_h / h)], ink_grid[math.floor(y * grid_h / h)]
        local base = y * w
        for x = 0, w - 1 do
            local value = data[base + x]
            if value < marked_max then
                bump(total, value, ink_max, marked_max)
                bump(row, value, ink_max, marked_max)
                local gx = math.floor(x * grid_w / w)
                gx_row[gx] = gx_row[gx] + 1
                if value < ink_max then ink_row[gx] = ink_row[gx] + 1 end
            end
        end
    end

    local band_h = math.ceil(h / bands)
    local band_list = {}
    local band_count = 0
    for b = 0, bands - 1 do
        local profile = new_profile()
        local y0, y1 = b * band_h, math.min(h - 1, (b + 1) * band_h - 1)
        local cells = 0
        for y = y0, y1 do
            local row = row_profiles[y]
            profile.ink = profile.ink + row.ink
            profile.panel = profile.panel + row.panel
            profile.marked = profile.marked + row.marked
            cells = cells + (y1 - y0 + 1)
        end
        local pixels = cells * w
        band_list[b] = {
            y0 = y0,
            y1 = y1,
            ink = ratio(profile.ink, pixels),
            panel = ratio(profile.panel, pixels),
            marked = ratio(profile.marked, pixels),
            populated = profile.marked > 0,
        }
        band_count = band_count + 1
    end

    local function to_ratio_map(grid)
        local out = {}
        for gy = 0, grid_h - 1 do
            out[gy] = {}
            for gx = 0, grid_w - 1 do
                out[gy][gx] = ratio(grid[gy][gx], w * h / (grid_h * grid_w))
            end
        end
        return out
    end

    local ink_rows, first_marked, last_marked = 0, nil, nil
    local row_ink = {}
    for y = 0, h - 1 do
        local row = row_profiles[y]
        row_ink[y] = row.ink
        if row.ink > 0 then ink_rows = ink_rows + 1 end
        if row.marked > 0 then
            if not first_marked then first_marked = y end
            last_marked = y
        end
    end

    local pixels = w * h
    return {
        w = w,
        h = h,
        ink_ratio = ratio(total.ink, pixels),
        panel_ratio = ratio(total.panel, pixels),
        marked_ratio = ratio(total.marked, pixels),
        ink_rows = ink_rows,
        row_ink = row_ink,
        first_marked_row = first_marked,
        last_marked_row = last_marked,
        band_h = band_h,
        band_count = band_count,
        bands = band_list,
        grid_h = grid_h,
        grid_w = grid_w,
        grid = to_ratio_map(marked_grid),
        ink_grid = to_ratio_map(ink_grid),
        panel_grid = to_ratio_map(panel_grid),
        panel_boxes = panel_boxes,
    }
end

---Total dark pixels in the rows y0..y1 (inclusive), clamped to the image.
---@param fp table fingerprint
---@param y0 number first row
---@param y1 number last row
---@return number
function M.ink_between(fp, y0, y1)
    local total = 0
    for y = math.max(0, y0), math.min(fp.h - 1, y1) do
        total = total + fp.row_ink[y]
    end
    return total
end

---A compact multi-line summary, for reading a failure in the console.
---@param fp table fingerprint
---@return string
function M.describe(fp)
    if not fp then return "<no fingerprint>" end
    local lines = {
        string.format("%dx%d  ink %.4f  panel %.4f  ink_rows %d  marked rows %s..%s",
            fp.w, fp.h, fp.ink_ratio, fp.panel_ratio, fp.ink_rows,
            tostring(fp.first_marked_row), tostring(fp.last_marked_row)),
        string.format("panel boxes: %d", #fp.panel_boxes),
    }
    for i, box in ipairs(fp.panel_boxes) do
        lines[#lines + 1] = string.format("  box %d  y %4d..%4d  x %4d..%4d  (%dx%d)",
            i, box.y0, box.y1, box.x0, box.x1, box.width, box.height)
    end
    for b = 0, fp.band_count - 1 do
        local band = fp.bands[b]
        lines[#lines + 1] = string.format("  band %2d  y %4d..%4d  ink %.4f  panel %.4f  %s",
            b, band.y0, band.y1, band.ink, band.panel, band.populated and "#" or ".")
    end
    return table.concat(lines, "\n")
end

-- ── Capture ────────────────────────────────────────────────────────────

local function ensure_dir(dir)
    if not koutil.pathExists(dir) then
        local ok, err = koutil.makePath(dir)
        if not ok then error("cannot create shot dir " .. tostring(dir) .. ": " .. tostring(err)) end
    end
end

---Capture the current framebuffer to `<dir>/<name>.png` and fingerprint it.
---@param name string shot name
---@param dir string|nil output directory, defaults to M.OUTPUT_DIR
---@return table fingerprint, string path
function M.capture(name, dir)
    dir = dir or M.OUTPUT_DIR
    ensure_dir(dir)
    local path = dir .. "/" .. name .. ".png"
    M.Screen:shot(path)
    local fp, err = M.fingerprint(path)
    if not fp then error("cannot fingerprint " .. path .. ": " .. tostring(err)) end
    return fp, path
end

-- ── Runner ─────────────────────────────────────────────────────────────

local function shot_widget(shot)
    if type(shot.build) == "function" then return shot.build() end
    return shot.widget
end

---Show each case's widgets in turn, capture each, then run its assertions.
---
---Exits the process with 0 when every check passed and 1 otherwise.
---@param cases table[] cases of { name, shots = { { name, build|widget } }, verify = function(ctx) }
---@param opts table|nil { dir = string }
function M.run(cases, opts)
    opts = opts or {}
    local dir = opts.dir or M.OUTPUT_DIR
    local UIManager = wb.UIManager
    -- Each shot closes its widget before the next one is shown, which leaves
    -- the window stack empty for a tick; without this UIManager would treat
    -- that gap as "no dialogs left" and quit the process mid-run.
    UIManager:setRunForeverMode()

    local passed, failed = 0, 0
    local function record(ok, name, detail)
        if ok then
            passed = passed + 1
            print("  PASS: " .. name)
        else
            failed = failed + 1
            print("  FAIL: " .. name .. (detail and (" -- " .. detail) or ""))
        end
    end

    local index = 0
    local function step()
        index = index + 1
        if index > #cases then
            M.restore()
            print(string.format("\n%d passed, %d failed", passed, failed))
            UIManager:unsetRunForeverMode()
            UIManager:quit(failed > 0 and 1 or 0)
            return
        end

        local case = cases[index]
        print("\n== " .. case.name .. " ==")
        local fingerprints = {}
        local paths = {}
        local shot_index = 0
        local shoot_next

        local function run_verify()
            local ctx = {
                shots = fingerprints,
                paths = paths,
                check = function(name, ok, detail) record(ok, name, detail) end,
            }
            local ok, err = pcall(case.verify, ctx)
            if not ok then record(false, case.name .. " raised", tostring(err)) end
            UIManager:scheduleIn(0, step)
        end

        shoot_next = function()
            shot_index = shot_index + 1
            local entry = case.shots and case.shots[shot_index]
            if not entry then return run_verify() end
            local built, widget = pcall(shot_widget, entry)
            if not built then
                record(false, "shot " .. entry.name .. " raised", tostring(widget))
                return shoot_next()
            end
            UIManager:show(widget)
            UIManager:scheduleIn(0.4, function()
                UIManager:forceRePaint()
                -- The blitbuffer only holds painted pixels, so the capture has to
                -- land on a later tick than the repaint.
                UIManager:scheduleIn(0.4, function()
                    local fp, path = M.capture(entry.name, dir)
                    fingerprints[entry.name] = fp
                    paths[entry.name] = path
                    print("  shot " .. entry.name .. " -> " .. path)
                    UIManager:close(widget)
                    shoot_next()
                end)
            end)
        end

        shoot_next()
    end

    step()
    -- UIManager:quit() only records the code in self._exit_code; upstream
    -- reader.lua is what turns it into a process status. Without this, every
    -- visual run exits 0 and a failing check can never fail CI.
    local exit_code = UIManager:run()
    os.exit(exit_code or 0, true)
end

return M
