-- test/ui/rtl_render.lua
-- The RTL display pipeline as pixels: per-block direction over a mixed
-- Persian/English reply, the gate that keeps the pipeline off for LTR
-- users, and the Response Font registration.
--
-- Every direction check is paired with its perturbation: the same page with
-- the dir= attributes stripped must flip the Persian line to the left edge,
-- or the check proves nothing.
--
-- Usage: SDL_VIDEODRIVER=dummy ./test/runui.sh ui/rtl_render
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local shot = require("test/screenshot")
local wb = require("test/wbuilder")
local Png = require("ffi/png")
local Screen = wb.Screen
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local ResultViewer = require("assistant_viewer")

local W, H = Screen:getWidth(), Screen:getHeight()

-- ── Fakes ──────────────────────────────────────────────────────────────
local switches = {
    minimalist_mode = false,
    show_reasoning = false,
    auto_prompt_suggest = false,
    response_direction = "auto",
    response_justified = false,
    response_font_face = nil,
}

local mock_assistant = {
    settings = {
        readSetting = function(dummy, key, def)
            local value = switches[key]
            if value ~= nil then return value end
            return def
        end,
    },
    config = {
        getFeature = function() return nil end,
        getActiveProviderId = function() return "test-provider" end,
    },
    ui = { doc_settings = true },
    ui_language_is_rtl = true,
    showProviderDialog = function() end,
    assistant_dialog = { runPrompt = function() end },
    querier = { provider_name = "test-provider", is_inited = function() return true end },
}

-- ── Page builder ───────────────────────────────────────────────────────
local function make_viewer(text)
    return ResultViewer:new{
        title = "RTL render",
        text = text,
        assistant = mock_assistant,
    }
end

local function wrap(html, css)
    local widget = ScrollHtmlWidget:new{
        html_body = html,
        css = css,
        default_font_size = Screen:scaleBySize(20),
        width = W,
        height = H,
    }
    return CenterContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = W, h = H }, widget }
end

local function page(text)
    local viewer = make_viewer(text)
    return wrap(viewer:_renderMarkdown(), viewer:_buildCSS())
end

-- The same page with the direction annotations removed: the perturbation a
-- direction check must be able to go red against.
local function page_without_dir(text)
    local viewer = make_viewer(text)
    local html = (viewer:_renderMarkdown():gsub(' dir="rtl"', ""):gsub(' dir="ltr"', ""))
    return wrap(html, viewer:_buildCSS())
end

-- ── Content: two one-line paragraphs, one Persian and one English ──────
local PERSIAN = "این یک متن فارسی است."
local ENGLISH = "This is an English sentence."
local MIXED = PERSIAN .. "\n\n" .. ENGLISH .. "\n\n"

-- ── Pixel helpers ──────────────────────────────────────────────────────
local INK_MAX = 200

