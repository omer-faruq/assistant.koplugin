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
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local Device = require("device")
local Screen = Device.screen

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
    return o
end

function Querier:is_inited()
    return self.handler ~= nil
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
        self.provider_settings = provider_settings
        self.provider_name = provider_name
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
    local frames = { ".", " .", "  .", "   .", "  .", " ." }
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

    local use_stream_mode = self.settings:readSetting("use_stream_mode", true)
    koutil.tableSetValue(self.provider_settings, use_stream_mode, "additional_parameters", "stream")

    -- Set up waiting animation for non-streaming mode
    local animation = createWaitingAnimation()
    local animation_task = nil
    local response_received = false

    local infomsg = InfoMessage:new{
      icon = "book.opened",
      text = string.format("%s\n️☁️ %s\n⚡ %s", title or _("Querying AI ..."), self.provider_name,
            koutil.tableGetValue(self.provider_settings, "model")),
    }

    UIManager:show(infomsg)

    -- Start animation for non-streaming mode
    local initial_text = infomsg.text
    local function updateInfoMessage()
        if not response_received then
            infomsg.text = initial_text .. "\n" .. animation:getNextFrame()
            UIManager:setDirty(infomsg)
            animation_task = UIManager:scheduleIn(0.4, updateInfoMessage)
        end
    end
    animation_task = UIManager:scheduleIn(0.4, updateInfoMessage)

    self.handler:setTrapWidget(infomsg)
    local res, err = self.handler:query(trimMessageHistory(message_history), self.provider_settings)
    self.handler:resetTrapWidget()

    -- Stop animation
    response_received = true
    if animation_task then
        UIManager:unschedule(animation_task)
        animation_task = nil
    end

    UIManager:close(infomsg)

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
            title = _("AI is responding"),
            description = T("☁ %1/%2", self.provider_name, koutil.tableGetValue(self.provider_settings, "model")),
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
                        streamDialog._input_widget:setText(table.concat(buffer or {}), true)
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
    local buffer = ffi.new('char[?]', chunksize, {0}) -- Buffer for reading data
    local buffer_ptr = ffi.cast('void*', buffer)
    local completed = false   -- Flag to indicate if the reading is completed
    local partial_data = ""   -- Buffer for incomplete line data
    local result_buffer = {}  -- Buffer for storing results
    local reasoning_content_buffer = {}  -- Buffer for storing results

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
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer_ptr, chunksize))
            if bytes_read < 0 then
                local err = ffi.errno()
                logger.warn("readAllFromFD() error: " .. ffi.string(ffi.C.strerror(err)))
                break
            elseif bytes_read == 0 then -- EOF, no more data to read
                completed = true
                break
            else
                -- Convert binary data to string and append to partial buffer
                local data_chunk = ffi.string(buffer, bytes_read)
                partial_data = partial_data .. data_chunk
                
                -- Process complete lines
                while true do
                    -- Find the next newline character
                    local line_end = partial_data:find("[\r\n]")
                    if not line_end then break end  -- No complete line yet, continue reading
                    
                    -- Extract the complete line
                    local line = partial_data:sub(1, line_end - 1)
                    partial_data = partial_data:sub(line_end + 1)
                    
                    -- Check if this is an Server-Sent-Event (SSE) data line
                    if line:sub(1, 6) == "data: " then
                        -- Clean up the JSON string (remove "data:" prefix and trim whitespace)
                        local json_str = koutil.trim(line:sub(7))
                        if json_str == '[DONE]' then break end -- end of SSE stream

                        -- Safely parse the JSON
                        local ok, event = pcall(rapidjson.decode, json_str, {null = nil})
                        if ok and event then
                        
                            local reasoning_content, content

                            local choice = koutil.tableGetValue(event, "choices", 1)
                            if choice then -- OpenAI (compatiable) API
                                if koutil.tableGetValue(choice, "finish_reason") then content="\n" end
                                local delta = koutil.tableGetValue(choice, "delta")
                                if delta then
                                    reasoning_content = koutil.tableGetValue(delta, "reasoning_content")
                                    content = koutil.tableGetValue(delta, "content")
                                    -- gork4 ouputs empty reasoning messages, logs '.' here to indicate the process works
                                    if not content and not reasoning_content then reasoning_content = "." end
                                end
                            else
                                content =
                                    koutil.tableGetValue(event, "candidates", 1, "content", "parts", 1, "text") or  -- Genmini API
                                    koutil.tableGetValue(event, "delta", "text") or   -- Anthropic streaming (content_block_delta)
                                    koutil.tableGetValue(event, "content", 1, "text") -- Anthropic non-stream message event
                            end
                                
                            if type(content) == "string" and #content > 0 then
                                table.insert(result_buffer, content)
                                if trunk_callback then trunk_callback(content, result_buffer) end
                            elseif type(reasoning_content) == "string" and #reasoning_content > 0 then
                                table.insert(reasoning_content_buffer, reasoning_content)
                                if trunk_callback then trunk_callback(reasoning_content, reasoning_content_buffer) end
                            elseif content == nil and reasoning_content == nil then
                                logger.warn("Unexpected SSE data:", json_str)
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
                                table.insert(result_buffer, err_message)
                            end

                            if trunk_callback then
                                trunk_callback(line)  -- Output to trunk callback
                                logger.info("JSON object received:", line)
                            end
                        else
                            -- the json was breaked into lines, just log the raw line
                            table.insert(result_buffer, line)  -- Add the raw line to the result
                        end
                    elseif line:sub(1, #(self.handler.PROTOCOL_NON_200)) == self.handler.PROTOCOL_NON_200 then
                        -- child writes a non-200 response 
                        non200 = true
                        table.insert(result_buffer, "\n\n" .. line:sub(#(self.handler.PROTOCOL_NON_200)+1))
                        break -- the request is done, no more data to read
                    else
                        if #koutil.trim(line) > 0 then
                            -- If the line is not empty, log it as a warning
                            table.insert(result_buffer, line)  -- Add the raw line to the result
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

    local ret = koutil.trim(table.concat(result_buffer))
    if non200 then
        -- try to parse the json, returns only message from the API.
        if ret:sub(1, 1) == '{' then
            local endPos = ret:reverse():find("}")
            if endPos and endPos > 0 then
                local ok, j = pcall(rapidjson.decode, ret:sub(1, #ret - endPos + 1), {null=nil})
                if ok then
                    local err
                    err = koutil.tableGetValue(j, "error", "message") -- OpenAI / Anthropic / Gemini 
                    if err then return nil, err end
                    err = koutil.tableGetValue(j, "message") -- Mistral / Cohere
                    if err then return nil, err end
                end
            end
        end

        -- return all received content as error message
        return nil, ret
    else
        local reasoning = table.concat(reasoning_content_buffer):gsub("^%.+", "", 1)
        if #reasoning > 0 then
            ret = T("<dl><dt>%1</dt><dd>%2</dd></dl>\n\n%3", _("Deeply Thought"), reasoning, ret)
        elseif ret:sub(1, 7) == "<think>" then
            ret = ret:gsub("<think>", T("<dl><dt>%1</dt><dd>", _("Deeply Thought")), 1):gsub("</think>", "</dd></dl>", 1)
        end
    end
    return ret, nil
end

return Querier