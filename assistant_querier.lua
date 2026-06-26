--- Querier module for handling AI queries with dynamic provider loading
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local InputText = require("ui/widget/inputtext")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local Size = require("ui/size")
local koutil = require("util")
local logger = require("logger")
local rapidjson = require('rapidjson')
local strbuf = require("string.buffer")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local Device = require("device")
local assistant_utils = require("assistant_utils")
local ToolExecutor = require("assistant_tool_executor")
local Screen = Device.screen

local API_HANDLERS = {}
local MAX_TOOL_ROUNDS = 3

-- default_value for rapidjson decoded object
local function json_default(value, default_value)
    if value == nil or value == rapidjson.null then
        return default_value
    end
    return value
end
local Querier = {
    assistant = nil, -- reference to the main assistant object
    settings = nil,
    handler = nil,
    handler_name = nil,
    provider_setting = nil,        -- setting of a single api config from provider_settings
    provider_name = nil,
    interrupt_stream = nil,      -- function to interrupt the stream query
    user_interrupted = false,  -- flag to indicate if the stream was interrupted
}

--- Normalize tool call: merge arguments_parts into a single arguments string
--- @param tool_call table  { id, name, arguments_parts or arguments or args }
--- @return table normalized tool call
local function normalizeToolCall(tool_call)
    if tool_call.arguments_parts then
        -- OpenAI/Anthropic format: merge arguments_parts into arguments
        tool_call.arguments = tool_call.arguments_parts:tostring()
        tool_call.arguments_parts = nil
    end
    return tool_call
end

function Querier:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    -- init handlers names
    if next(API_HANDLERS) == nil then
        koutil.findFiles(o.assistant.path .. "/api_handlers", function (path, f, attr)
            if f == "base" then return end
            local h = f:gsub("%.lua$", "", 1)
            API_HANDLERS[h] = true
        end, false)
    end
    return o
end

function Querier:is_inited()
    return self.handler ~= nil
end

function Querier:is_handler(provider_name)
    if API_HANDLERS[provider_name] then return true end
    
    local handler_name
    local underscore_pos = provider_name:find("_")
    if underscore_pos and underscore_pos > 0 then
        handler_name = provider_name:sub(1, underscore_pos - 1)
    end
    return handler_name and API_HANDLERS[handler_name]
end

--- Load provider model for the Querier
function Querier:load_model(provider_name)
    -- If the provider is already loaded, do nothing.
    if provider_name == self.provider_name and self:is_inited() then
        return true
    end

    local CONFIGURATION = self.assistant.CONFIGURATION
    local provider_setting = koutil.tableGetValue(CONFIGURATION, "provider_settings", provider_name)
    if not provider_setting then
        local err = T(_("Provider settings not found for: %1. Please check your configuration.lua file."),
         provider_name)
        logger.warn("Querier initialization failed: " .. err)
        return false, err
    end
    local serpapi = koutil.tableGetValue(CONFIGURATION, "provider_settings", "serpapi")
    local tavilyapi = koutil.tableGetValue(CONFIGURATION, "provider_settings", "tavilyapi")

    local handler_name
    local underscore_pos = provider_name:find("_")
    if underscore_pos and underscore_pos > 0 then
        -- Extract `openai` from `openai_o4mimi`
        handler_name = provider_name:sub(1, underscore_pos - 1)
    else
        handler_name = provider_name -- original name
    end

    -- Load the handler based on the provider name
    local success, handler = pcall(function()
        return require("api_handlers." .. handler_name)
    end)
    if success then
        self.handler = handler
        self.handler_name = handler_name
        -- Shallow copy to avoid mutating CONFIGURATION
        self.provider_setting = koutil.tableDeepCopy(provider_setting)
        assistant_utils.set_attr(self.provider_setting, "serpapi", serpapi)
        assistant_utils.set_attr(self.provider_setting, "tavilyapi", tavilyapi)
        self.provider_name = provider_name
        -- Apply saved OpenRouter model override
        if handler_name == "openrouter" then
            local saved_model = self.settings:readSetting("openrouter_model_" .. provider_name)
            if saved_model and saved_model ~= "" then
                self.provider_setting.model = saved_model
            end
        end
        return true
    else
        local err = T(_("The handler for %1 was not found. Please ensure the handler exists in api_handlers directory."),
                handler_name)
        logger.warn("Querier initialization failed: " .. err)
        return false, err
    end
