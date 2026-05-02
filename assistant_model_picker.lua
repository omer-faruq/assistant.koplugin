--- OpenRouter model picker — fetch and select models from UI
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TrapWidget = require("ui/widget/trapwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local koutil = require("util")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Screen = require("device").screen

local OPENROUTER_MODELS_URL = "https://openrouter.ai/api/v1/models"

-- Forward declarations
local showPickerDialog, showManualInput

--- Fetch models list from OpenRouter API (runs in dismissable subprocess)
local function fetchOpenRouterModels()
    local infomsg = TrapWidget:new{
        text = _("Fetching models..."),
    }
    UIManager:show(infomsg)

    local success, code, body = Trapper:dismissableRunInSubprocess(function()
        local response_body = {}
        local _, rcode = http.request{
            url = OPENROUTER_MODELS_URL,
            headers = {
                ["Accept"] = "application/json",
            },
            sink = ltn12.sink.table(response_body),
        }
        return rcode, table.concat(response_body)
    end, infomsg)

    UIManager:close(infomsg)

    if not success then
        return nil
    end

    if code ~= 200 then
        return nil, T(_("Failed to fetch models (HTTP %1)."), code or "?")
    end

    local ok, parsed = pcall(json.decode, body)
    if not ok or not parsed or not parsed.data then
        return nil, _("Failed to parse model list.")
    end

    -- Sort newest first
    local models = parsed.data
    table.sort(models, function(a, b)
        return (a.created or 0) > (b.created or 0)
    end)

    return models
end

--- Save selected model to settings and apply to current session
local function saveModelSelection(assistant, model_id)
    local provider_name = assistant.querier.provider_name
    assistant.settings:saveSetting("openrouter_model_" .. provider_name, model_id)
    assistant.querier.provider_settings.model = model_id
    assistant.updated = true
end

--- Reset model override — revert to configuration.lua default
local function resetModelSelection(assistant)
    local provider_name = assistant.querier.provider_name
    assistant.settings:delSetting("openrouter_model_" .. provider_name)
    -- Restore from CONFIGURATION
    local config_model = koutil.tableGetValue(
        assistant.CONFIGURATION, "provider_settings", provider_name, "model")
    assistant.querier.provider_settings.model = config_model
    assistant.updated = true
end

local MODELS_PER_PAGE = 20

-- Model picker dialog (extends InputDialog following SettingsDialog pattern)
local ModelPickerDialog = InputDialog:extend{
    title = "",
    assistant = nil,
    models = nil,
    all_models = nil,
    close_callback = nil,
    search_query = "",
    page = 1,
}

function ModelPickerDialog:init()
    local current_model = koutil.tableGetValue(
        self.assistant, "querier", "provider_settings", "model") or ""

    local model_count = #self.models
    local total_pages = math.max(1, math.ceil(model_count / MODELS_PER_PAGE))
    if self.page > total_pages then self.page = total_pages end

    -- Title with page info
    local title_parts = {}
    if self.search_query ~= "" then
        table.insert(title_parts, T(_("Models: %1 (filtered)"), model_count))
    else
        table.insert(title_parts, T(_("Models: %1"), model_count))
    end
    if total_pages > 1 then
        table.insert(title_parts, T(_(" — p. %1/%2"), self.page, total_pages))
    end
    self.title = table.concat(title_parts)

    -- Pagination buttons (first row) + action buttons (second row)
    local has_prev = self.page > 1
    local has_next = self.page < total_pages

    self.buttons = {
        {
            {
                text = has_prev and _("◂ Prev") or "",
                enabled = has_prev,
                callback = function()
                    if has_prev then self:changePage(self.page - 1) end
                end,
            },
            {
                text = _("Search"),
                callback = function() self:onSearch() end,
            },
            {
                text = has_next and _("Next ▸") or "",
                enabled = has_next,
                callback = function()
                    if has_next then self:changePage(self.page + 1) end
                end,
            },
        },
        {
            {
                text = _("Manual"),
                callback = function() self:onManualInput() end,
            },
            {
                text = _("Reset"),
                callback = function() self:onReset() end,
            },
            {
                id = "close",
                text = _("Cancel"),
                callback = function() UIManager:close(self) end,
            },
        },
    }

    -- Build radio buttons for current page only
    local start_idx = (self.page - 1) * MODELS_PER_PAGE + 1
    local end_idx = math.min(self.page * MODELS_PER_PAGE, model_count)

    self.radio_buttons = {}
    for i = start_idx, end_idx do
        local m = self.models[i]
        table.insert(self.radio_buttons, {{
            text = m.id,
            model_id = m.id,
            checked = (m.id == current_model),
        }})
    end

    -- Initialize base InputDialog (creates title_bar, button_table, layout)
    InputDialog.init(self)
    self.title_bar.close_callback = function() UIManager:close(self) end
    self.title_bar:init()

    self.element_width = math.floor(self.width * 0.9)

    -- Create RadioButtonTable for current page (no scroll needed)
    self.radio_button_table = RadioButtonTable:new{
        radio_buttons = self.radio_buttons,
        width = self.element_width,
        face = Font:getFace("cfont", 16),
        sep_width = 0,
        focused = true,
        parent = self,
        button_select_callback = function(btn)
            saveModelSelection(self.assistant, btn.model_id)
            UIManager:close(self)
            Notification:notify(T(_("Model: %1"), btn.model_id))
            if self.close_callback then self.close_callback() end
        end,
    }

    -- Focus layout: radio buttons + bottom buttons
    self.layout = {self.layout[#self.layout]}
    self:mergeLayoutInVertical(self.radio_button_table, #self.layout)

    -- Description text showing current filter
    local desc_text
    if self.search_query ~= "" then
        desc_text = T(_("Filter: \"%1\""), self.search_query)
    else
        desc_text = _("Select a model:")
    end

    local desc_widget = TextBoxWidget:new{
        width = self.width - 2 * Size.padding.large,
        text = desc_text,
        face = Font:getFace("xx_smallinfofont"),
    }
    local desc_h = desc_widget:getLineHeight() + Size.padding.tiny

    -- Build vertical layout (same pattern as SettingsDialog)
    self.vgroup = VerticalGroup:new{
        align = "left",
        self.title_bar,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = desc_h },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = Size.padding.tiny },
                desc_widget,
            },
        },
        CenterContainer:new{
            dimen = Geom:new{
                w = self.width,
                h = self.radio_button_table:getSize().h,
            },
            self.radio_button_table,
        },
        CenterContainer:new{
            dimen = Geom:new{
                w = self.title_bar:getSize().w,
                h = self.button_table:getSize().h,
            },
            self.button_table,
        },
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

function ModelPickerDialog:changePage(new_page)
    UIManager:close(self)
    showPickerDialog(self.assistant, self.all_models,
        self.close_callback, self.search_query, new_page)
end

function ModelPickerDialog:onSearch()
    UIManager:close(self)
    local search_dialog
    search_dialog = InputDialog:new{
        title = _("Search Models"),
        input = self.search_query,
        input_hint = _("e.g. claude, gemini, llama..."),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(search_dialog)
                    showPickerDialog(self.assistant, self.all_models,
                        self.close_callback, self.search_query, self.page)
                end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = search_dialog:getInputText()
                    UIManager:close(search_dialog)
                    showPickerDialog(self.assistant, self.all_models,
                        self.close_callback, query)
                end,
            },
        }},
    }
    UIManager:show(search_dialog)
