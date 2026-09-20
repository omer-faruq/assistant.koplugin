-- Markdown CSS debug viewer (uses the project's real Markdown control).
-- Usage: ./test/runui.sh markdown_css
--
-- SAMPLE is shared with the headless display test
-- (test/test_markdown_css.lua) via test/markdown_css_sample.md (plain text,
-- block keeps the generic LLM shapes (h1-h6/lists/tables/code/CJK/footnote)
-- for CSS eyeballing, the tail is the two-round dialog output
-- (Question/Thought/Response divs, reasoning fence, --- separators, Search
-- div with keyword line, suggestion links) mirroring what
-- AssistantDialog:_createResultText emits.
-- This file is dev-only (test/ is excluded from release zips).

-- Add project root to path before requiring wbuilder
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test/wbuilder")
local UIManager = wb.UIManager
local ChatGPTViewer = require("assistant_viewer")
local sample_file = io.open(project_root .. "/test/markdown_css_sample.md", "r")
local SAMPLE = sample_file:read("*a")
sample_file:close()

-- Minimal assistant mock: just enough for ChatGPTViewer:init().
-- Notebook stays disabled (doc_settings set), Add Note skipped (no ui).
local mock_assistant = {
    settings = {
        readSetting = function(dummy, key, def)
            -- On: exercise .suggestion-link styling below.
            if key == "auto_prompt_suggest" then return true end
            -- On: keep the reasoning block so .assistant-label--thought
            -- styling shows (the viewer strips it when this is off).
            if key == "show_reasoning" then return true end
            return def
        end,
    },
    ui = {
        doc_settings = true,
    },
    ui_language_is_rtl = false,
    showProviderDialog = function() end,
}

local viewer = ChatGPTViewer:new{
    title = "Markdown CSS",
    text = SAMPLE,
    assistant = mock_assistant,
    disable_add_note = true,
    add_default_buttons = true,
}

UIManager:show(viewer)
UIManager:run()
