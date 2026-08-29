local logger = require("logger")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("assistant_viewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local Font = require("ui/font")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local Prompts = require("assistant_prompts")
local koutil = require("util")
local strbuf = require("string.buffer")
local Device = require("device")
local Screen = Device.screen
local CheckButton = require("ui/widget/checkbutton")
local ASUtils = require("assistant_utils")
local Notebook = require("assistant_notebook")
local extractBookTextForAnalysis = ASUtils.extractBookTextForAnalysis
local normalizeMarkdownHeadings = ASUtils.normalizeMarkdownHeadings

--[[
  Extract the context text selected by the Ask dialog checkboxes.
  When `use_chapter` is set, narrow the context to the chapter containing
  the current position (see ASUtils.extractCurrentChapterText); otherwise
  fall back to the full "book text up to current position" extraction.
--]]
local function extractContextText(CONFIGURATION, ui, use_chapter)
  if use_chapter then
    return ASUtils.extractCurrentChapterText(CONFIGURATION, ui)
  end
  return extractBookTextForAnalysis(CONFIGURATION, ui)
end

--[[
  Format the "[! IMPORTANT !] Here is ..." fragment appended to the user
  question when the "Use Book Text as Context" checkbox is checked.

  Returns "" when there is no book text to include. Single source of truth
  for both Ask paths (regular Ask button and highlight prompt buttons) so
  the LLM instruction stays identical everywhere.

  NOTE: Intentionally NOT wrapped in _() — this fragment is an instruction
  to the LLM (English-only models), not user-facing UI text.
--]]
local function buildBookTextPrompt(use_chapter, book_text)
  if not book_text or book_text == "" then
    return ""
  end
  local context_source = use_chapter
      and "the text of the current chapter I am reading"
      or "the book text up to my current position"
  return string.format(
    "\n\n [! IMPORTANT !] Here is %s, only consider this text for your response, and answer in language of previous part of the question:\n [BOOK TEXT BEGIN]\n%s\n[BOOK TEXT END]",
    context_source, book_text)
end

-- main dialog class
local AssistantDialog = {
  CONFIGURATION = nil,
  assistant = nil,
  querier = nil,
  input_dialog = nil,
}
AssistantDialog.__index = AssistantDialog

function AssistantDialog:new(assistant, c)
  local self = setmetatable({}, AssistantDialog)
  self.assistant = assistant
  self.querier = assistant.querier
  self.CONFIGURATION = c
  return self
end

function AssistantDialog:_close()
  if self.input_dialog then
    UIManager:close(self.input_dialog)
    self.input_dialog = nil
  end
end

function AssistantDialog:_formatUserPrompt(user_prompt, highlightedText, user_input)
  local book = self:_getBookContext()
  
  -- Handle case where no text is highlighted (gesture-triggered)
  local text_to_use = highlightedText and highlightedText ~= "" and highlightedText or ""
  local language = self.assistant.settings:readSetting("response_language") or self.assistant.ui_language
  
  -- Resolve live page number / total pages (mirrors ASUtils.getPageInfo internals)
  local function resolve_page()
    local ui = self.assistant.ui
    if not ui or not ui.highlight or not ui.highlight.selected_text
        or not ui.highlight.selected_text.pos0 then
      return nil, nil
    end
    local pos0 = ui.highlight.selected_text.pos0
    local page_number
    if ui.paging then
      page_number = pos0.page
    else
      page_number = ui.document:getPageFromXPointer(pos0)
    end
    local total_pages = ui.document.info.number_of_pages
    return page_number, total_pages
  end

  -- Calculate progress if placeholder is present
  local formatted_progress = nil
  if user_prompt:find("{progress}", 1, true) then
    local page_number, total_pages = resolve_page()
    if page_number and total_pages and total_pages ~= 0 then
      local pct = math.floor(page_number / total_pages * 100 + 0.5)
      formatted_progress = string.format("%.2f", pct)
    else
      local success, doc_settings = pcall(function()
        return require("docsettings"):open(self.assistant.ui.document.file)
      end)
      if success and doc_settings then
        local percent_finished = doc_settings:readSetting("percent_finished") or 0
        formatted_progress = string.format("%.2f", percent_finished * 100)
      end
    end
  end

  -- Calculate chapter if placeholder is present
  local formatted_chapter = nil
  if user_prompt:find("{chapter}", 1, true) then
    local chapter_title = ""
    local page_number = resolve_page()
    local ui = self.assistant.ui
    if page_number and ui and ui.toc then
      chapter_title = ui.toc:getTocTitleByPage(page_number) or ""
    end
    formatted_chapter = chapter_title
  end

  -- Add user input if placeholder is not present
  if user_input and user_input ~= "" and not user_prompt:find("{user_input}", 1, true) then
    user_prompt = user_prompt.."\n\n[Additional user input]: \n"..user_input
  end

  -- replace placeholders in the user prompt
  return user_prompt:gsub("{([%w%_]+)}", {
    title = book.title,
    author = book.author,
    language = language,
    highlight = text_to_use,
    user_input = user_input,
    progress = formatted_progress,
    chapter = formatted_chapter,
  })

end

function AssistantDialog:_createResultText(highlightedText, message_history, previous_text, title)
  -- Helper function to format a single message (user or assistant)
  local function formatSingleMessage(message, title)
    if not message then return "" end
    if message.role == "user" then
      local user_message = strbuf.new()
      user_message:put(_("### ☺ Question\n"))

      if title and title ~= "" then
        user_message:putf("➤ ‹ %s ›\n", title)

        local user_input = ASUtils.get_attr(message, "user_input", "")

        -- Check if user input is available
        if user_input and user_input ~= "" then

          if user_input:find("%[BOOK TEXT BEGIN%]") then
            user_input = user_input:gsub("%[BOOK TEXT BEGIN%].*%[BOOK TEXT END%]", "[BOOK TEXT]")
          end

          if user_input:find("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%]") then
            user_input = user_input:gsub("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%].*%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT END%]", "[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT]")
          end

          user_message:put("➤")
          user_message:put(user_input)
          user_message:put("\n\n")
        end
      elseif message.content then
        -- shows user input prompt
        local content = message.content

        if content:find("%[BOOK TEXT BEGIN%]") then
          content = content:gsub("%[BOOK TEXT BEGIN%].*%[BOOK TEXT END%]", "[BOOK TEXT]")
        end

        if content:find("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%]") then
          content = content:gsub("%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN%].*%[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT END%]", "[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT]")
        end

        user_message:putf("\n➤ %s\n\n", content)
      end

      return user_message:get()
    elseif message.role == "assistant" then
      local assistant_content, answer_type
      local kw = ASUtils.get_attr(message, "search_keywords")
      if kw then
        answer_type = _("Search")
        assistant_content = string.format("%s\n\n", kw)
      else
        answer_type =  _("Response")
        assistant_content = message.content or _("(No response)")
        if self.assistant.settings:readSetting("auto_prompt_suggest", false) then
          assistant_content = ASUtils.process_suggestions(assistant_content)
        end
        -- Remove code block markers before displaying
        assistant_content = assistant_content:gsub("```", "\n")
        assistant_content = normalizeMarkdownHeadings(assistant_content, 3, 6) or assistant_content
      end

      return string.format("### ✦ %s\n\n%s\n\n", answer_type,assistant_content)
    end
    return "" -- Should not happen for valid roles
  end

  -- first response message
  if not previous_text then
    local result_text = ""
    local show_highlighted_text = true

    -- if highlightedText is nil or empty, don't show highlighted text
    if not highlightedText or highlightedText == "" then
      show_highlighted_text = false
    end

    -- won't show if `hide_highlighted_text` is set to false
    if koutil.tableGetValue(self.CONFIGURATION, "features", "hide_highlighted_text") then
      show_highlighted_text = false
    end

    -- won't show if highlighted text is longer than threshold `long_highlight_threshold`
    if show_highlighted_text and koutil.tableGetValue(self.CONFIGURATION, "features", "hide_long_highlights") and
        highlightedText and #highlightedText > (koutil.tableGetValue(self.CONFIGURATION, "features", "long_highlight_threshold") or 99999) then
      show_highlighted_text = false
    end

    local result_parts = {}
    if show_highlighted_text then
      table.insert(result_parts, string.format("__%s__\"%s\"\n\n", _("Highlighted text:"), highlightedText))
    end
    
    -- skips the first message (system prompt)
    for i = 2, #message_history do
      local message = message_history[i]
      local is_context = ASUtils.get_attr(message, "is_context")
      if not is_context then
        table.insert(result_parts, formatSingleMessage(message, title))
      end
    end
    return table.concat(result_parts)
  end

  local last_user_message = message_history[#message_history - 1]
  local last_assistant_message = message_history[#message_history]

  return previous_text .. "------------\n\n" ..
      formatSingleMessage(last_user_message, title) .. formatSingleMessage(last_assistant_message, title)
end

-- Helper function to create and show ChatGPT viewer
function AssistantDialog:_createAndShowViewer(highlightedText, message_history, title)
  local result_text = self:_createResultText(highlightedText, message_history, nil, title)
  
  local chatgpt_viewer 
  chatgpt_viewer = ChatGPTViewer:new {
    title = title,
    text = result_text,
    assistant = self.assistant,
    ui = self.assistant.ui,
    -- Hide Add Note button when invoked via gesture (no highlighted text)
    disable_add_note = (not highlightedText or highlightedText == ""),
    onAskQuestion = function(viewer, user_question, use_websearch) -- callback for user entered question
        -- Use viewer's own highlighted_text value
        local current_highlight = viewer.highlighted_text or highlightedText
        local viewer_title = ""

        if type(user_question) == "string" then
          -- Use user entered question
          self:_prepareMessageHistoryForUserQuery(message_history, current_highlight, user_question, use_websearch)
        elseif type(user_question) == "table" then
          -- Use custom prompt from configuration
          viewer_title = Prompts.getDisplayText(user_question.text or "Custom Prompt",
            user_question.use_websearch or false,
            Prompts.isWebSearchEnabled(self.assistant.settings))
          if user_question.use_book_context == true
              and self.assistant.settings:readSetting("prepend_book_metadata", true) then
            table.insert(message_history, self:_buildBookContextMessage(current_highlight))
          end

          local _user = {
            role = "user",
            content = self:_formatUserPrompt(user_question.user_prompt, current_highlight, user_question.user_input or ""),
          }
          -- set these attributes in metatable (won't be encoded to API calls)
          ASUtils.set_attr(_user, "user_input", user_question.user_input)
          ASUtils.set_attr(_user, "use_websearch", user_question.use_websearch)
          table.insert(message_history, _user)
        end

        viewer:trimMessageHistory()
        ASUtils.runWhenOnlineFast(function()
          Trapper:wrap(function()
            local answer, err = self.querier:query(message_history)
            
            -- Check if we got a valid response
            if err then
              self.querier:showError(err, message_history)
              return
            end
            
            table.insert(message_history, {
              role = "assistant",
              content = answer
            })
            viewer:update(self:_createResultText(current_highlight, message_history, viewer.text, viewer_title))
            
            if viewer.scroll_text_w then
              viewer.scroll_text_w:resetScroll()
            end
          end)
        end)
      end,
    highlighted_text = highlightedText,
    message_history = message_history,
    default_hold_callback = function () chatgpt_viewer:HoldClose() end
  }
  
  UIManager:show(chatgpt_viewer)
end


function AssistantDialog:_buildBookContextMessage(highlighted_text)
  local book = self:_getBookContext()
  local head
  if highlighted_text and highlighted_text ~= "" then
    head = string.format([[I'm reading something titled '%s' by %s.
I have a question about the following highlighted text: ```%s```.
If the question is not clear enough, analyze the highlighted text.]],
      book.title, book.author, highlighted_text)
  elseif book.title and book.author then
    head = string.format([[I'm reading something titled '%s' by %s.
I have a question about this book.]], book.title, book.author)
  else
    head = string.format([[You are a helpful assistant. I have a question.]])
  end

  -- Append segments into a string buffer: avoids repeated `content = content ..`
  -- intermediate string objects.
  local buf = strbuf.new()
  buf:put(head)

  local page_info = ASUtils.getPageInfo(self.assistant.ui)
  if page_info and page_info ~= "" then
    buf:put("\n\n", string.format("My current reading position is:%s.", page_info))
  end

  if highlighted_text and highlighted_text ~= ""
      and self.assistant.settings:readSetting("include_page_text", false) then
    local max_chars = koutil.tableGetValue(self.CONFIGURATION, "features", "max_page_context_chars") or 6000
    local page_text = ASUtils.getPageRangeText(self.assistant.ui, 1, 1, max_chars)
    if page_text ~= "" then
      buf:put("\n\n", string.format(
        "Surrounding text from the book (for reference only - the task applies ONLY to the highlighted passage):\n```\n%s\n```",
        page_text))
    end
  end

  local msg = {
    role = "user",
    content = buf:get(),
  }
  ASUtils.set_attr(msg, "is_context", true)
  return msg
end

function AssistantDialog:_prepareMessageHistoryForUserQuery(message_history, highlightedText, user_question, use_websearch)
  local context = self:_buildBookContextMessage(highlightedText)
  table.insert(message_history, context)

  local question_message = {
    role = "user",
    content = user_question
  }
  ASUtils.set_attr(question_message, "use_websearch", use_websearch or false)
  table.insert(message_history, question_message)
end

function AssistantDialog:_getBookContext()
  local ui = self.assistant and self.assistant.ui
  if not ui or not ui.document then
    return { title = nil, author = nil }
  end

  local ok, props = pcall(function() return ui.document:getProps() end)
  if not ok or not props then
    return { title = nil, author = nil }
  end

  return {
    title = props.title or "Unknown Title",
    author = props.authors or "Unknown Author",
  }
end

-- When clicked [Assistant] button in main select popup,
-- Or when activated from guesture (no text highlighted)
function AssistantDialog:show(highlightedText)

  local is_highlighted = highlightedText and highlightedText ~= ""
  
  -- close any existing input dialog
  self:_close()

  -- Handle regular dialog (user input prompt, other buttons)
  local book = self:_getBookContext()
  local use_multi_general_notebooks =
      not self.assistant.ui.doc_settings and Notebook.isEnabled(self.assistant)
  local system_prompt = koutil.tableGetValue(self.CONFIGURATION, "features", "system_prompt") or koutil.tableGetValue(Prompts, "assistant_prompts", "default", "system_prompt")
  if self.assistant.settings:readSetting("auto_prompt_suggest", false) then
    local language = self.assistant.settings:readSetting("response_language") or self.assistant.ui_language
    system_prompt = system_prompt .. Prompts.assistant_prompts.suggestions_prompt
  end

  local message_history = {{
    role = "system",
    content = system_prompt
  }}

  -- Create button rows (3 buttons per row)
  local button_rows = {}
  local prompt_buttons = {}
  local use_book_text_checkbox -- ref to the CheckButton widget
  local use_chapter_checkbox -- ref to the chapter-limit CheckButton widget
  local use_web_search_checkbox -- ref to the web search CheckButton widget
  local first_row = {
    {
      text = _("Cancel"),
      id = "close",
      callback = function()
        self:_close()
      end
    },
  }

  if use_multi_general_notebooks then
    table.insert(first_row, {
      id = "general_notebook",
      text = Notebook.getActiveDisplayName(self.assistant, 18),
      callback = function()
        -- Hide the keyboard while the picker is open, but keep the current
        -- question text in the existing InputDialog.
        if self.input_dialog then
          self.input_dialog:onCloseKeyboard()
        end

        Notebook.showPicker(self.assistant, {
          title = _("Select notebook"),
          on_select = function()
            if not self.input_dialog then
              return
            end

            local button = self.input_dialog.button_table
                and self.input_dialog.button_table:getButtonById("general_notebook")
            if button then
              button:setText(
                Notebook.getActiveDisplayName(self.assistant, 18),
                button.width
              )
              button:refresh()
            end

            UIManager:nextTick(function()
              if self.input_dialog then
                self.input_dialog:onShowKeyboard()
              end
            end)
          end,
        })
      end,
    })
  end

  table.insert(first_row, {
      text = _("Ask"),
      is_enter_default = true,
      callback = function()
        local user_question = self.input_dialog and self.input_dialog:getInputText() or ""
        local book_text_prompt = ""
        if use_book_text_checkbox and use_book_text_checkbox.checked then
          local use_chapter = use_chapter_checkbox and use_chapter_checkbox.checked
          book_text_prompt = buildBookTextPrompt(use_chapter,
              extractContextText(self.CONFIGURATION, self.assistant.ui, use_chapter))
        end
        if not user_question or user_question == "" then
          UIManager:show(InfoMessage:new{
            text = _("Enter a question before proceeding."),
            timeout = 3
          })
          return
        end
        if self.assistant.settings:readSetting("auto_copy_asked_question", true) and Device:hasClipboard() then
          Device.input.setClipboardText(user_question)
        end
        self:_close()
        user_question = user_question .. book_text_prompt
        self:_prepareMessageHistoryForUserQuery(message_history, highlightedText, user_question, use_web_search_checkbox.checked)
        Trapper:wrap(function()
          local answer, err = self.querier:query(message_history)
          
          -- Check if we got a valid response
          if err then
            self.querier:showError(err, message_history)
            return
          end
          
          table.insert(message_history, {
            role = "assistant",
            content = answer,
          })
          
          -- do not have a title to display user prompt 
          local viewer_title = nil
          self:_createAndShowViewer(highlightedText, message_history, viewer_title)
        end)
      end
    })

  -- Only add additional buttons if there's highlighted text
  if is_highlighted then
    local sorted_prompts = Prompts.getSortedPrompts(function (prompt)
      if prompt.visible == false then
        return false
      end
      return true
    end, Prompts.isWebSearchEnabled(self.assistant.settings)) or {}

    -- logger.warn("Sorted prompts: ", sorted_prompts)
    -- Add buttons in sorted order
    for i, tab in ipairs(sorted_prompts) do
      table.insert(prompt_buttons, {
        text = tab.text,
        callback = function()
          local user_question = self.input_dialog and self.input_dialog:getInputText() or ""
          if user_question ~= "" and self.assistant.settings:readSetting("auto_copy_asked_question", true) and Device:hasClipboard() then
            Device.input.setClipboardText(user_question)
          end
          self:_close()
          Trapper:wrap(function()
            if tab.order == -10 and tab.idx == "dictionary" then
              -- Special case for dictionary prompt
              local showDictionaryDialog = require("assistant_dictdialog")
              showDictionaryDialog(self.assistant, highlightedText)
            elseif tab.idx == "term_xray" then
              -- Special case for term_xray prompt - use dictionary dialog with enhanced context
              local showDictionaryDialog = require("assistant_dictdialog")
              showDictionaryDialog(self.assistant, highlightedText, nil, "term_xray")
            elseif tab.idx == "quick_note" then
              -- Special case for quick note prompt
              if not self.assistant.quicknote then
                local QuickNote = require("assistant_quicknote")
                self.assistant.quicknote = QuickNote:new(self.assistant)
              end
              -- Save note with highlighted text
              self.assistant.quicknote:saveNote(user_question, highlightedText)
            else
              local book_text_prompt = ""
              if use_book_text_checkbox and use_book_text_checkbox.checked then
                local use_chapter = use_chapter_checkbox and use_chapter_checkbox.checked
                book_text_prompt = buildBookTextPrompt(use_chapter,
                    extractContextText(self.CONFIGURATION, self.assistant.ui, use_chapter))
              end
              user_question = user_question .. book_text_prompt
              self:showPrompt(highlightedText, tab.idx, user_question)
            end
          end)
        end,
        hold_callback = function()
          local menukey = string.format("assistant_%02d_%s", tab.order, tab.idx)
          local settingkey = "showOnMain_" .. menukey
          UIManager:show(ConfirmBox:new{
            text = ASUtils.bold_format(
              T(_("<b>%1:</b> %2\n\nAdd this button to the Highlight Menu?"), tab.text, tab.desc)
            ),
            ok_text = _("Add"),
            ok_callback = function()
              self.assistant:handleEvent(Event:new("AssistantSetButton", {order=tab.order, idx=tab.idx}, "add"))
            end,
          })
        end
      })
    end
  end
  
  table.insert(button_rows, first_row)
  -- Organize buttons into rows of three
  local current_row = {}
  for _, button in ipairs(prompt_buttons) do
    table.insert(current_row, button)
    if #current_row == 3 then
      table.insert(button_rows, current_row)
      current_row = {}
    end
  end
  
  if #current_row > 0 then
    table.insert(button_rows, current_row)
  end

  -- Show the dialog with the button rows
  local dialog_hint
  if is_highlighted then
      dialog_hint = _("Ask a question about the highlighted text")
  elseif book.title then
      dialog_hint = ASUtils.bold_format(
          T(_("<b>Ask a question about this book:</b>\n%1 by %2"), book.title, book.author)
      )
  else
      dialog_hint = _("Ask a general question")
  end
  local input_hint = is_highlighted and 
      _("Type your question here...") or 
      book.title and _("Ask anything about this book...")
      or _("Ask anything...")  
  
  self.input_dialog = InputDialog:new{
    title = _("AI Assistant"),
    description = dialog_hint,
    input_hint = input_hint,
    input_height = 6,
    allow_newline = true,
    input_multiline = true,
    text_height = math.floor( 3 * Screen:scaleBySize(20) ), -- about 3 lines of text
    buttons = button_rows,
    title_bar_left_icon = "appbar.settings",
    title_bar_left_icon_tap_callback = function ()
        self.input_dialog:onCloseKeyboard()
        self.assistant:showSettings()
    end,
    close_callback = function () self:_close() end,
    dismiss_callback = function () self:_close() end
  }

  -- Add checkboxes below the input field
  local vgroup = self.input_dialog.dialog_frame[1]
  local checkbox_pos = 2 -- insert after the input text area
  local web_search_available = self.assistant.settings:readSetting("use_websearch", "none") ~= "none"
  local saved_web_search = self.assistant.settings:readSetting("ask_use_websearch", false)
  use_web_search_checkbox = CheckButton:new{
    face = Font:getFace("xx_smallinfofont"),
    text = _("Use web search 🌐"),
    parent = self.input_dialog,
    checked = web_search_available and saved_web_search,
    enabled = web_search_available,
    callback = function()
      self.assistant.settings:saveSetting("ask_use_websearch", use_web_search_checkbox.checked)
    end,
  }
  table.insert(vgroup, checkbox_pos, HorizontalGroup:new{
    HorizontalSpan:new{ width = Size.padding.large },
    use_web_search_checkbox,
  })
  checkbox_pos = checkbox_pos + 1

  -- Both checkboxes live under the `book.title` guard: the chapter option
  -- depends on the "Use Book Text as Context" checkbox, and `_getBookContext`
  -- falls back to "Unknown Title", so this guard is only bypassed when the
  -- document props fail entirely (in which case hiding both is correct).
  if book.title then
    use_book_text_checkbox = CheckButton:new{
      face = Font:getFace("xx_smallinfofont"),
      text = _("Use Book Text as Context"),
      parent = self.input_dialog,
      callback = function()
        -- The chapter-limit option only takes effect when book text is
        -- enabled; mirror that state (greyed out / unchecked otherwise).
        if use_chapter_checkbox then
          if use_book_text_checkbox.checked then
            use_chapter_checkbox:enable()
          else
            use_chapter_checkbox:disable()
          end
        end
      end,
    }
    table.insert(vgroup, checkbox_pos, HorizontalGroup:new{
      HorizontalSpan:new{ width = Size.padding.large },
      use_book_text_checkbox,
    })
    checkbox_pos = checkbox_pos + 1

    -- Chapter limit is only offered when a TOC chapter covers the current
    -- position (no TOC / outside the TOC -> no option).
    local chapter_range = ASUtils.getCurrentChapterRange(self.assistant.ui)
    if chapter_range then
      use_chapter_checkbox = CheckButton:new{
        face = Font:getFace("xx_smallinfofont"),
        text = _("Limit Context to Current Chapter"),
        parent = self.input_dialog,
        -- No effect unless "Use Book Text as Context" is checked too;
        -- starts disabled and follows that checkbox via its callback.
        enabled = use_book_text_checkbox.checked,
      }
      table.insert(vgroup, checkbox_pos, HorizontalGroup:new{
        HorizontalSpan:new{ width = Size.padding.large },
        use_chapter_checkbox,
      })
      checkbox_pos = checkbox_pos + 1
    end
  end

  local use_copy_clipboard_checkbox
  use_copy_clipboard_checkbox = CheckButton:new{
    face = Font:getFace("xx_smallinfofont"),
    text = _("Copy to Clipboard"),
    parent = self.input_dialog,
    checked = self.assistant.settings:readSetting("auto_copy_asked_question", true),
    callback = function()
      self.assistant.settings:saveSetting("auto_copy_asked_question", use_copy_clipboard_checkbox.checked)
    end,
  }
  table.insert(vgroup, checkbox_pos, HorizontalGroup:new{
    HorizontalSpan:new{ width = Size.padding.large },
    use_copy_clipboard_checkbox,
  })
  checkbox_pos = checkbox_pos + 1
  
  --  adds a close button to the top right
  self.input_dialog.title_bar.close_callback = function() self:_close() end
  self.input_dialog.title_bar:init()

  -- Show the dialog
  UIManager:show(self.input_dialog)
end

-- Process main select popup buttons
-- ( prompts from configuration )
function AssistantDialog:showPrompt(highlightedText, prompt_index, user_input)

  local user_prompts = koutil.tableGetValue(self.CONFIGURATION, "features", "prompts")
  local prompt_config = Prompts.getMergedPrompts(user_prompts)[prompt_index]

  local raw_title = koutil.tableGetValue(prompt_config, "text") or prompt_index
  local title = Prompts.getDisplayText(raw_title,
    koutil.tableGetValue(prompt_config, "use_websearch") or false,
    Prompts.isWebSearchEnabled(self.assistant.settings))

  highlightedText = highlightedText:gsub("\n", "\n\n") -- ensure newlines are doubled (LLM presumes markdown input)

  local user_content = self:_formatUserPrompt(koutil.tableGetValue(prompt_config, "user_prompt"), highlightedText, user_input or "")
  local system_prompt = koutil.tableGetValue(prompt_config, "system_prompt") or koutil.tableGetValue(Prompts, "assistant_prompts", "default", "system_prompt")

  if self.assistant.settings:readSetting("auto_prompt_suggest", false) then
    system_prompt = system_prompt .. Prompts.assistant_prompts.suggestions_prompt
  end

  local message_history = {{
    role = "system",
    content = system_prompt,
  }}

  if prompt_config.use_book_context == true
      and self.assistant.settings:readSetting("prepend_book_metadata", true) then
    table.insert(message_history, self:_buildBookContextMessage(highlightedText))
  end

  local _user = {
    role = "user",
    content = user_content,
  }
  -- set attributes in metatable (won't be encoded to API calls)
  ASUtils.set_attr(_user, "user_input", user_input)
  ASUtils.set_attr(_user, "use_websearch", koutil.tableGetValue(prompt_config, "use_websearch") or false)
  table.insert(message_history, _user)
  
  local answer, err = self.querier:query(message_history, T(_("Loading for %1 ..."), title or prompt_index))
  if err then
    self.querier:showError(err, message_history)
    return
  end
  if answer then
    table.insert(message_history, {
      role = "assistant",
      content = answer
    })
  end

  if not message_history or #message_history < 1 then
    UIManager:show(InfoMessage:new{
        text = ASUtils.bold_format(_("<b>Error:</b> No response received")),
        icon = "notice-warning"
    })
    return
  end

  self:_createAndShowViewer(highlightedText, message_history, title)
end

return AssistantDialog