end

-- InputText class for showing streaming responses
-- ignores all input events
local StreamText = InputText:extend{}
function StreamText:addChars(chars)
    self.readonly = false                           -- widget is inited with `readonly = true`
    InputText.addChars(self, chars)                 -- can only add text by our method
end
function StreamText:initTextBox(text, char_added)
    self.for_measurement_only = true                -- trick super class method avoiding showing cursor
    InputText.initTextBox(self, text, char_added)
    UIManager:setDirty(self.parent, function() return "ui", self.dimen end)
    self.for_measurement_only = false
end

function Querier:showError(err)
    logger.warn("API Error", err)
    local dialog
    if self.user_interrupted then
        dialog = InfoMessage:new{ timeout = 3, text = err }
    else
        dialog = ConfirmBox:new{
            text = T(_("API Error:\n%1\n\nTry another provider in the settings dialog."), err or _("Unknown error")),
            ok_text = _("Settings"),
            ok_callback = function() self.assistant:showSettings() end,
            cancel_text = _("Close"),
        }
    end
    UIManager:show(dialog)

    -- clear the text selection when plugin is called without a highlight or dict dialog
    if self.assistant.ui.highlight then
        if not (self.assistant.ui.highlight.highlight_dialog or self.assistant.ui.dictionary.dict_window) then
            self.assistant.ui.highlight:clear()
        end
    end
end


--- Create a bouncing period animation
-- Returns a table with animation frames and current frame index
local function createWaitingAnimation()
    local frames = { "◐  ", "◓  ", "◑  ", "◒  " }
    local currentIndex = 1

    return {
        getNextFrame = function()
            local frame = frames[currentIndex]
            currentIndex = currentIndex + 1
            if currentIndex > #frames then
                currentIndex = 1
            end
            return frame
        end,
        reset = function()
            currentIndex = 1
        end
    }
end

local function ExecuteResearch(tool_calls_array, tool_rounds, ws_mode, provider_setting, handler)
    local res, err
    local all_search_ok = true
    local search_results = {}
    for _, tool_call in ipairs(tool_calls_array) do

        -- Decode keywords from tool call arguments
        local tool_call_id, keywords, extract_err = ToolExecutor.extractKeywords(tool_call)
        if not keywords then
            res = nil
            err = extract_err
            break
        end

        tool_rounds = tool_rounds + 1
        local search_ok, search_result
        if tool_rounds < MAX_TOOL_ROUNDS then
            -- Execute web search via ToolExecutor
            search_ok, search_result = ToolExecutor.executeWebSearch(
                keywords,
                ws_mode,
                provider_setting,
                handler)
        else
            -- Maximum call reached. (tool_rounds == MAX_TOOL_ROUNDS)
            -- include instruction prompt let LLM dract the answer immediately
            search_ok, search_result = ToolExecutor.maximumToolRoundReached()
        end
        if search_ok then
            table.insert(search_results, {
                search_result = search_result,
                tool_call_id = tool_call_id,
            })
        else
            logger.warn("search err", search_result)
            all_search_ok = false
        end
    end


    if not all_search_ok then
        err = "Not all search succeeds"
        return nil, err
    end

    return true, search_results
end

