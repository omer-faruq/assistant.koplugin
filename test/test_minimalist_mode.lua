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
        for name, src in pairs({ dialog = dialog_src, feature = feature_src, dict = dict_src }) do
            assert.matches(src, 'readSetting%("minimalist_mode", false%)',
                name .. " must read the switch when assembling the result")
            assert.matches(src, "minimal = minimal",
                name .. " must hand the switch to the shared formatter")
        end
    end),

    test("querier: reasoning never reaches the UI while the switch is off", function()
        local querier_src = read_source("assistant_querier.lua")
        -- Both answer producers (non-stream + stream) must read the switch...
        assert.equal(select(2, querier_src:gsub(
            "self%.settings:readSetting%(\"show_reasoning\", false%)%)", "")),
            2, "both strip_think_tags call sites must honor Reasoning Text")
        assert.notMatches(querier_src, "strip_think_tags%([^%s]%s*nil, true%)",
            "no producer may force the reasoning fence on")
        assert.notMatches(querier_src, "structured, true%)",
            "the stream answer must not force the fence on either")
        -- ...and so must the streaming display path, or the composing window
        -- would still print reasoning while minimalist mode waits for the answer.
        assert.matches(querier_src,
            "if trunk_callback and self%.settings:readSetting%(\"show_reasoning\", false%) then\n%s*trunk_callback%(reasoning_content",
            "streamed reasoning must be gated before it reaches the composing window")
    end),

    test("viewer: renders the text as produced", function()
        assert.notMatches(viewer_src, "strip_reasoning", "the viewer must not filter the answer")
        assert.notMatches(viewer_src, "strip_think_tags", "the querier already split think tags")
    end),

    test("viewer: close is the only button in minimal mode", function()
        assert.matches(viewer_src,
            'self.minimalist = self.assistant.settings:readSetting%("minimalist_mode", false%)',
            "viewer must read the switch once in init()")
        assert.matches(viewer_src, "if self.minimalist then\n      %-%- Answer text only[^\n]*\n      table.insert%(buttons, { new_close_button%(%) }%)",
            "minimal rows must be a single Close button")
        local nav_pos = viewer_src:find("table.insert(buttons, nav_row)", 1, true)
        local action_pos = viewer_src:find("table.insert(buttons, action_row)", 1, true)
        assert.notNil(nav_pos and action_pos, "both default rows must still be assembled")
        assert.isTrue(nav_pos < action_pos, "navigation row stays above the action row")
        local rows_start = viewer_src:find("local nav_row, action_row", 1, true)
        assert.notNil(rows_start, "rows must be declared outside the minimal branch")
        assert.isTrue(rows_start < nav_pos, "the non-minimal branch must fill the declared rows")
    end),

    test("viewer: page-button feedback is skipped in minimal mode", function()
        assert.matches(viewer_src,
            "if not self.minimalist then\n    local prev_at_top",
            "the scroll feedback must not be built without page buttons")
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
        assert.matches(sub, 'if on then[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*saveSetting%("show_reasoning", false%)',
            "turning it on must clear Reasoning Text")
        assert.matches(sub, 'saveSetting%("auto_prompt_suggest", false%)',
            "turning it on must clear Follow-up Questions")
        assert.equal(select(2, sub:gsub(
            "%) return not assistant.settings:readSetting%(\"minimalist_mode\", false%) end,", "")),
            2, "both sub-switches must be disabled while minimal mode is on")
    end),
}

return helper.runTests("minimalist_mode.lua", tests)
