local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local koutil = require("util")
local ChatGPTViewer = require("assistant_viewer")
local assistant_prompts = require("assistant_prompts").assistant_prompts

local function showFeatureDialog(assistant, feature_type, title, author, progress_percent, message_history)
    local CONFIGURATION = assistant.CONFIGURATION
    local Querier = assistant.querier
    local ui = assistant.ui

    -- Check if Querier is initialized
    local ok, err = Querier:load_model(assistant:getModelProvider())
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    local formatted_progress_percent = string.format("%.2f", progress_percent * 100)
    
    -- Feature type configurations for easy extension
    local feature_configurations = {
        recap = {
            title = _("Recap"),
            loading_message = _("Loading Recap..."),
            config_key = "recap_config",
            prompts_key = "recap"
        },
        xray = {
            title = _("X‑Ray"),
            loading_message = _("Loading X-Ray..."),
            config_key = "xray_config",
            prompts_key = "xray"
        },
        book_info = {
            title = _("Book Information"),
            loading_message = _("Loading Book Information..."),
            config_key = "book_info_config",
            prompts_key = "book_info"
        }
    }
    
    -- Get feature configuration
    local feature_config = feature_configurations[feature_type]
    if not feature_config then
        UIManager:show(InfoMessage:new{ 
            icon = "notice-warning", 
            text = string.format(_("Unknown feature type: %s"), feature_type) 
        })
        return
    end
    
    local feature_title = feature_config.title
    local loading_message = feature_config.loading_message
    local config_key = feature_config.config_key
    local prompts_key = feature_config.prompts_key
    
    -- Get feature CONFIGURATION with fallbacks
    local file_config = koutil.tableGetValue(CONFIGURATION, "features", config_key) or {}
    local feature_prompts = assistant_prompts and assistant_prompts[prompts_key] or nil
    local language = assistant.settings:readSetting("response_language") or assistant.ui_language
    
    -- Prompts for feature (from config or prompts.lua)
    local system_prompt = koutil.tableGetValue(file_config, "system_prompt")
        or (feature_prompts and feature_prompts.system_prompt)

    local user_prompt_template = koutil.tableGetValue(file_config, "user_prompt")
        or (feature_prompts and feature_prompts.user_prompt)

    local message_history = message_history or {
        {
            role = "system",
            content = system_prompt,
        },
    }
    
    -- Format the user prompt with variables
    local user_content = user_prompt_template:gsub("{(%w+)}", {
      title = title,
      author = author,
      progress = formatted_progress_percent,
      language = language
    })
    
    local context_message = {
        role = "user",
        content = user_content
    }
    table.insert(message_history, context_message)

    local function createResultText(answer)
      local result_text = 
        TextBoxWidget.PTF_HEADER ..
        TextBoxWidget.PTF_BOLD_START .. title .. TextBoxWidget.PTF_BOLD_END .. " by " .. author .. " is " .. formatted_progress_percent .. "% complete.\n\n" ..  answer
      return result_text
    end

    local answer, err = Querier:query(message_history, loading_message)
    if err then
      assistant.querier:showError(err)
      return
    end

    local chatgpt_viewer
    chatgpt_viewer = ChatGPTViewer:new {
      assistant = assistant,
      ui = ui,
      title = feature_title,
      text = createResultText(answer),
      disable_add_note = true,
      default_hold_callback = function ()
        chatgpt_viewer:HoldClose()
      end,
    }

    UIManager:show(chatgpt_viewer)

    -- Optional: force refresh screen if enabled in configuration
    if koutil.tableGetValue(CONFIGURATION, "features", "refresh_screen_after_displaying_results") then
        UIManager:setDirty(nil, "full")
    end
end

return showFeatureDialog