--- Query the AI with the provided message history.
--- Handles both stream and non-stream modes, including multi-turn tool-call loops.
---
--- Non-stream tool-call loop:
---   handler:query() returns a table { __is_tool_call=true, keywords=..., ... }
---   → Querier executes the appropriate search API
---   → appends the tool result messages via ToolExecutor.appendToolResult()
---   → repeats until a plain-string answer or an error
---
--- Stream tool-call loop (TODO: not fully shown here; stream does not support
--- tool calls in the current architecture — use non-stream for websearch).
---
function Querier:query(message_history, title)
    if not self:is_inited() then
        return nil, _("Plugin is not configured.")
    end

    local prompt_websearch   = assistant_utils.get_attr(message_history[#message_history], "use_websearch", false)
    local user_setting_ws    = self.settings:readSetting("use_websearch", "none")
    local query_option = {
        use_stream_mode = self.settings:readSetting("use_stream_mode", true),
        use_websearch   = (prompt_websearch and user_setting_ws ~= "none")
                          and user_setting_ws or "none",
    }

    local res, err

    if query_option.use_stream_mode then
        -- ---------------------------------------------------------------
        -- STREAM PATH  — supports multi-turn tool-call loop
        --
        -- handler:query() returns a background function; showStremDialog
        -- drives processStream and returns:
        --   ok=true,  content=string,  nil          → plain text answer
        --   ok=true,  content=nil,     tool_calls=[] → LLM wants tool(s)
        --   ok=nil,   err=string                     → cancelled / error
        -- ---------------------------------------------------------------
        local tool_rounds = 0

        repeat
            local bg_fn
            bg_fn, err = self.handler:query(message_history, self.provider_setting, query_option)

            if type(bg_fn) ~= "function" then
                -- handler returned an error before even starting the stream
                res = nil
                break
            end
            if tool_rounds > MAX_TOOL_ROUNDS then
                res = nil
                err = _("Too many tool-call rounds; aborting.")
                break
            end

            local ok, content, tool_calls_array = self:showStremDialog(bg_fn)
            if not ok then
                -- cancelled or stream error
                res = nil
                err = content or _("Stream failed with no error message.")
                break
            end

            if type(content) == "string" then
                -- Normal text answer — done
                res = content
                err = nil
                break
            end

            -- Tool calls detected in stream
            if type(tool_calls_array) ~= "table" or #tool_calls_array == 0 then
                res = nil
                err = _("Stream ended with no content and no tool calls.")
                break
            end

            -- Build tool result and append to history
            local format = ToolExecutor.getHandlerFormat(self.handler_name)
            local build_ok, raw_assistant = ToolExecutor.buildRawAssistantForToolCall(tool_calls_array, format, content)
            if not build_ok then
                res = nil
                err = raw_assistant
                break
            end
            local search_ok, search_results = ExecuteResearch(tool_calls_array, tool_rounds,
                                                query_option.use_websearch,
                                                self.provider_setting,
                                                self.handler)
            if not search_ok then
                res = nil
                err = search_results
                break
            end
            tool_rounds = tool_rounds + #search_results

            local append_ok, append_err = ToolExecutor.appendToolResult(message_history, {
                    raw_assistant  = raw_assistant,
                    format         = format,
                    search_results = search_results,
            })

            if not append_ok then
                res = nil
                err = append_err
                break
            end

            -- query_option stays unchanged; loop will call handler:query again with augmented history
            res = nil
            err = nil

        until type(res) == "string" or (err ~= nil)

        if self.user_interrupted then
            return nil, _("Request Cancelled by user.")
        end

    else
        -- ---------------------------------------------------------------
        -- NON-STREAM PATH  — may loop for tool calls
        -- ---------------------------------------------------------------
        local notify = string.format("%s\n️☁️ %s\n⚡ %s",
            title or _("Querying AI ..."),
            self.provider_name,
            koutil.tableGetValue(self.provider_setting, "model"))
        if query_option.use_websearch ~= "none" then
            notify = notify .. "\n" .. _("With Search: ") .. ToolExecutor.SettingkeyToText(query_option.use_websearch)
        end
        local infomsg = InfoMessage:new{ icon = "book.opened", text = notify }
        UIManager:show(infomsg)
        self.handler:setTrapWidget(infomsg)

        -- Tool-call loop: keep calling the LLM until it returns a string answer.
        -- Bounded to a small iteration count to prevent runaway loops.
        local tool_rounds = 0

        repeat
            res, err = self.handler:query(message_history, self.provider_setting, query_option)

            if type(res) == "table" and res.__is_tool_call then
                -- The LLM requested a tool call (web_search).
                if tool_rounds >= MAX_TOOL_ROUNDS + 1 then -- the hard stop for MAX_TOOL_ROUNDS
                    res = nil
                    err = _("Too many tool-call rounds; aborting.")
                    break
                end

                -- Build tool result and append to history
                local format = ToolExecutor.getHandlerFormat(self.handler_name)
                local search_ok, search_results = ExecuteResearch(res.tool_calls, tool_rounds,
                                                query_option.use_websearch,
                                                self.provider_setting,
                                                self.handler)
                if not search_ok then
                    res = nil
                    err = search_results
                    break
                end
                tool_rounds = tool_rounds + #search_results
                local append_ok, append_err = ToolExecutor.appendToolResult(message_history, {
                        raw_assistant  = res.raw_assistant,
                        format         = format,
                        search_results = search_results,
                })

                if not append_ok then
                    res = nil
                    err = append_err
                    break
                end

                -- Refresh the loading indicator for the follow-up request
                UIManager:close(self.handler:resetTrapWidget())
                local follow_msg = InfoMessage:new{
                    icon = "book.opened",
                    text = string.format("%s\n️☁️ %s\n⚡ %s",
                        _("Composing answer ..."),
                        self.provider_name,
                        koutil.tableGetValue(self.provider_setting, "model")),
                }
                UIManager:show(follow_msg)
                self.handler:setTrapWidget(follow_msg)

                res = nil  -- ensure loop continues
            end

        until type(res) == "string" or err ~= nil
        UIManager:close(self.handler:resetTrapWidget())
    end

    if err == self.handler.CODE_CANCELLED then
        self.user_interrupted = true
        return nil, _("Request cancelled by user.")
    end

    -- Final validation
    if type(res) ~= "string" or err ~= nil then
        return nil, tostring(err)
    elseif #res == 0 then
        return nil, _("No response received.") .. (err and tostring(err) or "")
    end
    return res
end
function Querier:showStremDialog(res)

    self.user_interrupted = false -- reset the stream interrupted flag
    local streamDialog
    local animation_task = nil -- Will be set during animation setup

    local function _closeStreamDialog()
        if self.interrupt_stream then self.interrupt_stream() end
        if animation_task then
            UIManager:unschedule(animation_task)
            animation_task = nil
        end
        UIManager:close(streamDialog)
    end

    -- user may perfer smaller stream dialog on big screen device 
    local width, use_available_height, text_height, is_movable
    if self.settings:readSetting("large_stream_dialog", true) then
        width = Screen:getWidth() - 2*Size.margin.default
        text_height = nil
        use_available_height = true
        is_movable = false
    else
        width = Screen:getWidth() - Screen:scaleBySize(80) 
        text_height = math.floor(Screen:getHeight() * 0.35)
        use_available_height = false
        is_movable = true
    end

    streamDialog = InputDialog:new{
        title = _("AI is responding") ,
        description = T("☁ %1/%2", self.provider_name, self.provider_setting.model),
        inputtext_class = StreamText, -- use our custom InputText class
        input_face = Font:getFace("infofont", self.settings:readSetting("response_font_size") or 20),
        title_bar_left_icon = "appbar.settings",
        title_bar_left_icon_tap_callback = function ()
            self.assistant:showSettings()
        end,

        -- size parameters
        width = width, use_available_height = use_available_height, text_height = text_height, is_movable = is_movable,

        -- other behavior parameters
        readonly = true, fullscreen = false, 
        allow_newline = true, add_nav_bar = false, cursor_at_end = true, add_scroll_buttons = true,
        condensed = true, auto_para_direction = true,  scroll_by_pan = true, 
        buttons = {
            {
                {
                    text = _("⏹ Stop"),
                    id = "close", -- id:close response to default cancel action (esc key ...)
                    callback = _closeStreamDialog,
                },
            }
        }
    }

    --  adds a close button to the top right
    streamDialog.title_bar.close_callback = _closeStreamDialog
    streamDialog.title_bar:init()
    UIManager:show(streamDialog)

    -- Set up waiting animation
    local animation = createWaitingAnimation()
    local first_content_received = false

    -- Start animation
    streamDialog._input_widget:setText(animation:getNextFrame(), true)
    local function updateAnimation()
        if not first_content_received then
            streamDialog._input_widget:setText(animation:getNextFrame(), true)
            animation_task = UIManager:scheduleIn(0.4, updateAnimation)
        end
    end
    animation_task = UIManager:scheduleIn(0.4, updateAnimation)

    local stream_mode_auto_scroll = self.settings:readSetting("stream_mode_auto_scroll", true)
    local ok, content, tool_calls_or_err = pcall(self.processStream, self, res, function (content, buffer)
        UIManager:nextTick(function ()
            -- Stop animation on first content
            if not first_content_received and content and #tostring(content) > 0 then
                first_content_received = true
                if animation_task then
                    UIManager:unschedule(animation_task)
                    animation_task = nil
                end
                streamDialog._input_widget:setText("", true) -- Clear the animation
            end

            -- schedule the text update in the UIManager task queue
            if first_content_received then
                if stream_mode_auto_scroll then
                    streamDialog:addTextToInput(content or "")
                else
                    streamDialog._input_widget:resyncPos()
                    streamDialog._input_widget:setText(buffer and buffer:tostring() or "", true)
                end
            end
        end)
    end)
    local err
    if not ok then
        -- pcall failure: content holds the Lua error, tool_calls_or_err is nil
        logger.warn("Error processing stream: " .. tostring(content))
        err = content
    elseif type(tool_calls_or_err) == "table" then
        -- processStream detected a tool call; tool_calls_or_err is the accumulated tool_call table
        UIManager:close(streamDialog)
        return true, content, tool_calls_or_err  -- third value carries tool call data
    else
        -- Normal text response; tool_calls_or_err may be a trailing error string or nil
        err = tool_calls_or_err
    end
    UIManager:close(streamDialog)

    if self.user_interrupted then
        return nil, _("Request cancelled by user.")
    end
    if err then
        return nil, err:gsub("^[\n%s]*", "") -- clean leading spaces and newlines
    end

    return true, content
end

--- func description: run the stream request in the background 
--  and process the response in realtime, output to the trunk callback
-- return the full response content when the stream ends
function Querier:processStream(bgQuery, trunk_callback)
    local pid, parent_read_fd = ffiutil.runInSubProcess(bgQuery, true) -- pipe: true

    if not pid then
        logger.warn("Failed to start background query process.")
        return nil, _("Failed to start subprocess for request")
    end

    local _coroutine = coroutine.running()  
  
    self.interrupt_stream = function()  
        coroutine.resume(_coroutine, false)  
    end  
  
    local tool_calls   -- set to the accumulated array when LLM issues tool calls
    local tool_call_acc = { current = {}, tools = {} }  -- persistent accumulator: { current={...}, tools={...} }
    local non200_start -- byte offset in result_buffer when non-200 line was received
    local check_interval_sec = 0.125 -- loop check interval: 125ms  
    local chunksize = 1024 * 16 -- buffer size for reading data
    local completed = false   -- Flag to indicate if the reading is completed
    local partial_data = strbuf.new(chunksize) -- Buffer for incomplete line data
    local result_buffer = strbuf.new()  -- Buffer for storing results
    local reasoning_content_buffer = strbuf.new()  -- Buffer for storing reasoning content

    while true do  

        if completed then break end
  
        -- Schedule next check and yield control  
        local go_on_func = function() coroutine.resume(_coroutine, true) end  
        UIManager:scheduleIn(check_interval_sec, go_on_func)  
        local go_on = coroutine.yield()  -- Wait for the next check or user interruption
        if not go_on then -- User interruption  
            self.user_interrupted = true
            logger.info("User interrupted the stream processing")
            UIManager:unschedule(go_on_func)  
            break  
        end  

        local readsize = ffiutil.getNonBlockingReadSize(parent_read_fd) 
        if readsize > 0 then
            -- Reserve space inside partial_data directly, read into it, then commit
            local ptr, _ = partial_data:reserve(chunksize)
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, ptr, chunksize))
            if bytes_read < 0 then
                local err = ffi.errno()
                logger.warn("readAllFromFD() error: " .. ffi.string(ffi.C.strerror(err)))
                break
            elseif bytes_read == 0 then -- EOF, no more data to read
                completed = true
                break
            else
                partial_data:commit(bytes_read)

                -- Process complete lines
                while true do
                    -- Serialize once per iteration to scan for newline
                    local pd_str = partial_data:tostring()
                    local line_end = pd_str:find("[\r\n]")
                    if not line_end then break end  -- No complete line yet, continue reading

                    -- Extract the complete line; advance past it with skip()
                    local line = pd_str:sub(1, line_end - 1)
                    partial_data:skip(line_end)
                    
                    -- Check if this is an Server-Sent-Event (SSE) data line
                    if line:sub(1, 6) == "data: " then
                        -- Clean up the JSON string (remove "data:" prefix and trim whitespace)
                        local json_str = koutil.trim(line:sub(7))
                        if json_str == '[DONE]' then break end -- end of SSE stream

                        -- Safely parse the JSON
                        local ok, event = pcall(rapidjson.decode, json_str)
                        if ok and event then
                            local signal = self:processChunk(event, trunk_callback, result_buffer, reasoning_content_buffer, tool_call_acc)
                            if signal == "TOOLCALLS" then
                                -- Normalize tool calls: merge arguments_parts into arguments
                                tool_calls = {}
                                for _, tc in ipairs(tool_call_acc.tools) do
                                    table.insert(tool_calls, normalizeToolCall(tc))
                                end
                                break
                            end
                        else
                            logger.warn("Failed to parse JSON from SSE data:", json_str)
                        end
                    elseif line:sub(1, 7) == "event: " then
                        -- Ignore SSE event lines (from Anthropic)
                    elseif line:sub(1, 1) == ":" then
                        -- SSE empty events, nothing to do
                    elseif line:sub(1, 1) == "{" then
                        -- If the line starts with '{', it might be a JSON object
                        local ok, j = pcall(rapidjson.decode, line, {null=nil})
                        if ok and j then
                            -- log the json
                            local err_message = koutil.tableGetValue(j, "error", "message")
                            if err_message then
                                result_buffer:put(err_message)
                            end

                            if trunk_callback then
                                trunk_callback(line)  -- Output to trunk callback
                                logger.info("JSON object received:", line)
                            end
                        else
                            -- the json was breaked into lines, just log the raw line
                            result_buffer:put(line)  -- Add the raw line to the result
                        end
                    elseif line:sub(1, #(self.handler.PROTOCOL_NON_200)) == self.handler.PROTOCOL_NON_200 then
                        -- child writes a non-200 response; record the current buffer length as the
                        -- start offset so we can slice the error body precisely later
                        non200_start = #result_buffer:tostring()
                        result_buffer:put(line:sub(#(self.handler.PROTOCOL_NON_200)+1))
                        break -- the request is done, no more data to read
                    else
                        if #koutil.trim(line) > 0 then
                            result_buffer:put(line)  -- Add the raw line to the result
                            -- logger.warn("Unrecognized line format:", line)
                        end
                    end
                end
            end
        elseif readsize == 0 then
            -- No data to read, check if subprocess is done
            completed = ffiutil.isSubProcessDone(pid)
        else
            -- Error reading from the file descriptor
            local err = ffi.errno()
            logger.warn("Error reading from parent_read_fd:", err, ffi.string(ffi.C.strerror(err)))
            break
        end
    end

    ffiutil.terminateSubProcess(pid) -- Terminate the subprocess when user interrupted 
    self.interrupt_stream = nil  -- Clear the interrupt function

    -- read loop ended, clean up subprocess
    local collect_interval_sec = 5 -- collect cancelled cmd every 5 second, no hurry
    local collect_and_clean
    collect_and_clean = function()
        if ffiutil.isSubProcessDone(pid) then
            if parent_read_fd then
                ffiutil.readAllFromFD(parent_read_fd) -- close it
            end
            logger.dbg("collected previously dismissed subprocess")
        else
            if parent_read_fd and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0 then
                -- If subprocess started outputting to fd, read from it,
                -- so its write() stops blocking and subprocess can exit
                ffiutil.readAllFromFD(parent_read_fd)
                -- We closed our fd, don't try again to read or close it
                parent_read_fd = nil
            end
            -- reschedule to collect it
            UIManager:scheduleIn(collect_interval_sec, collect_and_clean)
            logger.dbg("previously dismissed subprocess not yet collectable")
        end
    end
    UIManager:scheduleIn(collect_interval_sec, collect_and_clean)

    local ret = koutil.trim(result_buffer:tostring())
    if non200_start then
        -- Slice out only the error body before the non-200 mark
        local err_body = koutil.trim(ret:sub(1, non200_start))
        -- Try to parse the JSON and extract a human-readable message
        if err_body:sub(1, 1) == '{' then
            local ok, j = pcall(rapidjson.decode, err_body)
            if ok then
                local err = koutil.tableGetValue(j, "error", "message") or -- OpenAI / Anthropic / Gemini
                      koutil.tableGetValue(j, "message") -- Mistral / Cohere
                if err then return nil, err end
            end
        end
        -- return the raw error body as error message
        return nil, ret
    end

    if tool_calls then
        local tc_content = {
            reasoning_key = tool_call_acc.reasoning_key, -- openai dialets
            signature = tool_call_acc.signature,         -- anthropic signatures
        }
        if #reasoning_content_buffer > 0 then
            tc_content.reasoning_content = reasoning_content_buffer:tostring()
        end
        if #result_buffer > 0 then
            tc_content.content = result_buffer:tostring()
        end
        return tc_content, tool_calls
    end

    local show_reasoning = self.settings:readSetting("show_reasoning", false)
    local is_reasoning_in_ret = ret:sub(1, 7) == "<think>"

    if show_reasoning then
        local reasoning = reasoning_content_buffer:tostring():gsub("^%.+", "", 1):gsub("\n", "<br>")
        if #reasoning > 0 then
            ret = T('#### %1\n\n<div class="reasoningtext">%2</div>\n\n---\n\n', _("Deeply Thought"), reasoning) .. ret
        elseif is_reasoning_in_ret then
            ret = ret
                :gsub("<think>",  T("#### %1\n\n<pre>", _("Deeply Thought")), 1)
                :gsub("</think>", "</pre>\n\n---\n\n", 1)
        end
    elseif is_reasoning_in_ret then
        local close_pos = ret:find("</think>", 8, true)  -- plain=true
        if close_pos then
            ret = ret:sub(close_pos + 8):gsub("^%s+", "", 1)
        end
    end
    return ret, nil
end

--- processChunk: parse one SSE event and update the running buffers.
---
--- @param event              table   decoded JSON of one SSE chunk
--- @param trunk_callback     func    called with each new text fragment (may be nil)
--- @param result_buffer      strbuf  accumulates final answer text
--- @param reasoning_content_buffer strbuf  accumulates reasoning/thinking text
--- @param tool_call_acc      table   mutable state containing:
---                                   { current={id, name, arguments_parts[]}, tools=[] }
---                                   - current: the tool_call being accumulated in this chunk stream
---                                   - tools: array of completed tool_calls
---                                   caller must pre-init as { current={}, tools={} } before the first chunk.
--- @return string|nil  "TOOLCALLS" when the model has finished issuing a tool call,
---                     nil otherwise.
function Querier:processChunk(event, trunk_callback, result_buffer, reasoning_content_buffer, tool_call_acc)

    local reasoning_content, reasoning_key, result_content, stop_reason

    local choices    = event.choices
    local candidates = event.candidates
    local anthropic_type = event.type

    -- 1. OpenAI-compatible handles (openai / groq / openrouter / deepseek / mistral …)
    if choices then
        for _, choice in ipairs(choices) do
            stop_reason = json_default(choice.finish_reason)
            local cdelta = choice.delta
            if cdelta then
                -- Accumulate tool_calls deltas: arguments arrive in pieces across chunks.
                local tc_deltas = json_default(cdelta.tool_calls)
                if tc_deltas then
                    for _, tc in ipairs(tc_deltas) do
                        -- New tool_call encountered: if current has a different index, push it and start fresh
                        if tool_call_acc.current.index and tool_call_acc.current.index ~= tc.index then
                            table.insert(tool_call_acc.tools, tool_call_acc.current)
                            tool_call_acc.current = {}
                        end
                        local fn = json_default(tc["function"])
                        if fn then
                            -- id / function name arrive only in the first delta for this call
                            if json_default(fn.name) then
                                tool_call_acc.current = { name = fn.name, id = tc.id, index = tc.index, }
                            end
                            if json_default(fn.arguments) then
                                if not tool_call_acc.current.arguments_parts then
                                    tool_call_acc.current.arguments_parts = strbuf.new()
                                end
                                tool_call_acc.current.arguments_parts:put(fn.arguments)
                            end
                        end
                    end
                    return nil
                end

                result_content    = json_default(cdelta.content, "")
                if not reasoning_key then
                    -- find the key starts with "reason", "reasoning/reasoning_content/reasoning_details"
                    for k, _ in pairs(cdelta) do if k:sub(1, 6) == "reason" then reasoning_key = k break end end
                end
                reasoning_content = json_default(cdelta[reasoning_key], "")
            end
        end

    -- 2. Gemini handles
    elseif candidates then
        stop_reason = json_default(candidates[1].finishReason)
        local parts = koutil.tableGetValue(candidates, 1, "content", "parts") or {}
        for _, part in ipairs(parts) do
            if part.text then
                if json_default(part.thought) then
                    reasoning_content = part.text
                else
                    result_content = part.text
                end
            end
            -- Gemini delivers a complete functionCall object in a single part
            local fc = json_default(part.functionCall)
            if fc then
                -- Push current if any, then create new one for Gemini
                if tool_call_acc.current.id then
                    table.insert(tool_call_acc.tools, tool_call_acc.current)
                end
                tool_call_acc.current = {
                    id = json_default(fc.id) or json_default(fc.name) or "fc_0",
                    name = json_default(fc.name) or "web_search",
                    args = json_default(fc.args) or {}
                }
                stop_reason = "tool_calls"
            end
        end

    -- 3. Anthropic handles
    elseif anthropic_type then
        if anthropic_type == "content_block_start" then
            local cb = json_default(event.content_block)
            if cb.type == "tool_use" then
                if not (tool_call_acc.current and tool_call_acc.current.id) then
                    tool_call_acc.current = { id = cb.id, name = cb.name, index = event.index }
                end
            end
            return
        elseif anthropic_type == "content_block_delta" then
            local delta = event.delta
            if delta.type == "text_delta" then
                result_content    = json_default(delta.text, "")
            elseif delta.type == "thinking_delta" then
                reasoning_content = json_default(delta.thinking, "")
            elseif delta.type == "input_json_delta" then
                if not tool_call_acc.current.arguments_parts then
                    tool_call_acc.current.arguments_parts = strbuf.new()
                end
                tool_call_acc.current.arguments_parts:put(delta.partial_json)
                return
            elseif delta.type == "signature_delta" then
                tool_call_acc.signature = delta.signature
                return
            end
        elseif anthropic_type == "content_block_stop" then
            if tool_call_acc.current and tool_call_acc.current.index == event.index then
                table.insert(tool_call_acc.tools, tool_call_acc.current)
                tool_call_acc.current = nil
            end
            return
        elseif anthropic_type == "message_delta" then
            stop_reason = event.delta.stop_reason
        elseif anthropic_type == "message_stop" or
               anthropic_type == "message_start" or
               anthropic_type == "ping" then
            return
        end
    end

    -- Flush text content to buffers / UI
    if type(result_content) == "string" and #result_content > 0 then
        result_buffer:put(result_content)
        if trunk_callback then trunk_callback(result_content, result_buffer) end
    elseif type(reasoning_content) == "string" and #reasoning_content > 0 then
        reasoning_content_buffer:put(reasoning_content)
        if trunk_callback then trunk_callback(reasoning_content, reasoning_content_buffer) end
    elseif type(stop_reason) == "string" then
        local prefix = stop_reason:sub(1, 3):lower()
        if prefix ~= "too" and              -- tool_call/tool_use
            prefix ~= "sto" and             -- stop
            prefix ~= "end" then            -- end_turn
            result_buffer:put(_("Stopped Reason: "))
            result_buffer:put(stop_reason) -- log the abnormal stop reason
        end

        -- Return TOOLCALLS signal if this chunk completed a tool call
        if prefix == "too" then
            if tool_call_acc.current and tool_call_acc.current.id then
                table.insert(tool_call_acc.tools, tool_call_acc.current)
            end
            if reasoning_key then
                tool_call_acc.reasoning_key = reasoning_key
            end
            return "TOOLCALLS"
        end
    end
    if not (result_content == nil or reasoning_content == nil or stop_reason == nil or
        choices == nil or candidates == nil or anthropic_type == nil) then
        logger.warn("Unexpected JSON:", event)
    end
end

return Querier