-- Contiguous ink rows in y0..y1: one entry per painted text line.
local function ink_bands(fp, y0, y1)
    local bands = {}
    local open
    for y = y0, y1 do
        if (fp.row_ink[y] or 0) > 0 then
            if open then
                open.y1 = y
            else
                open = { y0 = y, y1 = y }
                bands[#bands + 1] = open
            end
        else
            open = nil
        end
    end
    return bands
end

-- Dark pixels left and right of the window's middle, inside rows y0..y1.
local function side_ink(path, y0, y1)
    local ok, img = Png.decodeFromFile(path, 1)
    if not ok then return 0, 0 end
    local w, data = img.width, img.data
    local left, right = 0, 0
    for y = y0, y1 do
        local base = y * w
        for x = 0, w - 1 do
            if data[base + x] <= INK_MAX then
                if x < w / 2 then
                    left = left + 1
                else
                    right = right + 1
                end
            end
        end
    end
    return left, right
end

shot.run({
    -- 1. Mixed reply: the Persian line is RTL (right edge), the English line
    --    is LTR (left edge). The perturbation strips the dir= attributes and
    --    both lines must land on the left.
    {
        name = "per-block direction",
        shots = {
            { name = "mixed", build = function() return page(MIXED) end },
            { name = "stripped", build = function() return page_without_dir(MIXED) end },
        },
        verify = function(ctx)
            local fp = ctx.shots.mixed
            local bands = ink_bands(fp, 0, 0.5 * fp.h)
            ctx.check("the reply paints two text lines", #bands >= 2,
                "ink bands: " .. #bands .. "\n" .. shot.describe(fp))
            if #bands >= 2 then
                local p_left, p_right = side_ink(ctx.paths.mixed, bands[1].y0, bands[1].y1)
                ctx.check("the Persian line hugs the right edge",
                    p_right > 2 * p_left,
                    string.format("persian left %d right %d", p_left, p_right))
                local e_left, e_right = side_ink(ctx.paths.mixed, bands[2].y0, bands[2].y1)
                ctx.check("the English line hugs the left edge",
                    e_left > 2 * e_right,
                    string.format("english left %d right %d", e_left, e_right))
            end
            -- Perturbation: without the dir= attributes the Persian line
            -- loses its base direction and falls back to the left edge.
            local sfp = ctx.shots.stripped
            local sbands = ink_bands(sfp, 0, 0.5 * sfp.h)
            if #sbands >= 1 then
                local s_left, s_right = side_ink(ctx.paths.stripped, sbands[1].y0, sbands[1].y1)
                ctx.check("dropping dir= flips the Persian line to the left",
                    s_left > 2 * s_right,
                    string.format("stripped left %d right %d", s_left, s_right))
            else
                ctx.check("the perturbed page still paints", false, "no ink bands")
            end
        end,
    },

    -- 2. The gate: the same reply with the direction set to Left to Right is
    --    plain LTR, both lines on the left. This is the whole pipeline an
    --    English or Chinese user sees -- none of it.
    {
        name = "pipeline off for LTR users",
        shots = {
            { name = "off", build = function()
                switches.response_direction = "ltr"
                local widget = page(MIXED)
                switches.response_direction = "auto"
                return widget
            end },
        },
        verify = function(ctx)
            local fp = ctx.shots.off
            local bands = ink_bands(fp, 0, 0.5 * fp.h)
            ctx.check("the reply still paints two text lines", #bands >= 2,
                "ink bands: " .. #bands .. "\n" .. shot.describe(fp))
            if #bands >= 2 then
                for i = 1, 2 do
                    local l, r = side_ink(ctx.paths.off, bands[i].y0, bands[i].y1)
                    ctx.check("switch off keeps line " .. i .. " on the left",
                        l > 2 * r, string.format("line %d left %d right %d", i, l, r))
                end
            end
        end,
    },

    -- 3. The Response Font: the switch resolves to @font-face rules over the
    --    real font files (Noto Naskh Arabic is shipped with KOReader). The
    --    rendered result is for the eye; the wiring is asserted on the CSS
    --    the shipped builder produced.
    {
        name = "response font",
        shots = {
            { name = "naskh", build = function()
                switches.response_font_face = "Noto Naskh Arabic"
                local widget = page(PERSIAN)
                switches.response_font_face = nil
                return widget
            end },
        },
        verify = function(ctx)
            switches.response_font_face = "Noto Naskh Arabic"
            local css = make_viewer(PERSIAN):_buildCSS()
            switches.response_font_face = nil
            ctx.check("the response font registers its files with MuPDF",
                css:find("@font-face", 1, true) ~= nil
                    and css:find("NotoNaskhArabic", 1, true) ~= nil,
                "css carries no registration")
            -- The picker's list API: a wrong binding name here is the crash
            -- the font menu had, so the real call is exercised too.
            local cre = require("document/credocument"):engineInit()
            local faces = cre.getFontFaces()
            ctx.check("the installed font list is readable",
                type(faces) == "table" and #faces > 0,
                "getFontFaces returned " .. tostring(faces and #faces))
            local fp = ctx.shots.naskh
            ctx.check("the Persian text paints in the chosen font",
                fp.ink_ratio > 0.0003, string.format("ink_ratio %.5f", fp.ink_ratio))
        end,
    },
})
