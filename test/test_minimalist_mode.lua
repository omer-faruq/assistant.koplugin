-- test_minimalist_mode.lua
-- Guards the Response Settings "Minimalist Mode" switch:
--   * the reply is assembled answer-only (a separate emitter shape, not a
--     filter over the labelled one): no Question/Thought/Response/Search
--     carrier, no prompt name, and nothing to cut because the querier already
--     drops reasoning and the follow-up switch keeps suggestions out
--   * the standard shape is untouched when the switch is off
--   * the result window keeps a single Close button (no navigation row, no
--     Ask/Annotate/Save/actions, no page-button scroll feedback)
--   * turning the switch on clears the two subordinate display switches, and
--     the menu keeps them greyed out while it is on
-- Headless-safe: the pure formatter is exercised directly; the widget-heavy
-- viewer/dialog sources are checked by source scan (same split as the other
-- markdown tests).
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local TextUtils = require("assistant_text_utils")

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local viewer_src = read_source("assistant_viewer.lua")
local menu_src = read_source("assistant_settings_menu.lua")
local dialog_src = read_source("assistant_dialog.lua")
local feature_src = read_source("assistant_featuredialog.lua")
local dict_src = read_source("assistant_dictdialog.lua")

local function make_msg(role, content)
    return { role = role, content = content }
end

-- Settings stub: follow-ups on (so the labelled shape would render them).
local function make_settings(suggest_on)
    return {
        readSetting = function(dummy, key, def)
            if key == "auto_prompt_suggest" then return suggest_on end
            return def
        end,
    }
end

