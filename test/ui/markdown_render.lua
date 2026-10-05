-- test/ui/markdown_render.lua
-- Renders real replies and asserts on the pixels: the shipped renderer
-- (Conversation.Renderer), the shipped viewer transform
-- (ResultViewer:_renderMarkdown / :_buildCSS), the shipped CSS
-- (assistant_css.build) and MuPDF.
--
-- What the headless suite can only check as a string is checked here as
-- geometry: where the bubble sits, whether the Thought block is painted at
-- all, and whether the blocks of a two-round reply stay separate and in order.
--
-- Every threshold below is paired with a perturbation that turns the check
-- red: drop `margin-left: 38%` and the bubble check fails, strip the block
-- backgrounds and the panel checks find nothing, feed the page a second turn
-- and the "one block" count fails.
--
-- Usage: SDL_VIDEODRIVER=dummy ./test/runui.sh ui/markdown_render
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
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local ResultViewer = require("assistant_viewer")
local Conversation = require("assistant_conversation")
local ASUtils = require("assistant_utils")

local W, H = Screen:getWidth(), Screen:getHeight()

-- Geometry of the shipped stylesheet: the bubble is pushed right by
-- margin-left: 38% and shrink-to-fits whatever the margin leaves, so it ends at
-- the right margin. The Thought block and the dict excerpt carry no horizontal
-- margin and span the page.
local RIGHT_EDGE = 0.9
local LEFT_INDENT = 0.30
local FULL_WIDTH = 0.10

-- ── Fakes ──────────────────────────────────────────────────────────────
-- The switches under test live in one table the cases flip, so the same viewer
-- mock drives every scenario.
local switches = {
    minimalist_mode = false,
    show_reasoning = false,
    auto_prompt_suggest = true,
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
    ui_language_is_rtl = false,
    showProviderDialog = function() end,
    assistant_dialog = { runPrompt = function() end },
    querier = { provider_name = "test-provider", is_inited = function() return true end },
}

-- ── Page builder ───────────────────────────────────────────────────────
-- The viewer's own transform decides the HTML and the CSS; the page widget
-- only strips the window chrome, so a band's geometry is the document's.
local function make_viewer(text)
    return ResultViewer:new{
        title = "Markdown render",
        text = text,
        assistant = mock_assistant,
    }
end

local function page(text, mutate_css)
    local viewer = make_viewer(text)
    local css = viewer:_buildCSS()
    if mutate_css then css = mutate_css(css) end
    local widget = ScrollHtmlWidget:new{
        html_body = viewer:_renderMarkdown(),
        css = css,
        default_font_size = Screen:scaleBySize(20),
        width = W,
        height = H,
    }
    return CenterContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = W, h = H }, widget }
end

-- ── Transcript builders, through the shipped renderer ──────────────────

local function msg(role, content)
    return { role = role, content = content }
end

local function render(history, header)
    return Conversation.Renderer.render(history, {
        header = header,
        title = nil,
        settings = mock_assistant.settings,
        default_config = { show_suggestions = false },
    })
end

local ANSWER = "Frodo Baggins carries the Ring to Mordor with Samwise Gamgee beside him."
local REASONING = "The user asks about a classic book, so internal knowledge suffices and no search is needed."

local function push_answer(history, content)
    local answer = msg("assistant", content)
    ASUtils.set_attr(answer, "show_suggestions", false)
    table.insert(history, answer)
end

-- A reply with no user turn in front of it: the answer body alone.
local function answer_only()
    local history = { msg("system", "system prompt") }
    push_answer(history, ANSWER)
    return render(history)
end

local function one_round(answer)
    local history = { msg("system", "system prompt"), msg("user", "What is the One Ring?") }
    push_answer(history, answer or ANSWER)
    return render(history)
end

local function two_rounds(first_answer)
    local history = { msg("system", "system prompt"), msg("user", "What is the One Ring?") }
    push_answer(history, first_answer
        or "The One Ring was forged by Sauron in Mount Doom to rule the other Rings of Power.")
    table.insert(history, msg("user", "Who carries it to Mordor?"))
    push_answer(history, ANSWER)
    return render(history)
end

