--[[--
Settings menu builders: pure menu-item generators plus their local helpers.
]]

local Trapper = require("ui/trapper")
local DocUtils = require("utils/doc")
local NetUtils = require("utils/net")
local ASUtils = require("utils/base")
local TextUtils = require("utils/text")
local koutil = require("util")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local InputDialog = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local SpinWidget = require("ui/widget/spinwidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local _ = require("core/gettext")
local T = require("ffi/util").template
local Screen = require("device").screen
local meta = require("_meta")
local logger = require("logger")
local ToolExecutor = require("core/tool_executor")
local ExtTools = require("core/exttools")
local Updater = require("core/updater")
local Registry = require("core/provider_registry")
local SearchRegistry = require("core/search_registry")
local Notebook = require("feature/notebook")
local Prompts = require("core/prompts")
local Event = require("ui/event")
local Device = require("device")
local ProviderDialog = require("dialogs/provider")
local ffiutil = require("ffi/util")

-- Custom Widget: auto fill the empty field
local MultiInputDialog = require("ui/widget/multiinputdialog")
local CopyMultiInputDialog = MultiInputDialog:extend{}
function CopyMultiInputDialog:onSwitchFocus(inputbox)
    MultiInputDialog.onSwitchFocus(self, inputbox)
    local vidx = inputbox.idx == 1 and 2 or 1
    local vval = self.input_fields[vidx]:getText()
    -- copy value from the other field
    if vval ~= "" and inputbox:getText() == "" then
        inputbox:addChars(vval)
    end
end
function CopyMultiInputDialog:init()  -- fix the MultiInputDialog cannot move
    MultiInputDialog.init(self)
    local keyboard_height = self.keyboard_visible and self._input_widget:getKeyboardDimen().h or 0
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = Screen:getHeight() - keyboard_height,
        },
        ignore_if_over = "height",
        MovableContainer:new{  self.dialog_frame,  },
    }
end
function CopyMultiInputDialog:onTap(arg, ges)  -- fix: tap outside to close
    if ges.pos:notIntersectWith(self.dialog_frame.dimen) then
        UIManager:close(self)
        return true
    end
    return false
end


local function LanguageSetting(assistant, close_callback)
    local langsetting
    langsetting = CopyMultiInputDialog:new{
        description_margin = Size.margin.tiny,
        description_padding = Size.padding.tiny,
        title = _("AI Response Language Setting"),
        fields = {
            {
                description = _("AI Response Language"),
                text = assistant.settings:readSetting("response_language") or "",
                hint = T(_("Leave blank to use: %1"), assistant.ui_language),
            },
            {
                description = _("Dictionary Language"),
                text = assistant.settings:readSetting("dict_language") or "",
                hint = T(_("Leave blank to use: %1"), assistant.ui_language),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(langsetting)
                    end
                },
                {
                    text = _("Clear"),
                    callback = function()
                        for i, f in ipairs(langsetting.input_fields) do
                            f:setText("")
                        end

                        UIManager:setDirty(langsetting, function()
                            return "ui", langsetting.dialog_frame.dimen
                        end)
                    end
                },
                {
                    text = _("OK"),
                    callback = function()
                        local fields = langsetting:getFields()
                        for i, key in ipairs({"response_language", "dict_language"}) do
                            if fields[i] == "" then
                                assistant.settings:delSetting(key)
                            else
                                assistant.settings:saveSetting(key, fields[i])
                            end
                        end
                        assistant.updated = true
                        UIManager:close(langsetting)
                        if close_callback then
                            close_callback()
                        end
                    end
                },
            },
        },

    }

    if assistant.settings:has("dict_language") or
        assistant.settings:has("response_language") then
        -- show a notice when fields filled
        langsetting:addWidget(FrameContainer:new{
            padding = Size.padding.default,
            margin = Size.margin.small,
            bordersize = 0,
            TextBoxWidget:new{
                text = T(_("Leave these fields blank to use the UI language: %1"),  assistant.ui_language),
                face = Font:getFace("x_smallinfofont"),
                width = math.floor(langsetting.width * 0.95),
            }
        })
    end
    UIManager:show(langsetting)
    return langsetting
end

local function genWebSearchSubMenuItem(assistant, key)
    return {
        text = ToolExecutor.ToolToText(key),
        radio = true,
        checked_func = function ()
            return assistant.settings:readSetting("use_websearch", "none") == key
        end,
        callback = function ()
            local old_key = assistant.settings:readSetting("use_websearch", "none")
            assistant.settings:saveSetting("use_websearch", key)
            assistant.updated = true
            -- Only rebuild highlight-menu buttons when crossing the None/Non-None
            -- boundary: the 🌐 icon visibility depends solely on whether web
            -- search is enabled at all, not on which specific tool is selected.
            if (old_key == "none") ~= (key == "none") then
                assistant:_rebuildShowOnMainButtons()
            end
        end,
        enabled_func = function ()
            if key == "none" then
                return true
            elseif key == "builtin" then
                return koutil.tableGetValue(assistant, "querier", "handler", "has_builtin_websearch")
            elseif ToolExecutor.IsExtSearch(key) then
                local ps = assistant.config:getProvider(key)
                return (koutil.tableGetValue(ps, "api_key") ~= nil) or
                       (koutil.tableGetValue(ps, "base_url") ~= nil)
            end
            return false --
        end,
        hold_callback = function ()
            if key == "builtin" then
                local info = _("Builtin search uses the provider native search tool:\n- Gemini\n- Anthropic\n- Responses (OpenAI Responses API)\n")
                UIManager:show(InfoMessage:new{ face = Font:getFace("smallinfofont"),
                    text = info
                })
            end
            if ToolExecutor.IsExtSearch(key) then
                Trapper:wrap(function()
                    local API = ExtTools[key]
                    local ok, info = API:AccoutInfo()
                    UIManager:show(InfoMessage:new{ face = Font:getFace("smallinfofont"),
                        text = info
                    })
                    if not ok then
                        logger.warn("info err", info)
                    end
                end)
            end
        end
    }
