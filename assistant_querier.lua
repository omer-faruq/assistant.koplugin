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
local Screen = Device.screen

local API_HANDLERS = {}


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
    provider_settings = nil,
    provider_name = nil,
    interrupt_stream = nil,      -- function to interrupt the stream query
    user_interrupted = false,  -- flag to indicate if the stream was interrupted
}

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
    local provider_settings = koutil.tableGetValue(CONFIGURATION, "provider_settings", provider_name)
    if not provider_settings then
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
        self.provider_settings = {}
        for k, v in pairs(provider_settings) do
            self.provider_settings[k] = v
        end
        self.provider_settings.serpapi = serpapi
        self.provider_settings.tavilyapi = tavilyapi
        self.provider_name = provider_name
        -- Apply saved OpenRouter model override
        if handler_name == "openrouter" then
            local saved_model = self.settings:readSetting("openrouter_model_" .. provider_name)
            if saved_model and saved_model ~= "" then
                self.provider_settings.model = saved_model
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
    self.for_measurement_only = true                -- trick the method from super class
    InputText.initTextBox(self, text, char_added)   -- skips `UIManager:setDirty`
    -- use our own method of refresh, `fast` is suitable for stream responding 
    UIManager:setDirty(self.parent, function() return "fast", self.dimen end)
    self.for_measurement_only = false
end
function  StreamText:onCloseWidget()
    -- fast mode makes screen dirty, clean it with `flashui`
    UIManager:setDirty(self.parent, function() return "flashui", self.dimen end)
    return InputText.onCloseWidget(self)
end

function Querier:showError(err)
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

local function trimMessageHistory(message_history)
    local trimed_history = {}
    for i, message in ipairs(message_history) do
        trimed_history[i] = { role = message.role, content = message.content, }
    end
    return trimed_history
end

