-- Magnifying-glass candidates for the search-keyword marker.
-- Usage: ./test/runui.sh magnifier_probe
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test/wbuilder")
local UIManager = wb.UIManager
local Screen = wb.Screen
local ChatGPTViewer = require("assistant_viewer")

local mock_assistant = {
    settings = { readSetting = function(_, _, def) return def end },
    ui = { doc_settings = true },
    ui_language_is_rtl = false,
    showProviderDialog = function() end,
}

-- Rendered at the viewer's normal body size, then large, since a thin glyph
-- can look present at one size and turn to tofu at another.
local cands = {
    { "\u{2315}", "U+2315 telephone recorder" },
    { "\u{1F50D}", "U+1F50D magnifier (emoji)" },
    { "\u{1F50E}", "U+1F50E magnifier tilted (emoji)" },
    { "\u{2B58}", "U+2B58 circled magnifying glass" },
    { "\u{26B2}", "U+26B2 neuter" },
    { "\u{2317}", "U+2317 viewdata square (current)" },
}
local lines = {}
for _, c in ipairs(cands) do
    lines[#lines + 1] = string.format("%s  %s", c[1], c[2])
    lines[#lines + 1] = string.format("# %s  %s", c[1], c[2])
    lines[#lines + 1] = ""
end

local viewer = ChatGPTViewer:new{
    title = "Magnifier Candidates",
    text = table.concat(lines, "\n\n"),
    assistant = mock_assistant,
    is_show_addnote = false,
    add_default_buttons = true,
}

UIManager:show(viewer)

UIManager:scheduleIn(2, function()
    UIManager:forceRePaint()
    UIManager:scheduleIn(0.5, function()
        local ok = pcall(function()
            return Screen.bb:writeToFile("/tmp/opencode/magnifier_probe.png", "png")
        end)
        print("Screenshot:", ok, "/tmp/opencode/magnifier_probe.png")
        UIManager:quit()
    end)
end)

UIManager:run()
