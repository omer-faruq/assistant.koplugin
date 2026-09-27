-- Final layout check: runs the REAL pipeline (formatSingleMessage -> CSS ->
-- ScrollHtmlWidget) with no monkey-patching, and screenshots the framebuffer.
-- Usage: ./test/runui.sh chat_layout
-- Dev-only: test/ is excluded from release zips.
local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = script_path:match("^(.*)/test/")
if project_root then
    package.path = project_root .. "/?.lua;" .. project_root .. "/api_handlers/?.lua;" .. package.path
end

local wb = require("test/wbuilder")
local UIManager = wb.UIManager
local Screen = wb.Screen
local ChatGPTViewer = require("assistant_viewer")
local TextUtils = require("assistant_text_utils")
local ASUtils = require("assistant_utils")
local T = require("ffi/util").template

local settings = {
    readSetting = function(_, key, def)
        if key == "show_reasoning" then return true end
        if key == "auto_prompt_suggest" then return true end
        return def
    end,
}

local opts = {
    settings = settings,
    default_config = { show_suggestions = true },
}

-- Round 1: a preset prompt (name heads the bubble in angle quotes, no text
-- typed) plus a thought block and an answer. Round 2: a free question.
local preset = { role = "user", content = "TEMPLATE THAT MUST NOT LEAK" }
ASUtils.set_attr(preset, "prompt_title", "Book Info")

local answer1 = {
    role = "assistant",
    content = "## The Ring and Its Nature\n\n"
        .. "The One Ring was forged by Sauron in Mount Doom to rule the other Rings of Power.\n",
}

local typed = { role = "user", content = "TEMPLATE MUST NOT LEAK" }
ASUtils.set_attr(typed, "prompt_title", "Term X-Ray")
ASUtils.set_attr(typed, "user_input", "Who carries it to Mordor?")
ASUtils.set_attr(typed, "highlight_text", "All the world went ashen\nand the sun darkened")

local answer2 = { role = "assistant", content = "Frodo Baggins carries the Ring with Samwise Gamgee." }

-- A paragraph-length selection: previously cut at 72 bytes, now shown whole.
local epic = { role = "user", content = "TEMPLATE MUST NOT LEAK" }
ASUtils.set_attr(epic, "prompt_title", "Translate")
ASUtils.set_attr(epic, "highlight_text",
    "All the world went ashen and the sun darkened, and the moon, they say, was wan and cold")

local answer3 = { role = "assistant", content = "No natural English equivalent survives." }

local parts = {}
-- A book prompt: title, author and reading position now ride inside the
-- bubble, under the caption line, instead of as a block above everything.
local book = { role = "user", content = "TEMPLATE MUST NOT LEAK" }
ASUtils.set_attr(book, "prompt_title", "Book Summary & Recs")
ASUtils.set_attr(book, "bubble_meta",
    '<div class="user-bubble-meta"><p><b>Title</b>: The Lord of the Rings</p>'
    .. '<p><b>Author</b>: J.R.R. Tolkien</p><p><b>Reading progress</b>: 45%</p></div>\n')
parts[#parts + 1] = TextUtils.formatSingleMessage({}, book, {
    settings = settings, default_config = { show_suggestions = true }, msg_idx = 1,
})
parts[#parts + 1] = TextUtils.formatSingleMessage({}, { role = "assistant",
    content = "Frodo inherits the Ring and sets out for Mordor." }, {
    settings = settings, default_config = { show_suggestions = true }, msg_idx = 2,
})
parts[#parts + 1] = "\n---\n\n"

-- A search turn: the keyword line leads with the globe used for web search.
parts[#parts + 1] = "\u{1F310} Frodo Baggins Ring bearer Mordor\n\n"
parts[#parts + 1] = TextUtils.formatSingleMessage({}, { role = "assistant",
    content = "Frodo was a hobbit of the Shire who carried the One Ring to Mordor." }, {
    settings = settings, default_config = { show_suggestions = true }, msg_idx = 3,
})
parts[#parts + 1] = "\n---\n\n"

-- The dict dialog's excerpt header, exactly as createResultText emits it.
parts[#parts + 1] = T('<div class="dict-excerpt">... %1 <b>%2</b> %3 ...</div>\n\n',
    "he said &lt;Turned&gt; and &amp; waited",
    "mount Doom",
    "but the road east wound on")

-- Dict / Term X-Ray: the turn is context, so the renderer skips it entirely and
-- no user bubble is drawn. The excerpt header above carries the word instead.
local dict_ctx = { role = "user", content = "PROMPT TEMPLATE THAT MUST NOT LEAK" }
ASUtils.set_attr(dict_ctx, "is_context", true)
local dict_answer = { role = "assistant", content = "Mount Doom is the volcanic ridge where the Ring was forged." }
local dict_history = { { role = "system", content = "system" }, dict_ctx, dict_answer }
for i = 2, #dict_history do
    local msg = dict_history[i]
    if not ASUtils.get_attr(msg, "is_context") then
        local text = TextUtils.formatSingleMessage(dict_history, msg, {
            settings = settings, default_config = { show_suggestions = false }, msg_idx = i,
        })
        if text ~= "" then parts[#parts + 1] = text end
    end
end
parts[#parts + 1] = "\n---\n\n"

for i, msg in ipairs({ preset, answer1, typed, answer2, epic, answer3 }) do
    local text = TextUtils.formatSingleMessage({}, msg, {
        settings = settings,
        default_config = { show_suggestions = true },
        msg_idx = i,
    })
    if text ~= "" then
        parts[#parts + 1] = text
    end
end
local text = table.concat(parts)
if text:find("TEMPLATE THAT MUST NOT LEAK", 1, true) then
    error("prompt template text leaked into the result")
end

local mock_assistant = {
    settings = settings,
    ui = { doc_settings = true },
    ui_language_is_rtl = false,
    showProviderDialog = function() end,
}

local viewer = ChatGPTViewer:new{
    title = "Chat Layout",
    text = text,
    assistant = mock_assistant,
    is_show_addnote = false,
    add_default_buttons = true,
}

UIManager:show(viewer)

UIManager:scheduleIn(2, function()
    UIManager:forceRePaint()
    UIManager:scheduleIn(0.5, function()
        local ok, err = pcall(function()
            return Screen.bb:writeToFile("/tmp/opencode/chat_layout.png", "png")
        end)
        print("Screenshot:", ok, err or "saved to /tmp/opencode/chat_layout.png")
        UIManager:quit()
    end)
end)

UIManager:run()