--- Query the AI with the provided message history
--- return: answer, error (if any)
function Querier:query(message_history, title)
    if not self:is_inited() then
        return nil, _("Plugin is not configured.")
    end

    local prompt_websearch = message_history[#message_history].use_websearch or false
    local user_setting_websearch = self.settings:readSetting("use_websearch", "none")
    local query_option = {
        use_stream_mode = self.settings:readSetting("use_stream_mode", true),
        use_websearch = (prompt_websearch and user_setting_websearch ~= "none") and user_setting_websearch or "none"
    }

    local notify = string.format("%s\n️☁️ %s\n⚡ %s", title or _("Querying AI ..."),
        self.provider_name, koutil.tableGetValue(self.provider_settings, "model"))

    if query_option.use_websearch ~= "none" then
        notify = notify .. "\n" .. _("With Search: ") .. query_option.use_websearch 
    end
    local infomsg = InfoMessage:new{ icon = "book.opened", text = notify }

    UIManager:show(infomsg)

    self.handler:setTrapWidget(infomsg)
    local res, err = self.handler:query(trimMessageHistory(message_history), self.provider_settings, query_option)
    UIManager:close(self.handler:resetTrapWidget()) --  the widget may not be the same as infomsg

    -- when res is a function, it means we are in streaming mode
    -- open a stream dialog and run the background query in a subprocess
    if type(res) == "function" then
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
            title = (query_option.use_websearch and " 🌐 " or "") .. _("AI is responding") ,
            description = T("☁ %1/%2 %3", self.provider_name, self.provider_settings.model, (query_option.use_websearch or "")),
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
        local ok, content, err = pcall(self.processStream, self, res, function (content, buffer)
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
        if not ok then
            logger.warn("Error processing stream: " .. tostring(content))
            err = content -- content contains the error message
        end

        UIManager:close(streamDialog)

        if self.user_interrupted then
            return nil, _("Request cancelled by user.")
        end

        if err then
            return nil, err:gsub("^[\n%s]*", "") -- clean leading spaces and newlines
        end

        res = content
    end

    if err == self.handler.CODE_CANCELLED then
        self.user_interrupted = true
        return nil, _("Request cancelled by user.")
    end

    if type(res) ~= "string" or err ~= nil then
        return nil, tostring(err)
    elseif #res == 0 then
        return nil, _("No response received.") .. (err and tostring(err) or "")
    end
    return res
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
  
    local non200 = false -- flag to indicate if we received a non-200 response
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
                            self:processChunk(event, trunk_callback, result_buffer, reasoning_content_buffer)
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
                        -- child writes a non-200 response 
                        non200 = true
                        result_buffer:put("\n\n" .. line:sub(#(self.handler.PROTOCOL_NON_200)+1))
                        break -- the request is done, no more data to read
                    else
                        if #koutil.trim(line) > 0 then
                            -- If the line is not empty, log it as a warning
                            result_buffer:put(line)  -- Add the raw line to the result
                            logger.warn("Unrecognized line format:", line)
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
    if non200 then
        local err = _("API Error: ")

        -- try to parse the json, returns only message from the API.
        if ret:sub(1, 1) == '{' then
            local endPos = ret:reverse():find("}") -- find the last '}'
            if endPos and endPos > 0 then
                local ok, j = pcall(rapidjson.decode, ret:sub(1, #ret - endPos + 1))
                if ok then
                    err = koutil.tableGetValue(j, "error", "message") or -- OpenAI / Anthropic / Gemini 
                          koutil.tableGetValue(j, "message") -- Mistral / Cohere
                else
                    err = err .. ret
                end
            end
        end

        -- return all received content as error message
        return nil, err
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

function Querier:processChunk(event, trunk_callback, result_buffer, reasoning_content_buffer)
    
    local reasoning_content, result_content, stop_reason

    local choices    = event.choices
    local candidates = event.candidates
    local delta      = event.delta

    -- 1. OpenAI Handles
    if choices then
        for _, choice in ipairs(choices) do
            stop_reason = json_default(choice.finish_reason)
            local cdelta = choice.delta
            if cdelta then
                reasoning_content = json_default(cdelta.reasoning) or json_default(cdelta.reasoning_content, "")
                result_content = json_default(cdelta.content, "")
            end
            -- reasoning responses without text(grok-4)
            if not result_content and not reasoning_content then reasoning_content = "." end
        end

    -- 2. Gemini Handles
    elseif candidates then
        stop_reason = json_default(candidates[1].finishReason)
        for _, part in ipairs(koutil.tableGetValue(candidates, 1, "content", "parts")) do
            if part.text then
                if json_default(part.thought) then
                    reasoning_content = (reasoning_content or "") .. part.text
                else
                    result_content = (result_content or "") .. part.text
                end
            end
        end

    -- 3. Anthropic Handles
    elseif delta then
        result_content = json_default(delta.text, "")
        reasoning_content = json_default(delta.thinking, "")
        stop_reason = json_default(event.stop_reason)
    end 

    if type(result_content) == "string" and #result_content > 0 then
        result_buffer:put(result_content)
        if trunk_callback then trunk_callback(result_content, result_buffer) end
    elseif type(reasoning_content) == "string" and #reasoning_content > 0 then
        reasoning_content_buffer:put(reasoning_content)
        if trunk_callback then trunk_callback(reasoning_content, reasoning_content_buffer) end
    elseif type(stop_reason) == "string" and stop_reason:lower() ~= "stop" then
        -- logger.warn("abnormal stop:", stop_reason)
        result_buffer:put(_("Stopped Reason: ") .. stop_reason)
    else
        if result_content or reasoning_content or stop_reason then
            if choices or candidates or delta then
                -- reconized struct, but nothing needed (stream ended)
                -- logger.info("Unprocessed JSON:", json_str)
                return
            end
            logger.warn("Unexpected JSON:", event)
        end
        logger.warn("PROBLEM JSON:", event)
    end

    -- Genmini Last Chunk
    if candidates and stop_reason then
        local groundingMetadata = candidates[1].groundingMetadata
        if groundingMetadata then
            if groundingMetadata.webSearchQueries then
                -- Adds websearch_footer
                local items = {}
                for i, q in ipairs(groundingMetadata.webSearchQueries) do
                    items[i] = string.format("<u>%s</u>", q)
                end
                local webquery_footer = "\n\n" .. _("#### Search Keywords") .. '\n<ul class="subtext"><li>' .. 
                        table.concat(items, '</li><li>') .. '</li></ul>\n\n'
                result_buffer:put(webquery_footer)
            end
        end

        -- Add usage footer
        if event.usageMetadata and event.modelVersion then
            local usage_footer = T('<div class="subtext" style="margin-top: 1.5em;">%1: %2 (%3)</div>', _("Token Usage"),
                            event.usageMetadata.totalTokenCount, event.modelVersion)
            result_buffer:put(usage_footer)
        end
    end
end

return Querier