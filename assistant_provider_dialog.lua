--[[--
Provider selection dialog ("Providers and Models").
]]

local Trapper = require("ui/trapper")
local koutil = require("util")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local InputDialog = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("assistant_gettext")
local Screen = require("device").screen
local ffiutil = require("ffi/util")
local ASUtils = require("assistant_utils")
local Registry = require("assistant_provider_registry")

local ProviderDialog = InputDialog:extend{
    title = _("Providers and Models"),

    -- inited variables
    assistant = nil, -- reference to the main assistant object
    settings = nil,

    -- widgets
    buttons = nil,
    radio_buttons = nil,
}

function ProviderDialog:init()

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
            id = "edit_parameters",
            text = _("Reasoning Option"),
            enabled_func = function()
                local cur = self.assistant.querier.provider_name
                if not cur then return false end
                local ps = self.assistant.config:getProvider(cur)
                return Registry.hasReasoningOptions(cur, ps)
            end,
            callback = function()
                local cur = self.assistant.querier.provider_name
                if not cur then return end
                Registry.showParametersDialog(self.assistant, cur)
            end,
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
            -- OK only closes the dialog (provider selection is already
            -- saved on radio-button select); kept on the right for UI
            -- consistency (close left, action right).
            id = "ok",
            text = _("OK"),
            callback = function() UIManager:close(self) end,
        },
    }}

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
            self:updateReasoningButton()
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

function ProviderDialog:updateSelectModelButton()
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

function ProviderDialog:updateReasoningButton()
    local btn = self.button_table:getButtonById("edit_parameters")
    if btn then
        local cur = self.assistant.querier.provider_name
        local enabled = false
        if cur then
            local ps = self.assistant.config:getProvider(cur)
            enabled = Registry.hasReasoningOptions(cur, ps)
        end
        if enabled then
            btn:enable()
        else
            btn:disable()
        end
        UIManager:setDirty(self, "ui")
    end
end

function ProviderDialog:onBrowseModel()
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
            -- success: close settings and open the model picker. The menu
            -- refresh rides along on every close (so the main menu label
            -- updates even on long-press); the picker hands the window back
            -- to Provider Settings on a normal dismissal only.
            local menu_refresh = self.close_callback
            UIManager:close(self)
            local showPickerDialog = require("assistant_model_picker").showPickerDialog
            showPickerDialog(self.assistant, models, menu_refresh, "", 1, nil, nil, nil, function()
                UIManager:nextTick(function()
                    self.assistant:showProviderDialog(menu_refresh)
                end)
            end)
        end)
    end)
end

function ProviderDialog:onEditProvider()
    local provider_name = self.assistant.querier.provider_name
    local ps = self.assistant.config:getProvider(provider_name)
    if not Registry.is_editable(ps) then return end

    UIManager:close(self)
    UIManager:nextTick(function()
        self.assistant:_showAddProviderDialog(nil, nil, nil, nil, provider_name)
    end)
end

function ProviderDialog:onCloseWidget()
    InputDialog.onCloseWidget(self)
    if self.close_callback then
        self.close_callback()
    end
    self.assistant._provider_dialog = nil
end


return ProviderDialog
