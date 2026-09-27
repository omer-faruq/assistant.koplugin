-- Does MuPDF honor max-width on the user bubble? Tests the documented
-- "not supported" claim empirically, plus the width-based alternatives.
-- Usage: ./test/runui.sh bubble_width
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test/wbuilder")
local UIManager = wb.UIManager
local Screen = wb.Screen
local ChatGPTViewer = require("assistant_viewer")
local ViewerCSS = require("assistant_css")

-- Variants of the bubble rule; everything else is the shipped styling.
local EXPERIMENT = [[

/* A: current shipped rule - margin only, shrink to fit */
.b-a { margin-left: 50%; margin-top: 0.4em; margin-bottom: 0.4em;
    padding: 0.4em 0.6em; background-color: #E4E4E4; border-left: 3px solid #999; }

/* B: max-width, as a browser would do it */
.b-b { max-width: 50%; margin-left: auto; margin-top: 0.4em; margin-bottom: 0.4em;
    padding: 0.4em 0.6em; background-color: #E4E4E4; border-left: 3px solid #999; }

/* C: fixed width, right-aligned by a matching margin */
.b-c { width: 50%; margin-left: 50%; margin-top: 0.4em; margin-bottom: 0.4em;
    padding: 0.4em 0.6em; background-color: #E4E4E4; border-left: 3px solid #999; }

/* D: wider than half - margin sets the left edge, width the span */
.b-d { width: 62%; margin-left: 38%; margin-top: 0.4em; margin-bottom: 0.4em;
    padding: 0.4em 0.6em; background-color: #E4E4E4; border-left: 3px solid #999; }

/* E: no width at all, just a smaller left margin - shrink-to-fit within it */
.b-e { margin-left: 38%; margin-top: 0.4em; margin-bottom: 0.4em;
    padding: 0.4em 0.6em; background-color: #E4E4E4; border-left: 3px solid #999; }

/* F: same, pushed further left */
.b-f { margin-left: 25%; margin-top: 0.4em; margin-bottom: 0.4em;
    padding: 0.4em 0.6em; background-color: #E4E4E4; border-left: 3px solid #999; }
]]

local original_build = ViewerCSS.build
ViewerCSS.build = function(opts)
    return original_build(opts) .. EXPERIMENT
end

local mock_assistant = {
    settings = { readSetting = function(_, _, def) return def end },
    ui = { doc_settings = true },
    ui_language_is_rtl = false,
    showProviderDialog = function() end,
}

local SHORT = "Who carries it to Mordor?"
local LONG = "All the world went ashen and the sun darkened, and the moon, they say, " ..
    "was wan and cold, and the flowers of the field shrivelled and withered away"

local html = {}
for _, v in ipairs({ "e", "f" }) do
    html[#html + 1] = string.format(
        '<p><b>%s</b> short:</p><div class="b-%s"><div class="user-bubble-title">‹ Test › %s</div></div>',
        v:upper(), v, SHORT)
    html[#html + 1] = string.format(
        '<p><b>%s</b> long:</p><div class="b-%s"><div class="user-bubble-title">‹ Test › %s</div></div>',
        v:upper(), v, LONG)
end

local viewer = ChatGPTViewer:new{
    title = "Bubble Width",
    text = table.concat(html, "\n\n"),
    assistant = mock_assistant,
    is_show_addnote = false,
    add_default_buttons = true,
}

UIManager:show(viewer)

UIManager:scheduleIn(2, function()
    UIManager:forceRePaint()
    UIManager:scheduleIn(0.5, function()
        local ok = pcall(function()
            return Screen.bb:writeToFile("/tmp/opencode/bubble_width.png", "png")
        end)
        print("Screenshot:", ok, "/tmp/opencode/bubble_width.png")
        UIManager:quit()
    end)
end)

UIManager:run()
