-- UI check: which buttons each result-viewer shape actually gets.
-- Usage: ./test/runui.sh minimal_buttons
--
-- Builds two real ChatGPTViewer instances through the KOReader widget stack
-- (wbuilder) and prints the resulting button rows: the standard shape and
-- minimalist mode. The dict-shaped viewer is simulated by passing
-- extra_buttons + is_show_addnote = false, i.e. the dictionary viewer's
-- configuration (Vocabulary Builder, no Annotate).
--
-- Dev-only (test/ is excluded from release zips).
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test/wbuilder")
local UIManager = wb.UIManager
local ChatGPTViewer = require("assistant_viewer")

local TEXT = "The ring is a corrupting artifact."

local function make_assistant(minimalist, auto_save)
    return {
        settings = {
            readSetting = function(dummy, key, def)
                if key == "minimalist_mode" then return minimalist end
                if key == "auto_save_to_notebook" then return auto_save end
                return def
            end,
        },
        ui = { doc_settings = true },
        ui_language_is_rtl = false,
        showProviderDialog = function() end,
    }
end

local function ui_context()
    -- Annotate needs a highlight context; a bare table is enough for the
    -- button to be built (its callback is not tapped here).
    return {
        doc_settings = true,
        highlight = { selected_text = "a passage" },
    }
end

local function report(label, opts)
    local viewer = ChatGPTViewer:new(opts)
    UIManager:show(viewer)
    local names = {}
    for _, row in ipairs(viewer.button_table.buttons) do
        local row_names = {}
        for _, btn in ipairs(row) do
            row_names[#row_names + 1] = btn.text or btn.id
        end
        names[#names + 1] = "[" .. table.concat(row_names, " | ") .. "]"
    end
    print(string.format("%-40s %d row(s): %s", label, #viewer.button_table.buttons,
        table.concat(names, " ")))
    UIManager:close(viewer)
end

report("standard (highlight, submit, 1 extra)", {
    assistant = make_assistant(false, false),
    ui = ui_context(),
    text = TEXT,
    onSubmit = function() end,
    extra_buttons = { { text = "Vocabulary Builder" } },
})

report("standard (no ui, auto-save on)", {
    assistant = make_assistant(false, true),
    text = TEXT,
    onSubmit = function() end,
})

report("MINIMAL (highlight, submit, 1 extra)", {
    assistant = make_assistant(true, false),
    ui = ui_context(),
    text = TEXT,
    onSubmit = function() end,
    extra_buttons = { { text = "Vocabulary Builder" } },
})

report("MINIMAL (dict shape: no ui, 1 extra)", {
    assistant = make_assistant(true, false),
    text = TEXT,
    is_show_addnote = false,
    extra_buttons = { { text = "Vocabulary Builder" } },
})

UIManager:quit()
