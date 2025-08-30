--[[--
This widget displays a setting dialog.
]]

local FrontendUtil = require("util")
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
local ButtonTable = require("ui/widget/buttontable")
local TextBoxWidget = require("ui/widget/textboxwidget")
local SpinWidget = require("ui/widget/spinwidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Screen = require("device").screen
local ffiutil = require("ffi/util")
local meta = require("_meta")
local logger = require("logger")

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


local function LanguageSetting(dlg)
    local langsetting
    local chkbtn_is_rtl
    langsetting = CopyMultiInputDialog:new{
        description_margin = Size.margin.tiny,
        description_padding = Size.padding.tiny,
        title = _("AI Response Language Setting"),
        fields = {
            {
                description = _("AI Response Language"),
                text = dlg.assistant.settings:readSetting("response_language") or "",
                hint = T(_("Leave blank to use: %1"), dlg.assistant.ui_language),
            },
            {
                description = _("Dictionary Language"),
                text = dlg.assistant.settings:readSetting("dict_language") or "",
                hint = T(_("Leave blank to use: %1"), dlg.assistant.ui_language),
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
                            chkbtn_is_rtl.checked = dlg.assistant.ui_language_is_rtl
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
                                dlg.assistant.settings:delSetting(key)
                            else
                                dlg.assistant.settings:saveSetting(key, fields[i])
                            end
                        end

                        if chkbtn_is_rtl then
                            local checked = chkbtn_is_rtl.checked
                            if checked ~= (dlg.assistant.settings:readSetting("response_is_rtl") or false) then
                                dlg.assistant.settings:saveSetting("response_is_rtl", checked)
                            end
                        end

                        dlg.assistant.updated = true
                        local button = dlg.middle_button_table.button_by_id["ai_language"]
                        button:setText(T(_("AI Language: %1"),
                                        fields[1] ~= "" and fields[1] or dlg.assistant.ui_language), button.width)
                        UIManager:close(langsetting)
                    end
                },
            },
        },

    }

    chkbtn_is_rtl = CheckButton:new{
        text = _("RTL written Language"),
        face = Font:getFace("xx_smallinfofont"),  
        checked = dlg.assistant.settings:readSetting("response_is_rtl") or dlg.assistant.ui_language_is_rtl,
        parent = langsetting,
    }
    langsetting:addWidget(FrameContainer:new{
        padding = Size.padding.default,  
        margin = Size.margin.small,  
        bordersize = 0,  
        chkbtn_is_rtl
    })

    if dlg.assistant.settings:has("dict_language") or
        dlg.assistant.settings:has("response_language") then
        -- show a notice when fields filled
        langsetting:addWidget(FrameContainer:new{  
            padding = Size.padding.default,  
            margin = Size.margin.small,  
            bordersize = 0,  
            TextBoxWidget:new{  
                text = T(_("Leave these fields blank to use the UI language: %1"),  dlg.assistant.ui_language),
                face = Font:getFace("x_smallinfofont"),  
                width = math.floor(langsetting.width * 0.95),  
            }
        })
    end
    UIManager:show(langsetting)
    return langsetting
end

local function FontSizeSetting(dlg)
    local fontsize = dlg.assistant.settings:readSetting("response_font_size") or 20
    local widget = SpinWidget:new{
        title_text = _("Response Font Size"),
        value = fontsize,
        value_min = 12, value_max = 30, default_value = 20,
        keep_shown_on_apply = true,
        callback = function(spin)
            dlg.assistant.settings:saveSetting("response_font_size", spin.value)
            dlg.assistant.updated = true
            local button = dlg.middle_button_table.button_by_id["font_size"]
            button:setText(T(_("Font Size: %1"), spin.value), button.width)
        end,
    }
    UIManager:show(widget)
    return widget
end

local SettingsDialog = InputDialog:extend{
    title = _("AI Assistant Settings"),

    -- inited variables
    assistant = nil, -- reference to the main assistant object
    CONFIGURATION = nil,
    settings = nil,

    -- widgets
    buttons = nil,
    radio_buttons = nil,
}