local function fmt(message, opts)
    return TextUtils.formatSingleMessage({}, message, opts)
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("minimal: prompt turn shows the answer only", function()
        local user = make_msg("user", "TEMPLATE TEXT THAT MUST NOT LEAK")
        ASUtils.set_attr(user, "prompt_title", "Explain")
        local answer = make_msg("assistant", "Gandalf is a Maia.")
        local out = fmt(user, { minimal = true }) .. fmt(answer, { minimal = true })
        assert.equal(out, "Gandalf is a Maia.\n\n", "only the answer may be emitted")
        assert.notMatches(out, "assistant-label", "no carrier may survive")
        assert.notMatches(out, "Explain", "the prompt name is a title and must go")
        assert.notMatches(out, "TEMPLATE TEXT", "the prompt template must not leak")
    end),

    test("minimal: typed question survives without its label", function()
        local user = make_msg("user", "TEMPLATE")
        ASUtils.set_attr(user, "prompt_title", "Translate")
        ASUtils.set_attr(user, "user_input", "hello world")
        local out = fmt(user, { minimal = true })
        assert.equal(out, "hello world\n\n", "only the typed text may be emitted")
        assert.notMatches(out, "➤", "the question marker is chrome")
    end),

    test("minimal: free question keeps its text, book blocks compacted", function()
        local user = make_msg("user", "Why this?[BOOK TEXT BEGIN]lots of text[BOOK TEXT END]")
        local out = fmt(user, { minimal = true })
        assert.equal(out, "Why this?[BOOK TEXT]\n\n", "book text must collapse to the placeholder")
        assert.notMatches(out, "☺", "no Question label")
    end),

    test("minimal: answer is emitted as produced, nothing filtered", function()
        -- With Reasoning Text and Follow-up Questions off, the querier already
        -- hands over the bare answer, so the template only adds block spacing.
        local produced = TextUtils.strip_think_tags(
            "<think>thinking hard</think>\n\nThe answer.", nil, false)
        local out = fmt(make_msg("assistant", produced), { minimal = true })
        assert.equal(out, "The answer.\n\n", "the answer must pass through unchanged")
    end),

    test("minimal: search turn keeps the keyword line, loses the label", function()
        local search = make_msg("assistant", "raw")
        ASUtils.set_attr(search, "search_keywords", "⌗ Frodo Baggins\n\n")
        local out = fmt(search, { minimal = true })
        assert.equal(out, string.format("%s\n\n", "⌗ Frodo Baggins\n\n"),
            "keyword line must survive as content")
        assert.notMatches(out, "assistant%-label", "no Search carrier may survive")
    end),

    test("minimal: a fence from before the mode was switched on is cut", function()
        -- Answer-only is the mode's contract, so a leftover fence must not
        -- reach the page even if the turn was produced with reasoning on.
        local answer = make_msg("assistant", "```reasoning\nthinking hard\n```\n\nThe answer.")
        local out = fmt(answer, { minimal = true })
        assert.equal(out, "The answer.\n\n", "only the answer body may be emitted")
    end),

    test("minimal: answer block ends so the next turn starts a new block", function()
        -- Without the trailing blank line a list item and the following
        -- question merge into one line once the labels are gone.
        local answer = make_msg("assistant", "- first point\n- second point")
        local question = make_msg("user", "And who forged it?")
        local out = fmt(answer, { minimal = true }) .. fmt(question, { minimal = true })
        assert.equal(out, "- first point\n- second point\n\nAnd who forged it?\n\n",
            "blocks must stay separated")
    end),

    test("standard shape still renders the carriers", function()
        local user = make_msg("user", "Why this?")
        local answer = make_msg("assistant", "Because.")
        local out = fmt(user, { settings = make_settings(false) })
            .. fmt(answer, { settings = make_settings(false) })
        assert.matches(out, 'assistant%-label">☺ Question</div>', "Question div required")
        assert.matches(out, 'assistant%-label">✦ Response</div>', "Response div required")
    end),

    test("dialogs pass the switch into the shared formatter", function()
        -- The minimal switch is now read once in Conversation.Renderer;
        -- the dialogs no longer read it individually.
        local conv_src = read_source("assistant_conversation.lua")
        assert.matches(conv_src, 'readSetting%("minimalist_mode", false%)',
            "renderer must read the switch when assembling the result")
        assert.matches(conv_src, "minimal = minimal",
            "renderer must hand the switch to the shared formatter")
        -- Dialogs must NOT read the switch directly anymore.
        assert.notMatches(dialog_src, 'readSetting%("minimalist_mode", false%)',
            "dialog must not read the switch directly")
        assert.notMatches(feature_src, 'readSetting%("minimalist_mode", false%)',
            "feature must not read the switch directly")
        assert.notMatches(dict_src, 'readSetting%("minimalist_mode", false%)',
            "dict must not read the switch directly")
    end),

    test("querier: reasoning never reaches the UI while the switch is off", function()
        local querier_src = read_source("assistant_querier.lua")
        -- The non-stream answer reads the switch; the streaming paths share one
        -- per-stream snapshot instead of reading the settings per chunk.
        assert.equal(select(2, querier_src:gsub(
            "self%.settings:readSetting%(\"show_reasoning\", false%)%)", "")),
            1, "only the non-stream answer may read the switch directly")
        assert.matches(querier_src,
            "self%.show_reasoning = self%.settings:readSetting%(\"show_reasoning\", false%)",
            "the stream must snapshot the switch once")
        assert.notMatches(querier_src, "strip_think_tags%([^%s]%s*nil, true%)",
            "no producer may force the reasoning fence on")
        assert.notMatches(querier_src, "structured, true%)",
            "the stream answer must not force the fence on either")
        -- Streamed reasoning is display-only, so it must be gated before it
        -- reaches the composing window.
        assert.matches(querier_src, "if trunk_callback and self%.show_reasoning then",
            "streamed reasoning must follow the snapshot")
        assert.matches(querier_src, "trunk_callback%(reasoning_content, reasoning_content_buffer%)",
            "the reasoning push must stay where the gate can see it")
    end),

    test("viewer: renders the text as produced", function()
        assert.matches(viewer_src, "local html_body, err = MD%(self%.text%)",
            "the viewer must render the produced text as-is")
        assert.notMatches(viewer_src, "strip_reasoning",
            "the removed render-time reasoning filter must not come back")
    end),

    test("viewer: minimal mode drops the nav row and the chrome actions only", function()
        assert.matches(viewer_src,
            'self.minimalist = self.assistant.settings:readSetting%("minimalist_mode", false%)',
            "viewer must read the switch once in init()")
        -- Only the navigation row is conditional: the action row is assembled
        -- once and filtered, so Annotate / caller extra_buttons survive.
        assert.matches(viewer_src, "local nav_row\n  if not self%.minimalist then\n    nav_row = {",
            "the navigation row must not exist in minimal mode")
        assert.matches(viewer_src, "if nav_row then\n      table%.insert%(buttons, nav_row%)\n    end",
            "the navigation row must be inserted conditionally")
        local nav_pos = viewer_src:find("table.insert(buttons, nav_row)", 1, true)
        local action_pos = viewer_src:find("table.insert(buttons, action_row)", 1, true)
        assert.notNil(nav_pos and action_pos, "both rows must be inserted")
        assert.isTrue(nav_pos < action_pos, "navigation row stays above the action row")
        -- The two chrome actions are the only ones filtered out.
        assert.matches(viewer_src, "local show_ask = not self%.minimalist and self%.onSubmit ~= nil",
            "Ask Another Question must follow the mode")
        assert.matches(viewer_src, "local show_annotate = self%.ui and self%.is_show_addnote",
            "Annotate must not be filtered by the mode")
        assert.matches(viewer_src, "local show_save = not self%.minimalist",
            "Save must follow the mode")
        assert.matches(viewer_src, "if show_annotate then\n    table%.insert%(action_row, createAddNoteButton%(self%)%)",
            "Annotate must reach the action row in both shapes")
        local extra_pos = viewer_src:find("table.insert(action_row, extra[i])", 1, true)
        local close_pos = viewer_src:find("table.insert(action_row, new_close_button())", 1, true)
        assert.notNil(extra_pos and close_pos, "extra buttons and Close must be inserted")
        assert.isTrue(extra_pos < close_pos, "caller extra buttons stay right before Close")
    end),

    test("viewer: page-button feedback is skipped in minimal mode", function()
        assert.matches(viewer_src,
            "if not self.minimalist then\n    local prev_at_top",
            "the scroll feedback must not be built without page buttons")
    end),

    test("viewer: a display switch re-assembles the text, not just re-renders", function()
        -- The reply is shaped when the dialogs build it, so flipping Reasoning
        -- or Follow-up must rebuild it; re-rendering the stored string would keep
        -- the parts the switch just hid.
        local refresh_text = viewer_src:find("function ChatGPTViewer:_refreshText", 1, true)
        assert.notNil(refresh_text, "_refreshText must exist")
        local refresh_end = viewer_src:find("\nend", refresh_text, true)
        assert.notNil(refresh_end, "_refreshText must be a closed function")
        local refresh_body = viewer_src:sub(refresh_text, refresh_end)
        assert.matches(refresh_body, "self%.text = self%.rebuild_text%(self%)",
            "_refreshText must re-assemble the reply")
        assert.matches(refresh_body, "self:_refreshScrollWidget%(%)",
            "_refreshText must repaint through the scroll widget rebuild")
        local menu_start = viewer_src:find("function ChatGPTViewer:onShowMenu", 1, true)
        local menu = viewer_src:sub(menu_start)
        assert.equal(select(2, menu:gsub("self:_refreshText%(%)", "")),
            2, "both display switches must rebuild the text")
    end),

    test("dialogs hand the viewer a re-assembly entry point", function()
        for name, src in pairs({ dialog = dialog_src, feature = feature_src, dict = dict_src }) do
            assert.matches(src, "rebuild_text = function",
                name .. " must let the viewer re-assemble its result")
        end
    end),

    test("viewer: reasoning and follow-up switches are greyed out", function()
        -- NOTE: this LuaJIT's string.find returns start *and* end, so never
        -- nest it inside another call (s:sub(s:find(..)) would pass the end
        -- index as the second argument of sub).
        local menu_start = viewer_src:find("function ChatGPTViewer:onShowMenu", 1, true)
        assert.notNil(menu_start, "onShowMenu must exist")
        local menu = viewer_src:sub(menu_start)
        assert.equal(select(2, menu:gsub("return not self.minimalist", "")),
            2, "both display switches must follow the mode")
    end),

    test("menu: the switch is off by default and takes over its sub-switches", function()
        local start = menu_src:find('text = _("Response Settings")', 1, true)
        assert.notNil(start, "Response Settings must exist")
        local stop = menu_src:find('text = _("Dictionary Settings")', 1, true)
        assert.notNil(stop, "Dictionary Settings must follow Response Settings")
        local sub = menu_src:sub(start, stop)
        assert.matches(sub, 'text = _%("Minimalist Mode"%)', "the switch must live in Response Settings")
        assert.matches(sub, 'readSetting%("minimalist_mode", false%)',
            "the switch must default to off")
        assert.matches(sub, 'saveSetting%("minimalist_mode", on%)', "the switch must be saved")
        -- The two clears belong to the enable branch: anchor on their order, not
        -- on how many lines the comment inside the branch takes.
        local save_on = sub:find('saveSetting("minimalist_mode", on)', 1, true)
        local guard = sub:find("if on then", save_on, true)
        local clear_reasoning = sub:find('saveSetting("show_reasoning", false)', guard, true)
        local clear_followup = sub:find('saveSetting("auto_prompt_suggest", false)', guard, true)
        assert.notNil(guard and clear_reasoning and clear_followup,
            "turning it on must clear Reasoning Text and Follow-up Questions")
        assert.equal(select(2, sub:gsub(
            "%) return not assistant.settings:readSetting%(\"minimalist_mode\", false%) end,", "")),
            2, "both sub-switches must be disabled while minimal mode is on")
    end),
}

return helper.runTests("minimalist_mode.lua", tests)