end

local function genDictionaryOutputMenu(assistant)
    local items = {}
    local function set_preset(preset)
        assistant.settings:saveSetting("dict_output_preset", preset)
        assistant.settings:saveSetting("dict_output_sections", Prompts.presetToMap(preset))
        assistant.updated = true
    end

    -- Which AI entries the dictionary popup offers.
    local popup_items = {}
    for i, popup in ipairs({
        { key = "dict_popup_show_dictionary", text = _("AI Dictionary"), default = true },
        { key = "dict_popup_show_wikipedia", text = _("AI Wikipedia"), default = true },
        -- @translators Settings option. Same "Term X-Ray" feature as the popup button: explains the selected word by scanning every occurrence across the book. "AI" marks it as AI-powered. Translate consistently with "Term X-Ray". Keep it short.
        { key = "dict_popup_show_term_xray", text = _("AI Term X-Ray"), default = false },
        { key = "dict_popup_show_custom_prompts", text = _("Custom Prompts"), default = false },
    }) do
        popup_items[i] = {
            text = popup.text,
            checked_func = function()
                return assistant.settings:readSetting(popup.key, popup.default)
            end,
            callback = function()
                assistant.settings:toggle(popup.key)
                assistant.updated = true
            end,
        }
    end

    table.insert(items, {
        text = _("Dictionary Popup Buttons"),
        sub_item_table = popup_items,
    })

    table.insert(items, {
        -- @translators Settings switch: sends every looked-up word to the Vocabulary Builder as soon as its result appears. Keep it short.
        text = _("Auto Add Word to Vocabulary Builder"),
        separator = true,
        checked_func = function()
            return assistant.settings:readSetting("dict_auto_add_vocab", false)
        end,
        callback = function()
            assistant.settings:toggle("dict_auto_add_vocab")
            assistant.updated = true
        end,
        hold_callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Adds every word you look up in the dictionary to the Vocabulary Builder as soon as the result appears."),
            })
        end,
    })

    table.insert(items, {
        text = _("Concise - reply in short sentences"),
        checked_func = function()
            return assistant.settings:readSetting("dict_concise", false)
        end,
        callback = function()
            assistant.settings:toggle("dict_concise")
            assistant.updated = true
        end,
        hold_callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Keep dictionary answers short: at most one or two sentences per section."),
            })
        end,
    })

    for i, preset in ipairs({
        { id = "standard", text = _("Standard - standard definitions") },
        { id = "full", text = _("Full - full definitions") },
    }) do
        table.insert(items, {
            text = preset.text,
            radio = true,
            checked_func = function()
                return assistant.settings:readSetting("dict_output_preset", "standard") == preset.id
            end,
            callback = function() set_preset(preset.id) end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{ text = _("Preset list of AI Dictionary sections.") })
            end,
        })
    end

    table.insert(items, {
        text = _("Custom"),
        radio = true,
        checked_func = function()
            return assistant.settings:readSetting("dict_output_preset", "standard") == "custom"
        end,
        callback = function()
            assistant.settings:saveSetting("dict_output_preset", "custom")
            assistant.updated = true
        end,
    })

    local section_items = {}
    for i, sec in ipairs(Prompts.dict_sections) do
        section_items[i] = {
            text = sec.header,
            checked_func = function()
                local preset = assistant.settings:readSetting("dict_output_preset", "standard")
                if preset == "custom" then
                    local saved = assistant.settings:readSetting("dict_output_sections") or {}
                    return saved[sec.id] == true
                end
                return Prompts.presetToMap(preset)[sec.id] == true
            end,
            callback = function()
                local preset = assistant.settings:readSetting("dict_output_preset", "standard")
                local current
                if preset == "custom" then
                    current = assistant.settings:readSetting("dict_output_sections") or {}
                else
                    current = Prompts.presetToMap(preset)
                end
                current[sec.id] = not current[sec.id]
                assistant.settings:saveSetting("dict_output_sections", current)
                assistant.settings:saveSetting("dict_output_preset", "custom")
                assistant.updated = true
            end,
        }
    end

    table.insert(items, {
        text = _("Choose Definition Sections"),
        sub_item_table = section_items,
    })

    return items
end

