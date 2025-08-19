--- Querier module for handling AI queries with dynamic provider loading
local _ = require("owngettext")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local InputText = require("ui/widget/inputtext")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local koutil = require("util")
local logger = require("logger")
local json = require("json")
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
    stream_interrupted = false,  -- flag to indicate if the stream was interrupted
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

--- Initialize the Querier with the provider settings and handler
--- This function checks the CONFIGURATION for the provider and loads the appropriate handler.
--- return: nil on success, or an error message if initialization fails.
function Querier:init(provider_name)

    local CONFIGURATION = self.assistant.CONFIGURATION

    if CONFIGURATION and CONFIGURATION.provider_settings then

        --- Check if the provider is set in the configuration
        if CONFIGURATION.provider_settings and CONFIGURATION.provider_settings[provider_name] then
            self.provider_settings = CONFIGURATION.provider_settings[provider_name]
        else
            return string.format(
                _("Provider settings not found for: %s. Please check your configuration.lua file."),
                provider_name)
        end

        self.provider_name = provider_name

        local underscore_pos = self.provider_name:find("_")
        if underscore_pos then
            -- Extract the substring before the first underscore as the handler name
            self.handler_name = self.provider_name:sub(1, underscore_pos - 1)
        else
            self.handler_name = self.provider_name
        end

        --- Load the handler based on the provider name
        local success, handler = pcall(function()
            return require("api_handlers." .. self.handler_name)
        end)
        if success then
            self.handler = handler
        else
            return string.format(
                _("The handler for %s was not found. Please ensure the handler exists in api_handlers directory."),
                self.handler_name)
        end
    else
        return string.format(
            _("No provider set in configuration.lua. Please set the provider and provider_settings for %s."),
            provider_name)
    end
end

--- Load provider model for the Querier
function Querier:load_model(provider_name)
    -- If the provider name is different or not initialized, reinitialize
    if provider_name ~= self.provider_name or not self:is_inited() then
        local err = self:init(provider_name)
        if err then
            logger.warn("Querier initialization failed: " .. err)
            return false, err
        end
    end
    return true
end

-- InputText class for showing streaming responses
-- ignores all input events
local StreamText = InputText:extend{}
function StreamText:initInputEvents() end
function StreamText:initKeyboard() end
function StreamText:onKeyPress() end
function StreamText:onTextInput(text) end
function StreamText:onTapTextBox(arg, ges) return true end

--- Query the AI with the provided message history
--- return: answer, error (if any)
function Querier:query(message_history, title)
    if not self:is_inited() then
        return "", "Assistant: not configured."
    end

    if self.settings:readSetting("forced_stream_mode", true) then -- default true
        if not self.provider_settings.additional_parameters then
            self.provider_settings.additional_parameters = {}
        end
        self.provider_settings.additional_parameters["stream"] = true
    end

    self.stream_interrupted = false -- reset the stream interrupted flag

    local infomsg = InfoMessage:new{
      icon = "book.opened",
      text = string.format("%s\n️☁️ %s\n⚡ %s", title or _("Querying AI ..."),
            self.provider_name, self.provider_settings.model),
    }

    UIManager:show(infomsg)
    self.handler:setTrapWidget(infomsg)
    local res, err = self.handler:query(message_history, self.provider_settings)
    self.handler:resetTrapWidget()
    UIManager:close(infomsg)

    -- when res is a function, it means we are in streaming mode
    -- open a stream dialog and run the background query in a subprocess
    if type(res) == "function" then
        local streamDialog = InputDialog:new{
            face = Font:getFace("smallffont"),
            width = Screen:getWidth() - Screen:scaleBySize(30),
            title = _("AI is responding"),
            description = string.format(
                _("☁ %s/%s"), self.provider_name, self.provider_settings.model),
            inputtext_class = StreamText, -- use our custom InputText class
            title_bar_left_icon = "appbar.settings",
            title_bar_left_icon_tap_callback = function ()
                self.assistant:showSettings()
            end,

            readonly = false, skip_first_show_keyboard = true, keyboard_visible = false, fullscreen = false,
            allow_newline = true, add_nav_bar = false, cursor_at_end = true, add_scroll_buttons = true,
            deny_keyboard_hiding = false, use_available_height = true, condensed = true, auto_para_direction = true,
            buttons = {
                {
                    {
                        text = _("⏹ Stop"),
                        id = "close", -- id:close response to default cancel action (esc key ...)
                        callback = function()
                            if self.interrupt_stream then
                                self.interrupt_stream()
                            end
                        end,
                    },
                }
            }
        }
        UIManager:show(streamDialog)
        local content, err = self:processStream(res, function (content)
            UIManager:nextTick(function ()
                -- schedule the text update in the UIManager task queue
                streamDialog:addTextToInput(content)
            end)
        end)
        UIManager:close(streamDialog)

        if self.stream_interrupted then
            return nil, _("Response interrupted.")
        end

        if err then
            return nil, err
        end

        res = content
    end

    if #res == 0 then
        return nil, _("No response received.") .. (err and tostring(err) or "")
    elseif err ~= nil then
        return nil, tostring(err)
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

    while true do  

        if completed then break end
  
        -- Schedule next check and yield control  
        local go_on_func = function() coroutine.resume(_coroutine, true) end  
        UIManager:scheduleIn(check_interval_sec, go_on_func)  
        local go_on = coroutine.yield()  -- Wait for the next check or user interruption
        if not go_on then -- User interruption  
            self.stream_interrupted = true
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
                        local ok, event = pcall(json.decode, json_str)
                        if ok and event then
                        
                            local content
                            if event.choices and #event.choices > 0 and event.choices[1].delta then
                                -- openai API
                                content = event.choices[1].delta.content
                            elseif event.candidates and #event.candidates > 0 and event.candidates[1].content then 
                                -- gemini API
                                content = event.candidates[1].content.parts[1].text
                            elseif event.content and #event.content > 0 and event.content[1] then
                                -- Anthropic Claude (Messages API)
                                content = event.content[1].text
                            else
                                logger.warn("Unexpected event format:", json_str)
                                content = json_str
                            end
                                
                            if content then
                                table.insert(result_buffer, content)
                                if trunk_callback then
                                    trunk_callback(content)  -- Output to trunk callback
                                end
                            end
                        else
                            logger.warn("Failed to parse JSON from SSE data:", json_str)
                        end
                    elseif line:sub(1, 1) == "{" then
                        -- If the line starts with '{', it might be a JSON object
                        local ok, j = pcall(json.decode, line)
                        if ok then
                            -- log the json
                            if j.error and j.error.message then
                                table.insert(result_buffer, j.error.message)
                            end
                            if trunk_callback then
                                trunk_callback(line)  -- Output to trunk callback
                                logger.info("JSON object received:", line)
                            end
                        else
                            -- the json was breaked into lines, just log the raw line
                            table.insert(result_buffer, line)  -- Add the raw line to the result
                        end
                    elseif line:sub(1, 1) == ":" then
                        -- SSE empty events, nothing to do
                    elseif line:sub(1, #(self.handler.PROTOCAL_NON_200)) == self.handler.PROTOCAL_NON_200 then
                        -- child writes a non-200 response 
                        non200 = true
                        table.insert(result_buffer, "\n\n" .. line:sub(#(self.handler.PROTOCAL_NON_200)+1))
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

    local ret = table.concat(result_buffer)
    if non200 then
        -- return the result as error message
        return nil, ret
    end
    return ret, nil
end

return Querier