function SettingsDialog:init()

    self.title_bar_left_icon = "notice-info"
    self.title_bar_left_icon_tap_callback = function ()
        UIManager:show(InfoMessage:new{
            alignment = "center", show_icon = false,
            text = string.format("%s %s\n\n%s", meta.fullname, meta.version, meta.description)
        })
    end

    self.check_button_init_list = {
        {
            text = _("Enable stream response"),
            checked = self.settings:readSetting("use_stream_mode", true),
            callback = function()
                self.settings:toggle("use_stream_mode")
                self.assistant.updated = true
            end
        },
        {
            text = _("Use AI Assistant for 'Translate'"),
            checked = self.settings:readSetting("ai_translate_override", false),
            callback = function()
                self.settings:toggle("ai_translate_override")
                self.assistant.updated = true
                self.assistant:syncTranslateOverride()
            end
        },
        {
            text = _("Show Dictionary(AI) in Dictionary Popup"),
            checked = self.settings:readSetting("dict_popup_show_dictionary", true),
            callback = function()
                self.settings:toggle("dict_popup_show_dictionary")
                self.assistant.updated = true
            end
        },
        {
            text = _("Show Wikipedia(AI) in Dictionary Popup"),
            checked = self.settings:readSetting("dict_popup_show_wikipedia", true),
            callback = function()
                self.settings:toggle("dict_popup_show_wikipedia")
                self.assistant.updated = true
            end
        },
        {
            text = _("Copy entered question to the clipboard"),
            checked = self.settings:readSetting("auto_copy_asked_question", true),
            callback = function()
                self.settings:toggle("auto_copy_asked_question")
                self.assistant.updated = true
            end
        },
        {
            text = _("Enable AI Recap"),
            checked = self.settings:readSetting("enable_recap", false),
            callback = function()
                self.settings:toggle("enable_recap")
                self.assistant.updated = true
                if not self.settings:readSetting("enable_recap") then
                    -- if disable, remove the action from dispatcher
                    require("dispatcher"):removeAction("ai_recap")
                    return
                end
                Notification:notify(_("AI Recap will be enabled the next time a book is opened."), Notification.SOURCE_ALWAYS_SHOW)
            end
        },
        {
            text = _("Auto Export Chat Conversations to File"),
            checked = self.settings:readSetting("auto_export_conversations", false),
            callback = function()
                self.settings:toggle("auto_export_conversations")
                self.assistant.updated = true
            end
        },
    }

    -- action buttons
    self.buttons = {{
        {
            id = "close",
            text = _("Close"),
            callback = function() UIManager:close(self) end
        }
    }}  

    -- init radio buttons for selecting AI Model provider
    self.radio_buttons = {} -- init radio buttons table

    local columns = FrontendUtil.tableSize(self.CONFIGURATION.provider_settings) > 4 and 2 or 1 -- 2 columns if more than 4 providers, otherwise 1 column
    local buttonrow = {}
    for key, tab in ffiutil.orderedPairs(self.CONFIGURATION.provider_settings) do
        if not (FrontendUtil.tableGetValue(tab, "visible") == false) then -- skip `visible = false` providers
            if #buttonrow < columns then
                table.insert(buttonrow, {
                    text = columns == 1 and string.format("%s (%s)", key, FrontendUtil.tableGetValue(tab, "model")) or key,
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
        sep_width = 0,
        focused = true,
        scroll = false,
        parent = self,
        button_select_callback = function(btn)
            self.settings:saveSetting("provider", btn.provider)
            self.assistant.updated = true
            self.assistant.querier:load_model(btn.provider)
        end
    }
    self.layout = {self.layout[#self.layout]} -- keep bottom buttons
    self:mergeLayoutInVertical(self.radio_button_table, #self.layout) -- before bottom buttons

    self.middle_button_table = ButtonTable:new{
        width = self.element_width,
        buttons = {{
            {
                id="ai_language",
                text=T(_("AI Language: %1"), self.assistant.settings:readSetting("response_language") or self.assistant.ui_language),
                font_bold = true,
                font_size = 18,
                callback=function()
                    LanguageSetting(self)
                end
            },
            {
                id="font_size",
                text=T(_("Font Size: %1"), self.assistant.settings:readSetting("response_font_size") or 20),
                font_bold = true,
                font_size = 18,
                callback=function ()
                    FontSizeSetting(self)
                end
            },
        }},
    }
    self:mergeLayoutInVertical(self.middle_button_table, #self.layout)

    self.check_button_table = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            HorizontalSpan:new{ width = Size.padding.tiny },
            TextBoxWidget:new{
                text = _("AI Assistant Features:"),
                face = Font:getFace("xx_smallinfofont"),
                width = self.width - 2 * Size.padding.large,
            }
        }
    }
    for i, btn in ipairs(self.check_button_init_list) do
        local row =  HorizontalGroup:new{
            HorizontalSpan:new{ width = Screen:scaleBySize(15), },
            CheckButton:new{
                text = btn.text,
                checked = btn.checked,
                callback = btn.callback,
                face = Font:getFace("xx_smallinfofont"),
                parent = self,
            }
        }
        table.insert(self.check_button_table, row)
        table.insert(self.layout, #self.layout, {row[2]}) -- add to focus layout
    end

    local vertical_span = VerticalSpan:new{
        width = Size.padding.large,
    }

    local radio_desc = TextBoxWidget:new{
        width = self.width - 2 * Size.padding.large,
        text = _("AI Model provider:"),
        face = Font:getFace("xx_smallinfofont"),
    }

    -- main dialog widget layout table
    self.vgroup = VerticalGroup:new{
        align = "left",
        self.title_bar,         -- -- Title Bar
        CenterContainer:new{    -- -- Description text for provider radio
            dimen = Geom:new{
                w = self.width,
                h = radio_desc:getLineHeight() + Size.padding.tiny
            },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = Size.padding.tiny },
                radio_desc,
            },
        },
        CenterContainer:new{    -- -- Provider radio buttons
            dimen = Geom:new{
                w = self.width,
                h = self.radio_button_table:getSize().h,
            },
            self.radio_button_table,
        },
        CenterContainer:new{    -- -- Seperating line
            dimen = Geom:new{
                w = self.width,
                h = Size.padding.large,
            },
            LineWidget:new{
                background = Blitbuffer.COLOR_DARK_GRAY,
                dimen = Geom:new{
                    w = self.element_width,
                    h = Size.line.medium,
                }
            },
        },
        CenterContainer:new{    -- -- Middle Buttons
            dimen = Geom:new{
                w = self.width,
                h = self.middle_button_table:getSize().h,
            },
            self.middle_button_table,
        },
        CenterContainer:new{    -- -- Seperating line
            dimen = Geom:new{
                w = self.width,
                h = Size.padding.large,
            },
            LineWidget:new{
                background = Blitbuffer.COLOR_DARK_GRAY,
                dimen = Geom:new{
                    w = self.element_width,
                    h = Size.line.medium,
                }
            },
        },
        CenterContainer:new{    -- -- Features Check buttons
            dimen = Geom:new{
                w = self.width,
                h = self.check_button_table:getSize().h,
            },
            self.check_button_table,
        },
        vertical_span,          -- -- Seperating space
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

function SettingsDialog:onCloseWidget()
    InputDialog.onCloseWidget(self)
    self.assistant._settings_dialog = nil
end

return SettingsDialog
