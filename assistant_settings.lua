--[[--
This widget displays a setting dialog.
]]

local Trapper = require("ui/trapper")
local koutil = require("util")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton = require("ui/widget/checkbutton")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local TextBoxWidget = require("ui/widget/textboxwidget")
local SpinWidget = require("ui/widget/spinwidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ConfirmBox = require("ui/widget/confirmbox")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Device = require("device")
local Screen = Device.screen
local ffiutil = require("ffi/util")
local meta = require("_meta")
local logger = require("logger")
local koutil = require("util")
local ToolExecutor = require("assistant_tool_executor")
local ExtTools = require("assistant_exttools")
local Updater = require("assistant_updater")
local ASUtils = require("assistant_utils")
local Registry = require("assistant_provider_registry")
local SearchRegistry = require("assistant_search_registry")
local Notebook = require("assistant_notebook")

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
    local chkbtn_is_rtl
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
                        if chkbtn_is_rtl then
                            chkbtn_is_rtl.checked = assistant.ui_language_is_rtl
                            chkbtn_is_rtl:init()
                        end

                        UIManager:setDirty(langsetting, function()
                            return "ui", langsetting.dialog_frame.dimen
                        end)
                    end
                },
                {
                    id = "save",
                    text = _("Save"),
                    callback = function()
                        local fields = langsetting:getFields()
                        for i, key in ipairs({"response_language", "dict_language"}) do
                            if fields[i] == "" then
                                assistant.settings:delSetting(key)
                            else
                                assistant.settings:saveSetting(key, fields[i])
                            end
                        end

                        if chkbtn_is_rtl then
                            local checked = chkbtn_is_rtl.checked
                            if checked ~= (assistant.settings:readSetting("response_is_rtl") or false) then
                                assistant.settings:saveSetting("response_is_rtl", checked)
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

    chkbtn_is_rtl = CheckButton:new{
        text = _("RTL written Language"),
        face = Font:getFace("xx_smallinfofont"),  
        checked = assistant.settings:readSetting("response_is_rtl") or assistant.ui_language_is_rtl,
        parent = langsetting,
    }
    langsetting:addWidget(FrameContainer:new{
        padding = Size.padding.default,  
        margin = Size.margin.small,  
        bordersize = 0,  
        chkbtn_is_rtl
    })

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

local SettingsDialog = InputDialog:extend{
    title = _("Providers and Models"),

    -- inited variables
    assistant = nil, -- reference to the main assistant object
    settings = nil,

    -- widgets
    buttons = nil,
    radio_buttons = nil,
}

function SettingsDialog:init()

    self.title_bar_left_icon = "notice-info"
    self.title_bar_left_icon_tap_callback = function ()
        self.assistant:showAboutDialog()
    end

    -- action buttons
    self.buttons = {{
        {
            id = "close",
            text = _("Close"),
            callback = function() UIManager:close(self) end
        },
        {
            id = "select_model",
            text = _("Browse Models"),
            enabled_func = function ()
                return self.assistant.querier.handler.can_fetch_models
            end,
            callback = function() self:onBrowseModel() end,
            hold_callback = function ()
                UIManager:show(InfoMessage:new{
                    alignment = "center",
                    text = _("Browse available models from the current provider")
                })
            end
        },
        {
            id = "edit_provider",
            text = _("Edit"),
            enabled_func = function()
                local cur = self.assistant.querier.provider_name
                if not cur then return false end
                local ps = self.assistant.config:getProvider(cur)
                return Registry.is_editable(ps)
            end,
            callback = function() self:onEditProvider() end,
        },
        {
            id = "delete_provider",
            text = _("Delete"),
            enabled_func = function()
                local cur = self.assistant.querier.provider_name
                if not cur then return false end
                local ps = self.assistant.config:getProvider(cur)
                return Registry.is_deletable(ps)
            end,
            callback = function() self:onDeleteProvider() end,
        },
    }}

    table.insert(self.buttons[1], 3, {
        id = "add_provider",
        text = _("Add"),
        callback = function()
            UIManager:close(self)
            UIManager:nextTick(function()
                self.assistant:showAddProviderMenu()
            end)
        end,
    })

    -- init radio buttons for selecting AI Model provider
    self.radio_buttons = {} -- init radio buttons table

    local MAX_FOR_SINGLE_COLUMN = 12
    -- 2 columns if more than MAX_FOR_SINGLE_COLUMN providers, otherwise 1 column
    local columns = koutil.tableSize(self.assistant.config:getProviderSettings()) > MAX_FOR_SINGLE_COLUMN and 2 or 1
    local buttonrow = {}
    for key, tab in ffiutil.orderedPairs(self.assistant.config:getProviderSettings()) do
        if self.assistant.querier:is_valid_provider(key, tab) then
            if not (koutil.tableGetValue(tab, "visible") == false) then -- skip `visible = false` providers
                if #buttonrow < columns then
                    local seleted_model = self.settings:readSetting("selected_model_" .. key)
                    local model_name = seleted_model or koutil.tableGetValue(tab, "model")
                    local display_name = koutil.tableGetValue(tab, "display_name") or key
                    local button_text = string.format("%s (%s)", display_name, model_name)
                    table.insert(buttonrow, {
                        text = button_text,
                        provider = key, -- note: this `provider` field belongs to the RadioButton, not our AI Model provider.
                        checked = (key == self.assistant.querier.provider_name),
                    })
                end
                if #buttonrow == columns then
                    table.insert(self.radio_buttons, buttonrow)
                    buttonrow = {}
                end
            end
        end
    end

    if #buttonrow > 0 then -- edge case: if there are remaining buttons in the last row
        table.insert(self.radio_buttons, buttonrow)
        buttonrow = {}
    end

    -- init title and buttons in base class
    InputDialog.init(self)
    --  adds a close button to the top right
    self.title_bar.close_callback = function() UIManager:close(self) end
    self.title_bar:init()
    self.element_width = math.floor(self.width * 0.9)

    self.radio_button_table = RadioButtonTable:new{
        radio_buttons = self.radio_buttons,
        width = self.element_width,
        face = Font:getFace("cfont", 18),
        zero_sep = true,
        sep_width = 0,
        focused = true,
        scroll = false,
        parent = self,
        button_select_callback = function(btn)
            self.settings:saveSetting("provider", btn.provider)
            self.assistant.updated = true
            self.assistant.querier:load_model(btn.provider)
            self:updateSelectModelButton()
        end
    }
    self.layout = {self.layout[#self.layout]} -- keep bottom buttons
    self:mergeLayoutInVertical(self.radio_button_table, #self.layout) -- before bottom buttons

    -- main dialog widget layout table
    self.vgroup = VerticalGroup:new{
        align = "left",
        self.title_bar,         -- -- Title Bar
        CenterContainer:new{    -- -- Provider radio buttons
            dimen = Geom:new{
                w = self.width,
                h = self.radio_button_table:getSize().h,
            },
            self.radio_button_table,
        },
        CenterContainer:new{    -- -- Button at the bottom
            dimen = Geom:new{
                w = self.title_bar:getSize().w,
                h = self.button_table:getSize().h,
            },
            self.button_table,
        }
    }

    self.dialog_frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.vgroup,
    }
    self.movable = MovableContainer:new{
        self.dialog_frame,
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        self.movable,
    }
    self:refocusWidget()
end

function SettingsDialog:updateSelectModelButton()
    local btn = self.button_table:getButtonById("select_model")
    if btn then
        if self.assistant.querier.handler.can_fetch_models then
            btn:enable()
        else
            btn:disable()
        end
        UIManager:setDirty(self, "ui")
    end
end

function SettingsDialog:onBrowseModel()
    -- final check
    if not self.assistant.querier.handler.can_fetch_models then
        return
    end

    ASUtils.runWhenOnlineFast(function()
        Trapper:wrap(function()
            local handler = self.assistant.querier.handler
            local models, err = handler:FetchModels()
            if err == ASUtils.HANDLERCODE.CODE_CANCELLED then
                return  -- user dismissed the InfoMessage; keep settings window
            end
            if err or not models or #models == 0 then
                -- keep the settings window open on failure
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = err or _("No models available."),
                })
                return
            end
            -- success: close settings and open the model picker
            UIManager:close(self)
            local showPickerDialog = require("assistant_model_picker").showPickerDialog
            showPickerDialog(self.assistant, models, self.close_callback, "", 1)
        end)
    end)
end

function SettingsDialog:onDeleteProvider()
    local provider_name = self.assistant.querier.provider_name
    local ps = self.assistant.config:getProvider(provider_name)
    if not Registry.is_deletable(ps) then return end

    local display_name = koutil.tableGetValue(ps, "display_name") or provider_name
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete provider %1?"), display_name),
        ok_text = _("Delete"),
        ok_callback = function()
            local ui_data = self.assistant._ui_provider_data
            Registry.delete(ui_data, provider_name)
            Registry.save(self.settings, ui_data)
            self.assistant.config:deleteProvider(provider_name)

            -- Fallback: reselect a valid provider
            local new_provider = self.assistant.config:getActiveProviderId()
            if new_provider then
                self.assistant.querier:load_model(new_provider)
            end

            -- Close and reopen settings
            UIManager:close(self)
            if self.assistant._settings_dialog then
                UIManager:close(self.assistant._settings_dialog)
                self.assistant._settings_dialog = nil
            end
            UIManager:scheduleIn(0.15, function()
                self.assistant:showSettings()
            end)
        end,
    })