-- Text Direction submenu: how a reply's blocks get their base direction.
-- All three states stay reachable from the UI (Auto returns after any
-- choice), which is why the setting is a string and not a tri-state boolean.
local function genTextDirectionItems(assistant)
    local items = {}
    for i, mode in ipairs(TextUtils.DIRECTION_MODES) do
        items[#items + 1] = {
            text = TextUtils.direction_label(mode),
            radio = true,
            checked_func = function()
                return ASUtils.response_direction(assistant.settings,
                    assistant.ui_language_is_rtl) == mode
            end,
            callback = function()
                assistant.settings:saveSetting("response_direction", mode)
                assistant.updated = true
            end,
        }
    end
    return items
end

-- Response Font submenu: every font installed for KOReader (its fonts/ dir
-- and the system fonts), each row shown in its own face as the reader font
-- menu does. "Default" is the viewer stylesheet's own family stack; a chosen
-- family is registered with MuPDF as @font-face (see dialogs/css.build).
local function genResponseFontItems(assistant)
    local items = {
        {
            text = _("Default"),
            radio = true,
            checked_func = function()
                return assistant.settings:readSetting("response_font_face") == nil
            end,
            callback = function()
                assistant.settings:delSetting("response_font_face")
                assistant.updated = true
            end,
        },
    }
    local cre = require("document/credocument"):engineInit()
    local fonts = cre.getFontFaces()
    table.sort(fonts)
    for i, name in ipairs(fonts) do
        local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(name)
        if not font_filename then
            -- The font may be available only in italic, for example script/cursive fonts
            font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(name, nil, true)
        end
        items[#items + 1] = {
            text = name,
            radio = true,
            checked_func = function()
                return assistant.settings:readSetting("response_font_face") == name
            end,
            callback = function()
                assistant.settings:saveSetting("response_font_face", name)
                assistant.updated = true
            end,
            font_func = function(size)
                if font_filename and font_faceindex then
                    return Font:getFace(font_filename, size, font_faceindex)
                end
            end,
        }
    end
    return items
end

