---  model picker — fetch and select models from UI
local json = require("rapidjson")
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
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local koutil = require("util")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Screen = require("device").screen
local logger = require("logger")
local ASUtils = require("assistant_utils")
local Registry = require("assistant_provider_registry")

-- Forward declarations
local showPickerDialog, showManualInput

--- Model currently in effect for the active provider: the runtime override
--- (selected_model_<id>) wins over the provider record, mirroring
--- BaseHandler:SyncOptions.
local function effectiveModel(assistant)
    local querier = assistant.querier
    if not querier then return "" end
    local override = querier.provider_name and assistant.settings
        and assistant.settings:readSetting("selected_model_" .. querier.provider_name)
    if override and override ~= "" then return override end
    return koutil.tableGetValue(querier, "provider_setting", "model") or ""
end

--- Save selected model to settings and apply to current session
local function saveModelSelection(assistant, model_id)
    local provider_name = assistant.querier.provider_name
    assistant.settings:saveSetting("selected_model_" .. provider_name, model_id)
    assistant.updated = true

    assistant.querier.handler:SyncOptions(assistant.querier)
end

--- Reset model override — revert to configuration.lua default
local function resetModelSelection(assistant)
    local provider_name = assistant.querier.provider_name
    assistant.settings:delSetting("selected_model_" .. provider_name)
    assistant.updated = true

    -- Restore model from provider settings
    assistant.querier.handler:SyncOptions(assistant.querier)
end

-- Model picker dialog (extends InputDialog following SettingsDialog pattern)
local ModelPickerDialog = InputDialog:extend{
    title = "",
    assistant = nil,
    models = nil,
    all_models = nil,
    close_callback = nil,
    search_query = "",
    page = 1,
    on_select = nil,  -- optional callback(model_id) to intercept selection (skips saveModelSelection)
    provider_label = nil,  -- optional title prefix; falls back to the active provider's label
    selected_model = nil,  -- staged choice (radio highlight) pending OK confirmation
    reopen_callback = nil,  -- hand the window back to the caller (skipped on long-press)
    test_context = nil,  -- { handler, base_url, api_key } whose models are listed;
                         -- falls back to the active provider when nil
}