end

function ModelPickerDialog:onManualInput()
    UIManager:close(self)
    showManualInput(self.assistant, self.close_callback)
end

function ModelPickerDialog:onReset()
    resetModelSelection(self.assistant)
    UIManager:close(self)
    local config_model = koutil.tableGetValue(
        self.assistant.CONFIGURATION, "provider_settings",
        self.assistant.querier.provider_name, "model") or "?"
    Notification:notify(T(_("Model reset: %1"), config_model))
    if self.close_callback then self.close_callback() end
end

function ModelPickerDialog:onCloseWidget()
    InputDialog.onCloseWidget(self)
end

--- Show the model picker dialog with optional search filter and page
showPickerDialog = function(assistant, all_models, close_callback, search_query, page)
    search_query = search_query or ""
    page = page or 1
    local models = all_models

    -- Apply search filter
    if search_query ~= "" then
        models = {}
        local query_lower = search_query:lower()
        for _, m in ipairs(all_models) do
            local id_match = m.id and m.id:lower():find(query_lower, 1, true)
            local name_match = m.name and m.name:lower():find(query_lower, 1, true)
            if id_match or name_match then
                table.insert(models, m)
            end
        end
    end

    if #models == 0 then
        if search_query == "" then return end
        UIManager:show(InfoMessage:new{
            text = T(_("No models matching \"%1\"."), search_query),
        })
        -- Reopen without filter
        showPickerDialog(assistant, all_models, close_callback, "")
        return
    end

    UIManager:show(ModelPickerDialog:new{
        assistant = assistant,
        models = models,
        all_models = all_models,
        close_callback = close_callback,
        search_query = search_query,
        page = page,
    })
end

--- Show manual model input dialog
showManualInput = function(assistant, close_callback)
    local current_model = koutil.tableGetValue(
        assistant, "querier", "provider_settings", "model") or ""
    local dialog
    dialog = InputDialog:new{
        title = _("Enter Model ID"),
        input = current_model,
        input_hint = _("e.g. google/gemini-3.0-flash-exp:free"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local model_id = dialog:getInputText()
                    if model_id and koutil.trim(model_id) ~= "" then
                        model_id = koutil.trim(model_id)
                        saveModelSelection(assistant, model_id)
                        UIManager:close(dialog)
                        Notification:notify(T(_("Model: %1"), model_id))
                        if close_callback then close_callback() end
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

--- Main entry point: fetch OpenRouter models and show picker
local function showOpenRouterModelPicker(assistant, close_callback)
    local models, err = fetchOpenRouterModels()
    if not models then
        if err then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = err,
            })
        end
        return
    end

    if #models == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No models available."),
        })
        return
    end

    showPickerDialog(assistant, models, close_callback)
end

return showOpenRouterModelPicker