local function genMenuSettings(assistant)
    local sub_item_table = {
        {
            text = _("Context Settings"),
            sub_item_table = {
                {
                    text = _("Add Book Metadata as Context"),
                    checked_func = function() return assistant.settings:readSetting("prepend_book_metadata", true) end,
                    callback = function()
                        assistant.settings:toggle("prepend_book_metadata")
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            -- @translators "ELI5" is the feature name used on the button (short for "Explain Like I'm 5"); translate it the same way as the "ELI5" button.
                            text = _("Prepends book metadata (title, author and current reading position incl. chapter) to prompts that opt in to book context (by default: Explain, Historical Context, Summarize, Key Points and ELI5). Per-prompt behavior can be overridden with use_book_context in the configuration file.")
                        })
                    end
                },
                {
                    text = _("Add Nearby Page Text as Context"),
                    checked_func = function() return assistant.settings:readSetting("include_page_text", false) end,
                    callback = function()
                        assistant.settings:toggle("include_page_text")
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            -- @translators "ELI5" is the feature name used on the button (short for "Explain Like I'm 5"); translate it the same way as the "ELI5" button.
                            text = _("Only used by prompts that opt in to book context (by default: Explain, Historical Context, Summarize, Key Points and ELI5). When enabled, the text of the highlighted page and the adjacent pages is sent to the AI as background reference. Requires a text selection and increases token usage.")
                        })
                    end
                },
                {
                    -- @translators Settings option. "Recap" is a brief spoiler-free summary of what was already read. Keep consistent with "Recap" / "AI Recap" elsewhere.
                    text = _("Use Book Text for X-Ray and Recap"),
                    checked_func = function () return assistant.settings:readSetting("use_book_text_for_analysis", false) end,
                    callback = function()
                        assistant.settings:toggle("use_book_text_for_analysis")
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            -- @translators Explanation for the book-text option. "Recap" is a brief spoiler-free summary of what was already read.
                            text = _("When enabled, the Recap and X-Ray features automatically include the book text up to your current reading position as context. This only affects book-level features, not the highlight-menu prompts, and significantly increases token usage.")
                        })
                    end
                },
            }
        },
        {
            text = _("Response Settings"),
            sub_item_table = {
                {
                    text_func = function ()
                        return _("AI Language: ") ..
                            (assistant.settings:readSetting("response_language") or assistant.ui_language)
                    end,
                    callback = function (touchmenu_instance)
                        LanguageSetting(assistant, function ()
                            touchmenu_instance:updateItems()
                        end)
                    end,
                    keep_menu_open = true,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            text = _("Configure the response language of the AI LLM. Defaults to the KOReader interface language.")
                        })
                    end
                },
                -- Size, direction and font all shape how the reply text
                -- itself reads, so they ride one submenu.
                {
                    text = _("Text Appearance"),
                    sub_item_table = {
                        {
                            text_func = function ()
                                return T(_("Text Size: %1"), assistant.settings:readSetting("response_font_size") or 20)
                            end,
                            callback = function (touchmenu_instance)
                                local widget = SpinWidget:new{
                                    title_text = _("Response Text Font Size"),
                                    value = assistant.settings:readSetting("response_font_size") or 20,
                                    value_min = 12, value_max = 30, default_value = 20,
                                    callback = function(spin)
                                        assistant.settings:saveSetting("response_font_size", spin.value)
                                        assistant.updated = true
                                    end,
                                    close_callback = function ()
                                        touchmenu_instance:updateItems()
                                    end
                                }
                                UIManager:show(widget)
                            end,
                            keep_menu_open = true,
                        },
                        {
                            text_func = function ()
                                return T(_("Text Direction: %1"),
                                    TextUtils.direction_label(ASUtils.response_direction(
                                        assistant.settings, assistant.ui_language_is_rtl)))
                            end,
                            sub_item_table = genTextDirectionItems(assistant),
                            keep_menu_open = true,
                        },
                        {
                            text_func = function ()
                                return T(_("Response Font: %1"),
                                    assistant.settings:readSetting("response_font_face") or _("Default"))
                            end,
                            sub_item_table_func = function ()
                                return genResponseFontItems(assistant)
                            end,
                            keep_menu_open = true,
                        },
                    },
                    separator = true,
                },
                {
                    text = _("Enable Stream Response"),
                    checked_func = function () return assistant.settings:readSetting("use_stream_mode", true) end,
                    callback = function ()
                        assistant.settings:toggle("use_stream_mode")
                        assistant.updated = true
                    end
                },
                {
                    text = _("Stream Text Auto Scroll"),
                    enabled_func = function () return assistant.settings:readSetting("use_stream_mode") end,
                    checked_func = function () return assistant.settings:readSetting("stream_mode_auto_scroll", true) end,
                    callback = function()
                        assistant.settings:toggle("stream_mode_auto_scroll")
                        assistant.updated = true
                    end
                },
                {
                    text = _("Large Streaming Window"),
                    enabled_func = function () return assistant.settings:readSetting("use_stream_mode") end,
                    checked_func = function () return assistant.settings:readSetting("large_stream_dialog", true) end,
                    callback = function()
                        assistant.settings:toggle("large_stream_dialog")
                        assistant.updated = true
                    end,
                    separator = true,
                },
                {
                    -- Master switch of the display group below: it decides the
                    -- reply shape and the two sub-switches, so it leads them.
                    text = _("Minimalist Mode"),
                    checked_func = function () return assistant.settings:readSetting("minimalist_mode", false) end,
                    callback = function ()
                        local on = not assistant.settings:readSetting("minimalist_mode", false)
                        assistant.settings:saveSetting("minimalist_mode", on)
                        if on then
                            -- Reasoning and follow-up questions are part of the
                            -- standard display, so minimal mode takes them over:
                            -- clear both (the menu greys them out) instead of
                            -- leaving stale "on" values behind.
                            assistant.settings:saveSetting("show_reasoning", false)
                            assistant.settings:saveSetting("auto_prompt_suggest", false)
                        end
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            text = _("Shows the answer alone: no User/Assistant titles, no first button row, no reasoning and no follow-up questions. Keeps only the actions on the answer itself (Annotate, Vocabulary Builder) next to Close. Turns Reasoning Text and Follow-up Questions off while active.")
                        })
                    end
                },
                {
                    text = _("Show Reasoning Text"),
                    enabled_func = function () return not assistant.settings:readSetting("minimalist_mode", false) end,
                    checked_func = function () return assistant.settings:readSetting("show_reasoning", false) end,
                    callback = function ()
                        assistant.settings:toggle("show_reasoning")
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            text = _("Show deeply thought process (reasoning) from the AI response if exists.")
                        })
                    end
                },
                {
                    text = _("Show Follow-up Questions"),
                    enabled_func = function () return not assistant.settings:readSetting("minimalist_mode", false) end,
                    checked_func = function () return assistant.settings:readSetting("auto_prompt_suggest", false) end,
                    callback = function()
                        assistant.settings:toggle("auto_prompt_suggest")
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            text = _("Show follow up questions related to the response content.")
                        })
                    end
                },
                {
                    text = _("Show Highlighted Text at Top"),
                    enabled_func = function () return not assistant.settings:readSetting("minimalist_mode", false) end,
                    checked_func = function () return assistant.settings:readSetting("show_source_text", false) end,
                    callback = function()
                        assistant.settings:toggle("show_source_text")
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            text = _("Shows the text a prompt was pointed at as its own block at the top of the turn, above the question, so the original can be compared with the answer. The question bubble then stops repeating it.")
                        })
                    end
                },
            }
        },
        {
            text = _("Dictionary Settings"),
            sub_item_table_func = function()
                return genDictionaryOutputMenu(assistant)
            end,
        },
        {
            text = _("AI Notes Settings"),
            hold_callback = function ()
                UIManager:show(InfoMessage:new{
                    text = _("AI Notes is your conversation log: AI answers and quick notes are appended to it. You can create multiple AI notes to organize your logs.")
                })
            end,
            sub_item_table = {
                {
                    text = _("Auto-save Conversations to AI Notes"),
                    checked_func = function () return assistant.settings:readSetting("auto_save_to_notebook", false) end,
                    callback = function()
                        assistant.settings:toggle("auto_save_to_notebook")
                        assistant.updated = true
                    end
                },
                {
                    text = _("Multiple AI Notes"),
                    checked_func = function ()
                        return assistant.settings:readSetting("use_multiple_general_notebooks", false)
                    end,
                    callback = function()
                        assistant.settings:toggle("use_multiple_general_notebooks")
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            text = _("Choose which AI note your notes are saved to.")
                        })
                    end
                },
                {
                    text_func = function ()
                        local folder = Notebook.getFolder(assistant, false)
                        if folder then
                            return T(_("AI Notes Folder: %1"), Notebook.getFolderBasename(folder))
                        end
                        return _("AI Notes Folder")
                    end,
                    callback = function (touchmenu_instance)
                        Notebook.showFolderPicker(assistant, {
                            on_select = function ()
                                touchmenu_instance:updateItems()
                            end,
                        })
                    end,
                    keep_menu_open = true,
                    hold_callback = function ()
                        local folder, folder_err = Notebook.getFolder(assistant, false)
                        UIManager:show(InfoMessage:new{
                            text = folder
                                and T(_("AI Notes folder path:\n%1"), folder)
                                or (folder_err or _("No AI Notes folder is set."))
                        })
                    end,
                },
            },
        },
        {
            text = _("Other Settings"),
            sub_item_table = {
                {
                    -- @translators: 'Translate' is a built-in function
                    text = _("Use AI Assistant for 'Translate'"),
                    checked_func = function () return assistant.settings:readSetting("ai_translate_override", false) end,
                    callback = function()
                        assistant.settings:toggle("ai_translate_override")
                        assistant.updated = true
                        UIManager:nextTick(function ()
                            require("core/hooks").syncTranslateOverride(assistant)
                        end)
                    end
                },
                {
                    text = _("Smart Dictionary Lookup for 'Translate'"),
                    checked_func = function () return assistant.settings:readSetting("ai_smart_dictionary", false) end,
                    callback = function()
                        local key = "ai_smart_dictionary"
                        assistant.settings:saveSetting(key, not assistant.settings:readSetting(key))
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            text = _([[Route short selections to the AI Dictionary instead of the Translator.

- Counts as short: up to 5 words; for CJK text, which has no word
  separators, up to 8 characters.
- Short selections open the AI Dictionary; longer selections are
  translated as usual.]])
                        })
                    end
                },
                {
                    -- @translators Settings option. "Recap" is a brief spoiler-free summary offered when reopening a long-unread book. Keep consistent with "Recap" / "AI Recap" elsewhere.
                    text = _("Auto-recap on Opening Long-unread Books"),
                    checked_func = function () return assistant.settings:readSetting("enable_auto_recap", false) end,
                    callback = function()
                        assistant.settings:toggle("enable_auto_recap")
                        assistant.updated = true
                        if not assistant.settings:readSetting("enable_auto_recap") then
                            -- if disable, remove the action from dispatcher
                            require("dispatcher"):removeAction("ai_recap")
                            return
                        end
                        -- @translators Confirmation notice. Same "Recap" feature: a brief spoiler-free summary of what was already read.
                        Notification:notify(_("AI Recap will be enabled the next time a long-unread book is opened."), Notification.SOURCE_ALWAYS_SHOW)
                    end
                },
                {
                    text = _("Reset Assistant Settings"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _([[Reset all assistant.koplugin settings?

This restores the plugin to its factory defaults. Providers, API keys and
search tool credentials added via the Settings UI will be removed.
File configuration.lua will be preserved.]]),
                            ok_text = _("Reset"),
                            ok_callback = function()
                                assistant.settings:reset({})
                                assistant.settings:flush()
                                UIManager:askForRestart()
                            end
                        })
                    end
                },
            }
        },
        {
            text = _("OTA Update"),
            callback = function(touchmenu_instance)
                local ota_github_base = assistant.config:getFeature("ota_github_base", "https://github.com")
                local ota_github_repo = assistant.config:getFeature("ota_github_repo", "omer-faruq/assistant.koplugin")
                local version_input
                local default_version = Updater.getDefaultOtaInput(assistant) or "main"
                local current_version = tostring(meta.version)
                -- Match the tag display logic: GitHub tags carry a v-prefix, so show
                -- the current version the same way (see Updater.getDefaultOtaInput).
                local current_version_display = "v" .. (current_version:match("^v?(.*)$") or current_version)
                local latest_tag = Updater.getSavedLatestVersion(assistant)
                local has_update = latest_tag and latest_tag ~= "" and Updater.isVersionNewer(latest_tag, current_version)
                local desc_text
                if has_update then
                    desc_text = T(_("<b>Github URL:</b>  %1\n<b>Source Repo:</b>  %2\n\n- Current version: %3\n- Latest version: <b>%4</b>\n- Development branch: main"),
                        ota_github_base, ota_github_repo, current_version_display, latest_tag)
                else
                    desc_text = T(_("<b>Github URL:</b>  %1\n<b>Source Repo:</b>  %2\n\n- Current version: %3\n- Development branch: main"),
                        ota_github_base, ota_github_repo, current_version_display)
                end
                version_input = InputDialog:new{
                    title = T("%1 - %2 %3", _("OTA Update"), meta.fullname, current_version_display),
                    input = default_version,
                    input_hint = _("branch or tag name"),
                    description = TextUtils.bold_format(desc_text),
                    buttons = {
                        -- The cancellation button should be kept on the left
                        -- and the button executing the action on the right.
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(version_input)
                                end,
                            },
                            {
                                text = _("Update"),
                                callback = function()
                                    NetUtils.runWhenOnlineFast(function()
                                        local version = version_input:getInputText()
                                        if version == "" then version = "main" end
                                        UIManager:close(version_input)
                                        touchmenu_instance:closeMenu()
                                        Updater.otaUpgrade(assistant, version)
                                    end)
                                end,
                            },
                        },
                    },
                }
                UIManager:show(version_input)
            end,
            keep_menu_open = true,
        },
    }

    table.insert(sub_item_table, 1, Registry.getAddProviderMenuItem(assistant))
    table.insert(sub_item_table, 2, SearchRegistry.getAddWebSearchMenuItem(assistant))

    return sub_item_table