local function dict_answer()
    local history = { msg("system", "system prompt") }
    local context = msg("user", "PROMPT TEMPLATE THAT MUST NOT LEAK")
    ASUtils.set_attr(context, "is_context", true)
    table.insert(history, context)
    push_answer(history, "The term names a ship.")
    return render(history,
        '<div class="dict-excerpt">... he said <b>word</b> and then >stopped< ...</div>\n\n')
end

-- ── Fingerprint shorthands ─────────────────────────────────────────────

local function boxes(fp)
    return fp.panel_boxes
end

-- The grey boxes that start right of the bubble margin, i.e. the user bubbles.
-- The window's own chrome bands span the full width and are not counted.
local function bubbles(fp)
    local out = {}
    for idx = 1, #fp.panel_boxes do
        local box = fp.panel_boxes[idx]
        if box.x0 >= LEFT_INDENT * W and box.x1 >= RIGHT_EDGE * W then
            out[#out + 1] = box
        end
    end
    return out
end

shot.run({
    -- 1. The answer body lands on the page, at the top, with nothing painted
    --    behind it.
    {
        name = "answer body",
        shots = {
            { name = "answer", build = function() return page(answer_only()) end },
        },
        verify = function(ctx)
            local fp = ctx.shots.answer
            ctx.check("the answer body paints ink", fp.ink_ratio > 0.002,
                string.format("ink_ratio %.5f", fp.ink_ratio))
            ctx.check("the page starts at the top, not pushed off it",
                fp.first_marked_row and fp.first_marked_row < 0.1 * fp.h,
                "first_marked_row " .. tostring(fp.first_marked_row))
            ctx.check("a bare answer paints no block background", #boxes(fp) == 0,
                "panel boxes: " .. #boxes(fp) .. "\n" .. shot.describe(fp))
        end,
    },

    -- 2. The user bubble is a grey box pushed to the right by the CSS margin.
    --    MuPDF has no max-width and no auto margin, so this box only lands
    --    where it does because margin-left: 38% is in the stylesheet.
    {
        name = "user bubble",
        shots = {
            { name = "bubble", build = function() return page(one_round()) end },
            -- Same page, stylesheet with the block backgrounds stripped: the
            -- fingerprint has to tell them apart, or none of the panel checks
            -- below means anything.
            { name = "bubble_unpainted", build = function()
                local text = one_round()
                return page(text, function(css)
                    return (css:gsub("background%-color: #[0-9A-Fa-f]+;?", ""))
                end)
            end },
        },
        verify = function(ctx)
            local fp = ctx.shots.bubble
            local list = boxes(fp)
            ctx.check("the bubble paints exactly one grey block", #list == 1,
                "panel boxes: " .. #list .. "\n" .. shot.describe(fp))
            if #list == 1 then
                local bubble = list[1]
                ctx.check("the bubble starts right of the 38% margin",
                    bubble.x0 >= LEFT_INDENT * W,
                    "bubble x0 " .. bubble.x0 .. " of " .. W)
                ctx.check("the bubble is a box, not a hairline",
                    bubble.width > 0.4 * W and bubble.height > 0.03 * H,
                    "bubble " .. bubble.width .. "x" .. bubble.height)
                ctx.check("the answer is painted below the bubble",
                    fp.last_marked_row and fp.last_marked_row > bubble.y1 + 10,
                    "answer ends at " .. tostring(fp.last_marked_row)
                    .. ", bubble ends at " .. bubble.y1)
            end
            local stripped = ctx.shots.bubble_unpainted
            ctx.check("without the background the same page paints no block",
                #boxes(stripped) == 0,
                "panel boxes: " .. #boxes(stripped) .. "\n" .. shot.describe(stripped))
        end,
    },

    -- 3. The Reasoning Text switch decides whether the Thought block is on the
    --    page at all. Both renders come from the same history and only the
    --    switch differs, so the difference in pixels is the block.
    {
        name = "thought block",
        shots = {
            { name = "thought_on", build = function()
                switches.show_reasoning = true
                return page(one_round("```reasoning\n" .. REASONING .. "\n```\n\n" .. ANSWER))
            end },
            { name = "thought_off", build = function()
                switches.show_reasoning = false
                return page(one_round("```reasoning\n" .. REASONING .. "\n```\n\n" .. ANSWER))
            end },
        },
        verify = function(ctx)
            switches.show_reasoning = false
            local on, off = ctx.shots.thought_on, ctx.shots.thought_off
            local on_boxes, off_boxes = boxes(on), boxes(off)
            ctx.check("Reasoning Text on: bubble plus a Thought block",
                #on_boxes == 2, "panel boxes: " .. #on_boxes .. "\n" .. shot.describe(on))
            if #on_boxes == 2 then
                -- The transcript is a bubble, then the Thought block it belongs
                -- to, then the answer: the first box is the bubble.
                local bubble, thought = on_boxes[1], on_boxes[2]
                ctx.check("the bubble is the right-aligned one",
                    bubble.x0 >= LEFT_INDENT * W,
                    "bubble x0 " .. bubble.x0 .. " of " .. W)
                ctx.check("the Thought block spans the full page width",
                    thought.x0 <= FULL_WIDTH * W and thought.x1 >= RIGHT_EDGE * W,
                    string.format("thought x %d..%d of %d", thought.x0, thought.x1, W))
                ctx.check("the Thought block follows the turn it answers",
                    thought.y0 > bubble.y1,
                    "bubble ends at " .. bubble.y1 .. ", thought starts at " .. thought.y0)
            end
            ctx.check("Reasoning Text off: the Thought block leaves no trace",
                #off_boxes == 1, "panel boxes: " .. #off_boxes .. "\n" .. shot.describe(off))
            ctx.check("dropping the block pulls the rest of the page up",
                off.last_marked_row and on.last_marked_row
                    and off.last_marked_row < on.last_marked_row,
                "off ends at " .. tostring(off.last_marked_row)
                .. ", on ends at " .. tostring(on.last_marked_row))
        end,
    },

    -- 4. Two rounds: two separate blocks, both right-aligned, with the first
    --    answer painted between them. A block that swallows the other shows up
    --    here as one box instead of two.
    {
        name = "two rounds",
        shots = {
            { name = "rounds", build = function() return page(two_rounds()) end },
        },
        verify = function(ctx)
            local fp = ctx.shots.rounds
            local list = boxes(fp)
            ctx.check("both turns paint their own block", #list == 2,
                "panel boxes: " .. #list .. "\n" .. shot.describe(fp))
            if #list == 2 then
                local first, second = list[1], list[2]
                ctx.check("the two blocks are stacked, not merged",
                    second.y0 > first.y1,
                    string.format("first y %d..%d, second y %d..%d",
                        first.y0, first.y1, second.y0, second.y1))
                ctx.check("both bubbles are right-aligned",
                    first.x0 >= LEFT_INDENT * W and second.x0 >= LEFT_INDENT * W,
                    string.format("x0 %d and %d of %d", first.x0, second.x0, W))
                ctx.check("the first answer is painted between the two bubbles",
                    shot.ink_between(fp, first.y1 + 1, second.y0 - 1) > 50,
                    "no ink between y " .. first.y1 .. " and " .. second.y0)
            end
        end,
    },

    -- 5. The dictionary excerpt is a full-width band above the answer, and it
    --    is not styled like a bubble.
    {
        name = "dictionary excerpt",
        shots = {
            { name = "dict", build = function() return page(dict_answer()) end },
        },
        verify = function(ctx)
            local fp = ctx.shots.dict
            local list = boxes(fp)
            ctx.check("the excerpt paints one band", #list == 1,
                "panel boxes: " .. #list .. "\n" .. shot.describe(fp))
            if #list == 1 then
                ctx.check("the excerpt spans the full page width",
                    list[1].x0 <= FULL_WIDTH * W and list[1].x1 >= RIGHT_EDGE * W,
                    string.format("excerpt x %d..%d of %d", list[1].x0, list[1].x1, W))
                ctx.check("the answer is painted below the excerpt",
                    fp.last_marked_row and fp.last_marked_row > list[1].y1 + 5,
                    "answer ends at " .. tostring(fp.last_marked_row)
                    .. ", excerpt ends at " .. list[1].y1)
            end
        end,
    },

    -- 6. A long user turn takes the page: the 38% chat margin would wrap it
    --    into a narrow column, so the long-text class drops it to 6%. The
    --    short turn above is the perturbation: it must keep the 38% margin,
    --    so the two cases bracket the length classes.
    {
        name = "long turn width",
        shots = {
            { name = "long", build = function()
                local history = { msg("system", "system prompt"),
                    msg("user", string.rep("Why does the Ring corrupt its bearer? ", 4)) }
                push_answer(history, ANSWER)
                return page(render(history))
            end },
        },
        verify = function(ctx)
            local fp = ctx.shots.long
            local list = boxes(fp)
            ctx.check("the long turn paints one bubble", #list == 1,
                "panel boxes: " .. #list .. "\n" .. shot.describe(fp))
            if #list == 1 then
                local bubble = list[1]
                ctx.check("a long turn's bubble takes the page",
                    bubble.x0 <= 0.12 * W and bubble.width > 0.7 * W,
                    string.format("bubble x0 %d width %d of %d", bubble.x0, bubble.width, W))
            end
        end,
    },

    -- 7. Show Highlighted Text: the selection rides in its own band above the
    --    question bubble, and the bubble narrows back to the chat shape (its
    --    caption no longer carries the selection). The window still ends with
    --    the answer.
    {
        name = "source block above the turn",
        shots = {
            { name = "source", build = function()
                switches.show_source_text = true
                local history = { msg("system", "system prompt") }
                local question = msg("user", "TEMPLATE MUST NOT LEAK")
                ASUtils.set_attr(question, "prompt_title", "Translate")
                ASUtils.set_attr(question, "highlight_text",
                    "All the world went ashen and the sun darkened, and the moon, they say, was wan and cold")
                table.insert(history, question)
                push_answer(history, ANSWER)
                local widget = page(render(history))
                switches.show_source_text = false
                return widget
            end },
        },
        verify = function(ctx)
            local fp = ctx.shots.source
            local list = boxes(fp)
            ctx.check("the turn paints the source band and the bubble", #list == 2,
                "panel boxes: " .. #list .. "\n" .. shot.describe(fp))
            if #list == 2 then
                local band, bubble = list[1], list[2]
                ctx.check("the source band rides above the question bubble",
                    band.y1 < bubble.y0,
                    string.format("band ends %d, bubble starts %d", band.y1, bubble.y0))
                ctx.check("the caption-only bubble hugs the right edge",
                    bubble.x0 >= 0.6 * W,
                    "bubble x0 " .. bubble.x0 .. " of " .. W)
                ctx.check("the answer is painted below the turn",
                    fp.last_marked_row and fp.last_marked_row > bubble.y1,
                    "answer ends at " .. tostring(fp.last_marked_row))
            end
        end,
    },

    -- 8. The real viewer window paints: title bar, page and both bubbles. A
    --    broken paint hook leaves the framebuffer empty, which no string
    --    assertion can see. The empty reply is the control: same window, same
    --    chrome, no transcript, so the difference is the transcript.
    {
        name = "viewer window",
        shots = {
            { name = "viewer", build = function() return make_viewer(two_rounds()) end },
            { name = "viewer_empty", build = function() return make_viewer(".") end },
        },
        verify = function(ctx)
            local fp, empty = ctx.shots.viewer, ctx.shots.viewer_empty
            ctx.check("the viewer window paints",
                fp.ink_ratio > 0.005 and fp.ink_rows > 0.5 * fp.h,
                string.format("ink %.5f over %d rows", fp.ink_ratio, fp.ink_rows))
            local function page_ink(p)
                return shot.ink_between(p, math.floor(0.15 * p.h), math.floor(0.6 * p.h))
            end
            ctx.check("the page carries the transcript, not just the window chrome",
                page_ink(fp) > 2 * page_ink(empty),
                string.format("transcript %d vs empty window %d", page_ink(fp), page_ink(empty)))
            ctx.check("both bubbles reach the window", #bubbles(fp) == 2,
                "bubble boxes: " .. #bubbles(fp) .. "\n" .. shot.describe(fp))
        end,
    },
})
