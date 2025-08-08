local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local InfoMessage = require("ui/widget/infomessage")
local Event = require("ui/event")
local t = require("i18n")
local ChatGPTViewer = require("chatgptviewer")
local configuration = require("configuration")
local recap_prompts = require("prompts").assitant_prompts.recap

local function showRecapDialog(assitant, title, author, progress_percent, message_history)
    local Querier = assitant.querier
    local ui = assitant.ui

    -- Check if Querier is initialized
    local ok, err = Querier:load_model(assitant:getModelProvider())
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    local formatted_progress_percent = string.format("%.2f", progress_percent * 100)
    
    -- Get recap configuration with fallbacks
    local recap_config = configuration.features and configuration.features.recap_config or {}
    local system_prompt = recap_config.system_prompt or recap_prompts.system_prompt
    local user_prompt_template = recap_config.user_prompt or recap_prompts.user_prompt
    local language = configuration.features and configuration.features.response_language or "English"
    
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

    local answer, err = Querier:query(message_history, "Loading Recap ...")
    if err ~= nil then
      UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
      return
    end

    local chatgpt_viewer = ChatGPTViewer:new {
      assitant = assitant,
      ui = ui,
      title = t("recap"),
      text = createResultText(answer),
    }

    UIManager:show(chatgpt_viewer)
end

return showRecapDialog