end

local function BookLevelCustomPrompts(assistant)
  local sub_item_table = {}

  -- Read book_level_prompts from configuration
  local book_level_prompts = assistant.config:getFeature("book_level_prompts") or {}

  for key, prompt_config in ffiutil.orderedPairs(book_level_prompts) do
    if prompt_config.visible == true and prompt_config.type == "feature" then
      local button = {
        text = Prompts.getDisplayText(prompt_config.text or key,
          koutil.tableGetValue(prompt_config, "use_websearch") or false,
          Prompts.isWebSearchEnabled(assistant.settings)),
        callback = function()
          if not assistant:isConfigured() then return end
          NetUtils.runWhenOnlineFast(function()
            local book = require("feature/book_actions").getDocumentInfo(assistant.ui)
            local showFeatureDialog = require("dialogs/feature")
            Trapper:wrap(function()
              showFeatureDialog(assistant, prompt_config, book.title, book.authors, book.percent_finished)
            end)
          end)
        end,
        hold_callback = function()
          UIManager:show(InfoMessage:new{
            text = prompt_config.description or _("This is a custom prompt")
          })
        end,
      }
      table.insert(sub_item_table, button)
    end
  end

  if #sub_item_table == 0 then
    local button = {
      text = _("No valid custom prompt found"),
      enabled = false,
    }
    table.insert(sub_item_table, button)
    local button2 = {
      text = _("For details, visit the 'Configuration' wiki page on github."),
      enabled = false,
    }
    table.insert(sub_item_table, button2)
  end
  return sub_item_table
