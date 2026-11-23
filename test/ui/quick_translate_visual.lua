-- test/ui/quick_translate_visual.lua
-- Visual check for dialogs/translate_quick.lua, via the screenshot harness:
-- the panel must actually paint, above the selection when it fits there,
-- below a selection sitting at the top, and mid-screen without a selection.
-- The paint hooks are the point: a bare InputContainer silently never
-- appears, so the pixels are the only trustworthy evidence.
--
-- Usage: SDL_VIDEODRIVER=dummy ./test/runui.sh ui/quick_translate_visual
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local shot = require("test/screenshot")
local wb = require("test/wbuilder")
local Screen = wb.Screen
local QT = require("dialogs/translate_quick")

local W, H = Screen:getWidth(), Screen:getHeight()

-- wbuilder has nothing beneath the dialog stack, so an empty-stack repaint
-- never erases: wipe the framebuffer before each case or the previous
-- panel's ink leaks into the next fingerprint.
local Blitbuffer = require("ffi/blitbuffer")
local function wipe_bb()
    Screen.bb:paintRect(0, 0, W, H, Blitbuffer.COLOR_WHITE)
end

local function build_panel(boxes)
    return function()
        wipe_bb()
        return QT.QuickTranslate:new{
            text = "The Ring was forged in Mount Doom, in secret, by its master.",
            boxes = boxes,
            assistant = { settings = { readSetting = function() return "auto" end } },
            timeout = nil,
        }
    end
end

local cases = {
    {
        name = "panel above a low selection",
        shots = { { name = "above", build = build_panel({ { y = math.floor(H * 0.85), h = 30 } }) } },
        verify = function(ctx)
            local fp = ctx.shots.above
            ctx.check("paints", fp ~= nil and fp.ink_rows > 0)
            ctx.check("ink sits above the selection",
                shot.ink_between(fp, 0, math.floor(H * 0.85) - 40) > 500)
            ctx.check("nothing below the selection",
                shot.ink_between(fp, math.floor(H * 0.85) + 10, H - 1) == 0)
        end,
    },
    {
        name = "panel below a top selection",
        shots = { { name = "below", build = build_panel({ { y = 20, h = 24 } }) } },
        verify = function(ctx)
            local fp = ctx.shots.below
            ctx.check("paints", fp ~= nil and fp.ink_rows > 0)
            ctx.check("nothing above the selection",
                shot.ink_between(fp, 0, 40) == 0)
            ctx.check("ink sits below the selection",
                shot.ink_between(fp, 60, math.floor(H * 0.5)) > 500)
        end,
    },
    {
        name = "panel centered without a selection",
        shots = { { name = "center", build = build_panel(nil) } },
        verify = function(ctx)
            local fp = ctx.shots.center
            ctx.check("paints", fp ~= nil and fp.ink_rows > 0)
            ctx.check("band stays clear of the screen edges",
                fp.first_marked_row > H * 0.2 and fp.last_marked_row < H * 0.8,
                shot.describe(fp))
        end,
    },
}

shot.run(cases)
