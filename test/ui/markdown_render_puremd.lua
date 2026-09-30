-- test/ui/markdown_render_puremd.lua
-- The same bubble geometry, rendered through the pure-Lua markdown fallback
-- instead of hoedown.
--
-- It is the fallback that wraps a raw HTML block in <p>, which is exactly the
-- case ResultViewer:_renderMarkdown unwraps. Here the parser is faked for the
-- whole run (test/screenshot.lua restores it afterwards), so the shipped
-- viewer transform is what decides whether the bubble ends up a styled,
-- right-aligned box or a paragraph-indented block.
--
-- Usage: SDL_VIDEODRIVER=dummy ./test/runui.sh ui/markdown_render_puremd
--
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local shot = require("test/screenshot")

-- Installed before the viewer is required: assistant_viewer binds the parser at
-- load time, so a later swap would not reach it.
shot.fake("assistant_mdparser", function()
    local puremd = require("apps/filemanager/lib/md")
    return setmetatable({}, { __call = function(_, text) return puremd(text) end })
end)

local wb = require("test/wbuilder")
local Screen = wb.Screen
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local ResultViewer = require("assistant_viewer")
local MD = require("assistant_mdparser")

local W, H = Screen:getWidth(), Screen:getHeight()
local RIGHT_EDGE = 0.9
local LEFT_INDENT = 0.30

local mock_assistant = {
    settings = { readSetting = function(_, key, def) return def end },
    config = {
        getFeature = function() return nil end,
        getActiveProviderId = function() return "test-provider" end,
    },
    ui = { doc_settings = true },
    ui_language_is_rtl = false,
    showProviderDialog = function() end,
    assistant_dialog = { runPrompt = function() end },
    querier = { provider_name = "test-provider", is_inited = function() return true end },
}

local BUBBLE = '<div class="user-bubble">What is the One Ring, and who carries it all the way to Mordor?</div>\n\n'
local ANSWER = "Frodo Baggins carries the Ring to Mordor with Samwise Gamgee beside him."

local function page(html_body, css)
    local widget = ScrollHtmlWidget:new{
        html_body = html_body,
        css = css,
        default_font_size = Screen:scaleBySize(20),
        width = W,
        height = H,
    }
    return CenterContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = W, h = H }, widget }
end

shot.run({
    {
        name = "pure-Lua parser",
        shots = {
            -- The parser's own output, still wrapped: this is what the viewer
            -- has to clean up.
            { name = "wrapped", build = function()
                return page(MD(BUBBLE .. ANSWER .. "\n\n"), ResultViewer:new{
                    text = "", assistant = mock_assistant }:_buildCSS())
            end },
            -- The same document through the viewer's own transform.
            { name = "unwrapped", build = function()
                local viewer = ResultViewer:new{ text = BUBBLE .. ANSWER .. "\n\n", assistant = mock_assistant }
                return page(viewer:_renderMarkdown(), viewer:_buildCSS())
            end },
        },
        verify = function(ctx)
            local wrapped_html = MD(BUBBLE)
            ctx.check("the pure-Lua parser does wrap the container in a paragraph",
                wrapped_html:find("<p>%s*<div class=\"user%-bubble\"") ~= nil,
                "parser output: " .. wrapped_html:sub(1, 80))
            local fp = ctx.shots.unwrapped
            local list = fp.panel_boxes
            ctx.check("the viewer still paints one bubble block", #list == 1,
                "panel boxes: " .. #list .. "\n" .. shot.describe(fp))
            if #list == 1 then
                ctx.check("the unwrapped bubble is still right-aligned",
                    list[1].x0 >= LEFT_INDENT * W and list[1].x1 >= RIGHT_EDGE * W,
                    string.format("bubble x %d..%d of %d", list[1].x0, list[1].x1, W))
            end
            local wrapped_fp = ctx.shots.wrapped
            ctx.check("the paragraph the parser added changes where the bubble lands",
                #wrapped_fp.panel_boxes == 1
                and (wrapped_fp.panel_boxes[1].x0 ~= list[1].x0
                    or wrapped_fp.panel_boxes[1].y0 ~= list[1].y0),
                string.format("wrapped x %d y %d, unwrapped x %d y %d",
                    wrapped_fp.panel_boxes[1].x0, wrapped_fp.panel_boxes[1].y0,
                    list[1].x0, list[1].y0))
            ctx.check("the unwrapped bubble is the one at the CSS margin",
                math.abs(list[1].x0 - math.floor(0.38 * W)) <= 12,
                "bubble x0 " .. list[1].x0 .. ", 38% of " .. W .. " is " .. math.floor(0.38 * W))
        end,
    },
})