end

local function addToMainMenu(assistant, menu_items)
  local common_items_table = {
              {
                text = _("Ask a Question"),
                callback = function ()
                  assistant:onAskAIQuestion()
                end,
                hold_callback = function ()
                  UIManager:show(InfoMessage:new{
                    text = _("Enter a question to ask the AI.")
                  })
                end
              },
              {
                text = _("Take Quick Notes"),
                callback = function ()
                  assistant:onAskAIQuickNote()
                end,
                hold_callback = function ()
                  UIManager:show(InfoMessage:new{
                    text = _("Take quick notes that will be saved to your AI Notes.")
                  })
                end,
              },
              {
                text_func = function ()
                  if not assistant.ui.doc_settings and Notebook.isEnabled(assistant) then
                    return T(
                      _("AI Notes: %1"),
                      Notebook.getActiveDisplayName(assistant, 24)
                    )
                  end
                  return _("AI Notes (AI Conversation Log)")
                end,
                callback = function ()
                  local is_general_mode = not assistant.ui.doc_settings
                  local multi_enabled = Notebook.isEnabled(assistant)

                  local function showNotebookFileDialog(notebookfile, include_switch, include_edit)
                    local other_buttons = {}
                    local notebook_dialog

                    if include_switch then
                      table.insert(other_buttons, {
                        text = _("Switch"),
                        callback = function ()
                          Notebook.showPicker(assistant, {
                            on_select = function ()
                              if notebook_dialog then
                                UIManager:close(notebook_dialog)
                              end
                            end,
                          })
                        end
                      })
                    end

                    table.insert(other_buttons, {
                      text = _("Delete"),
                      callback = function ()
                        UIManager:show(ConfirmBox:new{
                          text = T(_("Delete file?\n%1\nThis operation is not reversible."), notebookfile),
                          ok_text = _("Delete"),
                          ok_callback = function ()
                            local ok, err = koutil.removeFile(notebookfile)
                            if not ok then
                              UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
                              return
                            end
                            if notebook_dialog then
                              UIManager:close(notebook_dialog)
                            end
                          end
                        })
                      end
                    })

                    if include_edit then
                      table.insert(other_buttons, {
                        text = _("Edit"),
                        callback = function ()
                          UIManager:broadcastEvent(Event:new("ShowNotebookFile"))
                        end
                      })
                    end

                    notebook_dialog = ConfirmBox:new{
                      icon = "appbar.pageview",
                      face = Font:getFace("smallinfofont"),
                      text = TextUtils.bold_format(
                          T(_("<b>AI Notes file:</b>\n\n%1"), notebookfile)
                      ),
                      ok_text = _("View"),
                      ok_callback = function()
                        if not koutil.pathExists(notebookfile) then
                          UIManager:show(InfoMessage:new{
                            text = T(_("File does not exist.\n\n%1"), notebookfile)
                          })
                          return
                        end
                        Notebook.openNotebookFile(assistant, notebookfile)
                      end,
                      other_buttons = { other_buttons },
                    }
                    UIManager:show(notebook_dialog)
                  end

                  if is_general_mode and multi_enabled then
                    Notebook.showPicker(assistant, {
                      title = _("AI Notes"),
                      on_select = function(notebook)
                        if notebook and notebook.path then
                          showNotebookFileDialog(notebook.path, false, false)
                        end
                      end,
                    })
                    return
                  end

                  local notebookfile
                  if is_general_mode then
                    notebookfile = Notebook.getGeneralNotebookFilePath(assistant)
                  else
                    local ok, resolved = pcall(Notebook.getBookModeNotebookPath, assistant)
                    if ok and type(resolved) == "string" and resolved ~= "" then
                      notebookfile = resolved
                    else
                      notebookfile = assistant.ui.bookinfo:getNotebookFile(assistant.ui.doc_settings)
                    end
                  end
                  showNotebookFileDialog(
                    notebookfile,
                    is_general_mode and multi_enabled,
                    not is_general_mode
                  )
                end,
                separator = true,
              },
              {
                text_func = function ()
                  if not assistant.querier or not assistant.querier.handler then
                    return T(_("Provider %1 NOT CONFIGURED"), "▸")
                  end
                  local provider = assistant.querier.provider_setting
                      and assistant.querier.provider_setting.display_name
                      or assistant.querier.provider_name
                  local effective = assistant.querier.getEffectiveModel
                      and assistant.querier:getEffectiveModel() or ""
                  local model = effective ~= "" and effective
                      or assistant.querier.handler.model or "?"
                  return T(_("Provider %1 %2(%3)"), "▸", provider, model)
                end,
                keep_menu_open = true,
                callback = function (touchmenu_instance)
                  assistant._menu_instance = touchmenu_instance
                  assistant:showProviderDialog(function ()
                    touchmenu_instance:updateItems()
                  end)
                end,
              },
              {
                  text_func = function ()
                    local key = assistant.settings:readSetting("use_websearch", "none")
                    local text = ToolExecutor.ToolToText(key)
                      return T(_("Web Search %1 %2"), "▸", text)
                  end,
                  hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                          text = _("Improves response accuracy with real-time web results. \nNote: Higher token usage and additional API charges apply.")
                      })
                  end,
                  sub_item_table = {},
              },
              {
                text = _("Settings"),
                sub_item_table_func = function ()
                  return genMenuSettings(assistant)
                end,
                hold_callback = function ()
                  assistant:showAboutDialog()
                end
              }
            }

  for _, n in ipairs(ToolExecutor.SEARCH_API_NAMES) do
    table.insert(common_items_table[5].sub_item_table,
      genWebSearchSubMenuItem(assistant, n))
  end

  local book_level_items = {
              {
                text = _("Book Insights"),
                sub_item_table = {
                  {
                    text_func = function()
                      return Prompts.getDisplayText(_("Book Summary & Recs"),
                        koutil.tableGetValue(Prompts.assistant_prompts, "book_info", "use_websearch") or false,
                        Prompts.isWebSearchEnabled(assistant.settings))
                    end,
                    callback = function ()
                      assistant:onAskAIBookInfo()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Summary of the book, author biography, historical context, and a list of similar book recommendations with descriptions.")
                      })
                    end
                  },
                  {
                    text_func = function()
                      return Prompts.getDisplayText(_("AI X-Ray"),
                        koutil.tableGetValue(Prompts.assistant_prompts, "xray", "use_websearch") or false,
                        Prompts.isWebSearchEnabled(assistant.settings))
                    end,
                    callback = function ()
                      assistant:onAskAIXRay()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("\"X-Ray\" summary for a book, structured into specific sections like Characters, Locations, Themes, Terms & Concepts, Timeline, and Re-immersion.")
                      })
                    end
                  },
                  {
                    text_func = function()
                      return Prompts.getDisplayText(_("AI Recaps"),
                        koutil.tableGetValue(Prompts.assistant_prompts, "recap", "use_websearch") or false,
                        Prompts.isWebSearchEnabled(assistant.settings))
                    end,
                    callback = function ()
                      assistant:onAskAIRecap()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("A very brief, spoiler-free summary of the book up to current reading progress.")
                      })
                    end,
                  },
                  {
                    text_func = function()
                      local identify_prompt_config = koutil.tableGetValue(Prompts, "builtin_prompts", "identify_book") or {}
                      local identify_ws_flag = koutil.tableGetValue(identify_prompt_config, "use_websearch") and true or false
                      return Prompts.getDisplayText(_("Identify This Book"), identify_ws_flag,
                        Prompts.isWebSearchEnabled(assistant.settings))
                    end,
                    callback = function ()
                      assistant:onAskAIIdentifyBook()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Infer the open book's title and author from its opening text and save them as custom metadata.")
                      })
                    end,
                  },
                  {
                    text = _("Highlight & Note Analysis"),
                    callback = function ()
                      assistant:onAskAIAnnotations()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Analysis of your highlights, notes, and AI Notes content from the book.")
                      })
                    end,
                  },
                  {
                    text_func = function()
                      return Prompts.getDisplayText(_("Summary Using Highlights & Notes"),
                        koutil.tableGetValue(Prompts.assistant_prompts, "summary_using_annotations", "use_websearch") or false,
                        Prompts.isWebSearchEnabled(assistant.settings))
                    end,
                    callback = function ()
                      assistant:onAskSummaryUsingAnnotations()
                    end,
                    hold_callback = function ()
                      UIManager:show(InfoMessage:new{
                        text = _("Summary of the book using your highlights and notes.")
                      })
                    end,
                  },
                }
              },
            }

  if assistant.config:getFeature("book_level_prompts") then
    table.insert(book_level_items, {
              text = _("Custom Prompts"),
              sub_item_table_func = function ()
                return BookLevelCustomPrompts(assistant)
              end,
              hold_callback = function ()
                UIManager:show(InfoMessage:new{
                  text = _("Your own prompts defined in the configuration file")
                })
              end,
              separator = true,
            })
  else
    book_level_items[1].separator = true
  end

    local reader_items_table = {}
    table.move(common_items_table, 1, #common_items_table, 1, reader_items_table)
    for i = #book_level_items,1,-1 do
      table.insert(reader_items_table, 2, book_level_items[i])
    end

    if assistant.ui.document then
        common_items_table[1].separator = false
        menu_items.ai_assistant = {
            text = _("AI Assistant"),
            sorting_hint = "tools",
            hold_callback = function ()
              assistant:_help_dialog()
            end,
            sub_item_table = reader_items_table
          }
    else
        common_items_table[1].separator = true
        menu_items.ai_assistant = {
            text = _("AI Assistant"),
            sorting_hint = "tools",
            hold_callback = function ()
              assistant:_help_dialog()
            end,
            sub_item_table = common_items_table
        }
    end
end

local function showProviderDialog(assistant, close_callback)
  if not assistant.config or not next(assistant.config:getProviderSettings()) then
    UIManager:show(InfoMessage:new{
      text = T(_("Add providers from the main menu:\n%1 -> AI Assistant -> Settings -> Provider API"), "⚙")
    })
    return
  end
  if not assistant:isConfigured() then return end

  if assistant._provider_dialog then
    UIManager:show(assistant._provider_dialog)
    return
  end

  assistant._provider_close_callback = close_callback or assistant._provider_close_callback

  local settingDlg = ProviderDialog:new{
      assistant = assistant,
      settings = assistant.settings,
      close_callback = assistant._provider_close_callback,
  }

  assistant._provider_dialog = settingDlg
  UIManager:show(settingDlg)
end

local function showHelpDialog(assistant)
    local info_text = string.format("%s %s  ", assistant.meta.fullname, assistant.meta.version) .. T(_([[Usage Tips

Select:
Highlight text (or a word) in the book, then press [AI assistant] in the poped up menu.

Long Press:
- On a Prompt Button: Add to the highlight menu.
- On a highlight menu button to remove it.
- On the Close button to go back to the book in 1 step.

Very-Long Press (over 3 seconds):
On a single word in the book to show the highlight menu (instead of the dictionary).

Multi-Swipe (e.g., %1, %2, %3):
On the result dialog to close (as the Close button is far to reach).
]]), "⮠", "⮡", "↺")
    UIManager:show(ConfirmBox:new{
        icon = "info",
        text = info_text,
        face = Font:getFace("xx_smallinfofont"),
        other_buttons = {{
          {
            text = _("Version Info"),
            callback = function()
              assistant:showAboutDialog()
            end,
          },
        }},
        ok_text = _("Purge Settings"),
        ok_callback = function()
          UIManager:show(ConfirmBox:new{
            text = _([[Are you sure to purge the assistant plugin settings?
This resets the assistant plugin to the status the first time you installed it.

configuration.lua is safe, only the settings are purged.]]),
            ok_text = _("Purge"),
            ok_callback = function()
              assistant.settings:reset({})
              assistant.settings:flush()
              UIManager:askForRestart()
            end
          })
        end
    })
end

local function showAboutDialog(assistant)
  local md_renderer = "Pure MD"
  local ok, parser = pcall(require, "dialogs/mdparser")
  if ok and parser and parser._is_hoedown then
    md_renderer = "libhoedown"
  end

  local Version = require("version")

  UIManager:show(InfoMessage:new{
      show_icon = false,
      text = TextUtils.bold_format(
        T("<b>%1 %2</b>\n――――――――――――――――\n<b>%3:</b> %4\n<b>%5:</b> %6\n<b>%7:</b> %8\n<b>%9:</b> %10/%11\n<b>%12:</b> %13",
          assistant.meta.fullname, assistant.meta.version,
          _("Markdown Engine"), md_renderer,
          _("KOReader"), Version:getShortVersion(),
          _("Device"), Device.model or "?",
          _("Platform"), jit.os, jit.arch,
          _("Runtime"), jit.version
        )
      ),
  })
end


return {
    genWebSearchSubMenuItem = genWebSearchSubMenuItem,
    genDictionaryOutputMenu = genDictionaryOutputMenu,
    genMenuSettings = genMenuSettings,
    addToMainMenu = addToMainMenu,
    showProviderDialog = showProviderDialog,
    showHelpDialog = showHelpDialog,
    showAboutDialog = showAboutDialog,
}