function ModelPickerDialog:init()
    -- dynamic calculate lines PER PAGE
    local item_height = Screen:scaleBySize(30) + 2*Size.padding.default -- radiobutton item_height
    local fixed_height = Screen:scaleBySize(135) + 2*Size.margin.default -- title bar, buttons row, etc
    local MODELS_PER_PAGE = math.max(5, math.floor((Screen:getHeight() - fixed_height) / item_height))

    local current_model = effectiveModel(self.assistant)

    -- Credentials the listed models came from. Callers that list a provider
    -- other than the active one (the edit dialog's "Browse Models") pass the
    -- edited dialog's fields; otherwise test the active provider.
    local test_context = self.test_context
    if not test_context then
        local querier = self.assistant.querier
        if querier then
            test_context = {
                handler = querier.handler_name,
                base_url = koutil.tableGetValue(querier, "provider_setting", "base_url"),
                api_key = koutil.tableGetValue(querier, "provider_setting", "api_key"),
            }
        end
    end

    -- The model the Test button acts on: the staged choice wins, otherwise the
    -- model currently in effect. Never empty, so the test is never fired with
    -- a nil model id.
    local function testModelId()
        if self.selected_model and self.selected_model ~= "" then
            return self.selected_model
        end
        if current_model and current_model ~= "" then
            return current_model
        end
        return nil
    end

    local model_count = #self.models
    local total_pages = math.max(1, math.ceil(model_count / MODELS_PER_PAGE))
    if self.page > total_pages then self.page = total_pages end

    -- Title prefix: whose models are listed (falls back to the active provider).
    local provider_label = self.provider_label
    if (not provider_label or provider_label == "") and self.assistant.querier then
        provider_label = self.assistant.querier:getProviderLabel()
    end
    local title_parts = {}
    if provider_label and provider_label ~= "" then
        table.insert(title_parts, provider_label .. " ")
    end
    if self.search_query ~= "" then
        table.insert(title_parts, T(_("Models: %1 (matched)"), model_count))
    else
        table.insert(title_parts, T(_("Models: %1"), model_count))
    end
    if total_pages > 1 then
        table.insert(title_parts, T(_(" - p. %1/%2"), self.page, total_pages))
    end
    self.title = table.concat(title_parts)

    -- Pagination buttons (first row) + action buttons (second row)
    local has_prev = self.page > 1
    local has_next = self.page < total_pages

    -- Final closes refresh whatever the caller owns (close_callback) and,
    -- unless the user is done (long-press), hand the window back to the
    -- caller (reopen_callback). Paging/search close the dialog directly and
    -- must not fire either.
    local function finishClose(reopen)
        UIManager:close(self)
        if self.close_callback then self.close_callback() end
        if reopen and self.reopen_callback then self.reopen_callback() end
    end

    -- Apply the staged selection and close. `reopen` is false for the OK
    -- long-press shortcut: the user is done, so the caller's window is not
    -- handed back, only refreshed. Every applied pick is confirmed with a
    -- notification, tap or long-press alike.
    local function applySelection(reopen)
        local model_id = self.selected_model
        if not model_id then
            finishClose(reopen)
            return
        end
        if self.on_select then
            finishClose(reopen)
            self.on_select(model_id)
        else
            saveModelSelection(self.assistant, model_id)
            finishClose(reopen)
        end
        Notification:notify(T(_("Model: %1"), model_id), Notification.SOURCE_ALWAYS_SHOW)
    end

    self.buttons = {
        {
            {
                text = "◁◁",
                enabled = has_prev,
                callback = function()
                    if has_prev then self:changePage(self.page - 1) end
                end,
                hold_callback =function () -- hold to first page
                    self:changePage(1)
                end
            },
            {
                text = _("Search"),
                callback = function() self:onSearch() end,
            },
            {
                -- @translators Button text: means custom input, keep translation short
                text = _("Custom"),
                callback = function() self:onManualInput() end,
            },
            {
                text = "▷▷",
                enabled = has_next,
                callback = function()
                    if has_next then self:changePage(self.page + 1) end
                end,
                hold_callback = function () -- hold to last page
                    self:changePage(total_pages)
                end,
            },
        },
        {
            {
                id = "close",
                text = _("Cancel"),
                callback = function() finishClose(true) end,
            },
            {
                text = _("Reset"),
                callback = function()
                    self:onReset()
                    finishClose(true)
                end,
            },
            {
                -- Test the staged choice, falling back to the model in effect.
                -- The shared helper owns the online check + Trapper wrap and
                -- shows the dismissable "Testing connection..." message.
                id = "test",
                text = _("Test"),
                enabled_func = function() return testModelId() ~= nil end,
                callback = function()
                    local model_id = testModelId()
                    if not model_id then return end
                    Registry.testConnection(test_context.handler,
                        test_context.base_url, test_context.api_key, model_id)
                end,
            },
            {
                -- OK applies the staged selection (radio highlight); the
                -- choice is not saved until this button is tapped. Holding it
                -- applies and closes without handing the window back.
                id = "ok",
                text = _("OK"),
                callback = function() applySelection(true) end,
                hold_callback = function() applySelection(false) end,
            },
        },
    }

    -- Build radio buttons for current page only
    local start_idx = (self.page - 1) * MODELS_PER_PAGE + 1
    local end_idx = math.min(self.page * MODELS_PER_PAGE, model_count)

    self.radio_buttons = {}
    for i = start_idx, end_idx do
        local m = self.models[i]
        -- Staged selection wins; otherwise highlight the effective model.
        local checked
        if self.selected_model then
            checked = (m.id == self.selected_model)
        else
            checked = (m.id == current_model)
        end
        table.insert(self.radio_buttons, {{
            text = m.id,
            model_id = m.id,
            checked = checked,
        }})
    end

    -- Initialize base InputDialog (creates title_bar, button_table, layout)
    InputDialog.init(self)
    self.title_bar.close_callback = function() finishClose(true) end
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
            -- Stage the choice only; OK applies it, Cancel discards.
            self.selected_model = btn.model_id
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
        self.close_callback, self.search_query, new_page, self.on_select,
        self.provider_label, self.selected_model, self.reopen_callback,
        self.test_context)
end

function ModelPickerDialog:onSearch()
    UIManager:close(self)
    local search_dialog
    search_dialog = InputDialog:new{
        title = _("Search Models"),
        input = self.search_query,
        input_hint = "claude, gemini, free ...",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(search_dialog)
                    showPickerDialog(self.assistant, self.all_models,
                        self.close_callback, self.search_query, self.page,
                        self.on_select, self.provider_label, self.selected_model,
                        self.reopen_callback, self.test_context)
                end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = search_dialog:getInputText()
                    UIManager:close(search_dialog)
                    showPickerDialog(self.assistant, self.all_models,
                        self.close_callback, query, 1,
                        self.on_select, self.provider_label, self.selected_model,
                        self.reopen_callback, self.test_context)
                end,
            },
        }},
    }
    UIManager:show(search_dialog)