end

function SettingsDialog:onEditProvider()
    local provider_name = self.assistant.querier.provider_name
    local ps = self.assistant.config:getProvider(provider_name)
    if not Registry.is_editable(ps) then return end

    UIManager:close(self)
    UIManager:nextTick(function()
        self.assistant:_showAddProviderDialog(nil, nil, nil, nil, provider_name)
    end)
end

function SettingsDialog:onCloseWidget()
    InputDialog.onCloseWidget(self)
    if self.close_callback then
        self.close_callback()
    end
    self.assistant._settings_dialog = nil
end

SettingsDialog.genWebSearchSubMenuItem = function(assistant, key)
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
                local info = _("Builtin Tools Works ONLY with these models:\n- Gemini-2.5/3\n- OpenAI/gpt-4o-search\n")
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

SettingsDialog.genMenuSettings = function(assistant)
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
                            text = _("Only used by prompts that opt in to book context (by default: Explain, Historical Context, Summarize, Key Points and ELI5). When enabled, the text of the highlighted page and the adjacent pages is sent to the AI as background reference. Requires a text selection and increases token usage.")
                        })
                    end
                },
                {
                    text = _("Use Book Text for X-Ray and Recap"),
                    checked_func = function () return assistant.settings:readSetting("use_book_text_for_analysis", false) end,
                    callback = function()
                        assistant.settings:toggle("use_book_text_for_analysis")
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
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
                    text = _("Show Reasoning Text"),
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
            }
        },
        {
            text = _("Notebook Settings"),
            hold_callback = function ()
                UIManager:show(InfoMessage:new{
                    text = _("The notebook is your conversation log: AI answers and quick notes are appended to it. You can create multiple notebooks to organize your logs.")
                })
            end,
            sub_item_table = {
                {
                    text = _("Auto-save Conversations to Notebook"),
                    checked_func = function () return assistant.settings:readSetting("auto_save_to_notebook", false) end,
                    callback = function()
                        assistant.settings:toggle("auto_save_to_notebook")
                        assistant.updated = true
                    end
                },
                {
                    text = _("Multiple Notebooks"),
                    checked_func = function ()
                        return assistant.settings:readSetting("use_multiple_general_notebooks", false)
                    end,
                    callback = function()
                        assistant.settings:toggle("use_multiple_general_notebooks")
                        assistant.updated = true
                    end,
                    hold_callback = function ()
                        UIManager:show(InfoMessage:new{
                            text = _("Choose which notebook your notes are saved to.")
                        })
                    end
                },
                {
                    text_func = function ()
                        local folder = Notebook.getFolder(assistant, false)
                        if folder then
                            return T(_("Notebooks Folder: %1"), Notebook.getFolderBasename(folder))
                        end
                        return _("Notebooks Folder")
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
                                and T(_("Notebooks folder path:\n%1"), folder)
                                or (folder_err or _("No notebooks folder is set."))
                        })
                    end,
                },
            },
        },
        {
            -- @translators: functional overriding
            text = _("KOReader Tweaks"),
            sub_item_table = {
                {
                    -- @translators: 'Translate' is a built-in function
                    text = _("Use AI Assistant for 'Translate'"),
                    checked_func = function () return assistant.settings:readSetting("ai_translate_override", false) end,
                    callback = function()
                        assistant.settings:toggle("ai_translate_override")
                        assistant.updated = true
                        UIManager:nextTick(function ()
                            assistant:syncTranslateOverride()
                        end)
                    end
                },
                {
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
                        Notification:notify(_("AI Recap will be enabled the next time a long-unread book is opened."), Notification.SOURCE_ALWAYS_SHOW)
                    end
                },
                {
                    text = _("Show Dictionary(AI) in Dictionary Popup"),
                    checked_func = function () return assistant.settings:readSetting("dict_popup_show_dictionary", true) end,
                    callback = function()
                        assistant.settings:toggle("dict_popup_show_dictionary")
                        assistant.updated = true
                    end
                },
                {
                    text = _("Show Wikipedia(AI) in Dictionary Popup"),
                    checked_func = function () return assistant.settings:readSetting("dict_popup_show_wikipedia", true) end,
                    callback = function()
                        assistant.settings:toggle("dict_popup_show_wikipedia")
                        assistant.updated = true
                    end
                },
                {
                    text = _("Show Term X-Ray(AI) in Dictionary Popup"),
                    checked_func = function () return assistant.settings:readSetting("dict_popup_show_term_xray", false) end,
                    callback = function()
                        assistant.settings:toggle("dict_popup_show_term_xray")
                        assistant.updated = true
                    end
                },
                {
                    text = _("Show Custom Prompts in Dictionary Popup"),
                    checked_func = function () return assistant.settings:readSetting("dict_popup_show_custom_prompts", false) end,
                    callback = function()
                        assistant.settings:toggle("dict_popup_show_custom_prompts")
                        assistant.updated = true
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
                local latest_tag = Updater.getSavedLatestVersion(assistant)
                local has_update = latest_tag and latest_tag ~= "" and Updater.isVersionNewer(latest_tag, current_version)
                local desc_text
                if has_update then
                    desc_text = T(_("<b>Github URL:</b>  %1\n<b>Source Repo:</b>  %2\n\n- Current version: %3\n- Latest version: <b>%4</b>\n- Development version: main"),
                        ota_github_base, ota_github_repo, current_version, latest_tag)
                else
                    desc_text = T(_("<b>Github URL:</b>  %1\n<b>Source Repo:</b>  %2\n\n- Current version: %3\n- Development version: main"),
                        ota_github_base, ota_github_repo, current_version)
                end
                version_input = InputDialog:new{
                    title = T("%1 - %2 %3", _("OTA Update"), meta.fullname, meta.version),
                    input = default_version,
                    input_hint = _("branch or tag name"),
                    description = ASUtils.bold_format(desc_text),
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
ASUtils.runWhenOnlineFast(function()
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


return SettingsDialog