end

function ModelPickerDialog:onManualInput()
    UIManager:close(self)
    showManualInput(self.assistant, self.close_callback, self.on_select, self.reopen_callback)
end

function ModelPickerDialog:onReset()
    resetModelSelection(self.assistant)
    local _p = self.assistant.config:getProvider(self.assistant.querier.provider_name)
    local config_model = (_p and _p.model) or "?"
    Notification:notify(T(_("Model reset: %1"), config_model), Notification.SOURCE_ALWAYS_SHOW)
end

function ModelPickerDialog:onCloseWidget()
    InputDialog.onCloseWidget(self)
end

--- Show the model picker dialog with optional search filter and page
--- @param selected_model string|nil staged choice to keep highlighted across
---        paging/search reopens (nil on a fresh entry)
--- @param reopen_callback function|nil hand the window back to the caller on
---        a normal dismissal; skipped on long-press (the user is done)
--- @param test_context table|nil { handler, base_url, api_key } whose models
---        are listed; nil tests the active provider
showPickerDialog = function(assistant, all_models, close_callback, search_query, page, on_select, provider_label, selected_model, reopen_callback, test_context)
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
        showPickerDialog(assistant, all_models, close_callback, "", 1, on_select, provider_label, selected_model, reopen_callback, test_context)
        return
    end

    UIManager:show(ModelPickerDialog:new{
        assistant = assistant,
        models = models,
        all_models = all_models,
        close_callback = close_callback,
        search_query = search_query,
        page = page,
        on_select = on_select,
        provider_label = provider_label,
        selected_model = selected_model,
        reopen_callback = reopen_callback,
        test_context = test_context,
    })
end

--- Show manual model input dialog
showManualInput = function(assistant, close_callback, on_select, reopen_callback)
    local current_model = effectiveModel(assistant)
    local dialog
    dialog = InputDialog:new{
        title = _("Enter Model ID"),
        input = current_model,
        input_hint = _("e.g. google/gemini-3.0-flash-exp:free"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                    if close_callback then close_callback() end
                    if reopen_callback then reopen_callback() end
                end,
            },
            {
                text = _("OK"),
                is_enter_default = true,
                callback = function()
                    local model_id = dialog:getInputText()
                    if model_id and koutil.trim(model_id) ~= "" then
                        model_id = koutil.trim(model_id)
                        if on_select then
                            UIManager:close(dialog)
                            on_select(model_id)
                        else
                            saveModelSelection(assistant, model_id)
                            UIManager:close(dialog)
                            Notification:notify(T(_("Model: %1"), model_id), Notification.SOURCE_ALWAYS_SHOW)
                            if close_callback then close_callback() end
                            if reopen_callback then reopen_callback() end
                        end
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

--- Main entry point: fetch models via querier's handler and show picker
local function showModelPicker(assistant, close_callback, on_select)
    local models, err = assistant.querier.handler:FetchModels()
    if err then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err, })
        return
    end

    if not models or #models == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No models available."),
        })
        return
    end
   
    showPickerDialog(assistant, models, close_callback, "", 1, on_select)
end

--- Build a temporary handler instance from provider fields and fetch the
--- model list through the handler's own FetchModels. Each handler knows its
--- endpoint, auth headers, and post-processing (e.g. Gemini filters by
--- supportedGenerationMethods and strips the "models/" prefix), so the
--- returned list is always picker-ready.
---
--- A fresh instance is used instead of the module-level handler singleton,
--- which may be the currently active provider and must not be mutated.
--- Must be called inside Trapper:wrap — FetchModels runs the request in a
--- dismissable subprocess behind an InfoMessage.
--- @param handler_name string API handler name (e.g. "openai", "gemini")
--- @param base_url string   provider base URL as entered by the user
--- @param api_key string    provider API key
--- @return table|nil model_list @return string|nil err
local function fetchModels(handler_name, base_url, api_key)
    local handler_module = require("api_handlers." .. handler_name)
    local provider_handler = handler_module:new{
        base_url = base_url,
        api_key = api_key,
    }
    provider_handler:normalizeBaseUrl()
    return provider_handler:FetchModels()
end

return {
    showModelPicker = showModelPicker,
    showPickerDialog = showPickerDialog,
    fetchModels = fetchModels,
}
