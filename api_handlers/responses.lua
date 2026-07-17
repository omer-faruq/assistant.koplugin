local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")
local ToolExecutor = require("assistant_tool_executor")
local ASUtils = require("assistant_utils")
local UIManager = require("ui/uimanager")
local _ = require("assistant_gettext")
local InfoMessage = require("ui/widget/infomessage")

-- Socket/HTTP modules for custom stream transformation
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local strbuf = require("string.buffer")

--- OpenAI Responses API handler.
--- Supports the /v1/responses endpoint with built-in web_search,
--- file_search, and function-calling tools.
---
--- Configuration key prefix: "responses" (e.g. responses_openai)
local ResponsesHandler = BaseHandler:new({
    name = "responses",
    can_fetch_models = true,
})

ResponsesHandler.SupportedOptions = {
    ["temperature"]          = true,
    ["top_p"]                = true,
    ["max_output_tokens"]    = true,
    ["max_tokens"]           = true,
    ["reasoning"]            = true,
    ["reasoning_effort"]     = true,
    ["store"]                = true,
}

function ResponsesHandler:SyncOptions(querier)
    BaseHandler.SyncOptions(self, querier)
    -- Normalize base_url: strip trailing /responses if present, we'll append it
    self.responses_url = self.base_url
    if not self.responses_url:match("/responses$") then
        self.responses_url = self.responses_url:gsub("/+$", "") .. "/responses"
    end
end

function ResponsesHandler:FetchModels()
    -- Use the standard /v1/models endpoint (same as Chat Completions)
    local model_url = self.base_url:gsub("/responses.*$", "/models")
    local infomsg = InfoMessage:new{
        text = _("Fetching models..."),
    }
    UIManager:show(infomsg)
    local models, err = ASUtils.fetchJSON(model_url, {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. self.api_key,
    }, infomsg)

    if err then return nil, err end
    if models and models.data then
        local model_list = models.data
        table.sort(model_list, function(a, b)
            return a.id < b.id
        end)
        return model_list, nil
    end
    return nil, _("Failed to fetch models")
end

-- ---------------------------------------------------------------------------
-- Error extraction helper
-- ---------------------------------------------------------------------------

--- Extract a human-readable error message from a decoded API response.
--- Handles common error shapes:
---   { error = { message = "..." } }  -- OpenAI/standard
---   { error = "..." }                -- flat string error
---   { message = "..." }              -- bare message
--- @param decoded table  json.decode result
--- @return string|nil  error message, or nil if no error found
local function extractErrorMessage(decoded)
    if type(decoded) ~= "table" then return nil end

    -- Nested error.message (OpenAI format)
    local err_msg = koutil.tableGetValue(decoded, "error", "message")
    if err_msg then return err_msg end

    -- Flat error string
    if type(decoded.error) == "string" and #decoded.error > 0 then
        return decoded.error
    end

    -- Bare message
    if type(decoded.message) == "string" and #decoded.message > 0 then
        return decoded.message
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Message conversion: OpenAI-format message_history → Responses API input
-- ---------------------------------------------------------------------------

--- Convert OpenAI-format message_history to Responses API input items + instructions.
--- The internal message_history uses standard OpenAI roles (system/user/assistant/tool).
--- We convert:
---   system    → instructions string (concatenated)
---   user      → { role = "user", content = "..." }
---   assistant (no tool_calls) → { role = "assistant", content = "..." }
---   assistant (with tool_calls) → { type = "function_call", call_id, name, arguments }
---   tool      → { type = "function_call_output", call_id, output }
--- @param messages table  OpenAI-format message_history
--- @return table input_items, string instructions
local function convertMessagesToInput(messages)
    local input_items = {}
    local instructions_parts = {}

    for _, msg in ipairs(messages) do
        if msg.role == "system" then
            table.insert(instructions_parts, msg.content)
        elseif msg.role == "user" then
            table.insert(input_items, {
                role    = "user",
                content = msg.content,
            })
        elseif msg.role == "assistant" then
            if msg.tool_calls and #msg.tool_calls > 0 then
                -- Convert each tool call to a function_call input item
                for _, tc in ipairs(msg.tool_calls) do
                    local call_id = tc.id
                    local fn_name = tc.name or (tc["function"] and tc["function"].name)
                    local fn_args = tc.arguments or (tc["function"] and tc["function"].arguments) or "{}"
                    table.insert(input_items, {
                        type      = "function_call",
                        call_id   = call_id,
                        name      = fn_name,
                        arguments = fn_args,
                    })
                end
            elseif msg.content and #msg.content > 0 then
                table.insert(input_items, {
                    role    = "assistant",
                    content = msg.content,
                })
            end
            -- Assistant messages with no content and no tool_calls are skipped
        elseif msg.role == "tool" then
            table.insert(input_items, {
                type    = "function_call_output",
                call_id = msg.tool_call_id,
                output  = msg.content or "",
            })
        else
            -- Fallback: treat as user message
            local content = msg.content
            if not content and msg.parts then
                -- Gemini-format message from augmented history; extract text
                local parts = {}
                for _, p in ipairs(msg.parts) do
                    if p.text then table.insert(parts, p.text) end
                    if p.functionResponse then
                        table.insert(input_items, {
                            type    = "function_call_output",
                            call_id = p.functionResponse.id or p.functionResponse.name,
                            output  = p.functionResponse.response and p.functionResponse.response.result or "",
                        })
                    end
                end
                if #parts > 0 then
                    content = table.concat(parts, "\n")
                end
            end
            if content and #content > 0 then
                table.insert(input_items, {
                    role    = "user",
                    content = content,
                })
            end
        end
    end

    local instructions = #instructions_parts > 0 and table.concat(instructions_parts, "\n\n") or nil
    return input_items, instructions
end

-- ---------------------------------------------------------------------------
-- Request body builder
-- ---------------------------------------------------------------------------

--- Build a JSON request body for the OpenAI Responses API.
--- @param messages  table   message history (OpenAI format)
--- @param query_option table query options
--- @param tools     table|nil  tool definitions
--- @return table requestBody
function ResponsesHandler:buildRequestBody(messages, query_option, tools)
    local input_items, instructions = convertMessagesToInput(messages)

    local body = {
        model = self.model,
        input = input_items,
    }

    if instructions then
        body.instructions = instructions
    end

    -- Apply additional_parameters (SupportedOptions filter)
    if type(self.additional_parameters) == "table" and next(self.additional_parameters) then
        for o, v in pairs(self.additional_parameters) do
            if self.SupportedOptions[o] then
                body[o] = v
            end
        end
    end

    -- Tools configuration
    if tools then
        body.tools = tools
        body.tool_choice = "auto"
    end

    if query_option.use_stream_mode then
        body.stream = true
    end

    return body
end

-- ---------------------------------------------------------------------------
-- Response parsing
-- ---------------------------------------------------------------------------

--- Extract text content from a Responses API output array.
--- Returns the concatenated text from all message-type output items.
--- @param output_items table  response.output array
--- @return string|nil text, table|nil tool_call_items
local function parseOutputItems(output_items)
    local text_parts = {}
    local tool_calls = {}

    for _, item in ipairs(output_items) do
        local item_type = item.type

        if item_type == "message" then
            -- Extract text from content blocks
            local content = item.content
            if type(content) == "table" then
                for _, block in ipairs(content) do
                    if block.type == "output_text" and block.text then
                        table.insert(text_parts, block.text)
                    end
                end
            elseif type(content) == "string" then
                table.insert(text_parts, content)
            end
        elseif item_type == "function_call" then
            table.insert(tool_calls, {
                tool_call_id = item.call_id,
                name         = item.name,
                arguments    = item.arguments or "{}",
            })
        end
    end

    local text = #text_parts > 0 and table.concat(text_parts, "\n\n") or nil
    return text, #tool_calls > 0 and tool_calls or nil
end

-- ---------------------------------------------------------------------------
-- Stream mode: custom backgroundRequest with SSE transformation
-- ---------------------------------------------------------------------------

--- Custom background request function that transforms Responses API SSE events
--- into Chat Completions SSE format that processChunk can parse.
--- @param url     string  The Responses API endpoint
--- @param headers table   HTTP request headers
--- @param body    string  JSON-encoded request body
--- @return function  Background function compatible with runInSubProcess
function ResponsesHandler:backgroundRequest(url, headers, body)

    return function(pid, child_write_fd)
        if not pid or not child_write_fd then
            logger.warn("ResponsesHandler: invalid parameters for background request")
            return
        end

        if url:sub(1, 5) == "https" then
            https.cert_verify = false
        end

        -- Track tool call accumulation state
        local tool_call_index = 0
        local pending_tool_calls = {}

        local function emitJSON(t)
            local s = "data: " .. json.encode(t) .. "\n\n"
            ffiutil.writeToFD(child_write_fd, s)
        end

        -- Make the HTTP request with a custom sink that processes chunks
        local buf = strbuf.new()
        -- Separate buffer for the full raw response body (never consumed by processLine).
        -- When the request fails with a non-200 status, the server returns plain JSON
        -- instead of SSE, and processLine silently drops non-"data:" lines.  We snapshot
        -- raw_body instead of buf so the error body is preserved for error reporting.
        local raw_body = strbuf.new()
        local function processLine(line)
            line = line:gsub("\r$", "")

            if line:sub(1, 6) == "data: " then
                local json_str = line:sub(7)
                if json_str == "[DONE]" then return false end

                local ok, event = pcall(json.decode, json_str)
                if ok and event then
                    local ev_type = event.type or ""

                    -- Transform output_text.delta → Chat Completions content delta
                    if ev_type == "response.output_text.delta" then
                        local delta = event.delta or ""
                        emitJSON({
                            id = "resp_stream",
                            object = "chat.completion.chunk",
                            choices = {{
                                index = 0,
                                delta = { content = delta },
                                finish_reason = nil,
                            }},
                        })
                    elseif ev_type == "response.output_text.done" then
                        -- nothing extra to emit

                    -- Transform function_call events → tool_calls in Chat Completions format
                    elseif ev_type == "response.output_item.added" then
                        local item = event.item
                        if item and item.type == "function_call" then
                            pending_tool_calls[item.id] = {
                                id = item.id,
                                call_id = item.call_id,
                                name = item.name,
                                arguments = "",
                            }
                        end
                    elseif ev_type == "response.function_call_arguments.delta" then
                        local item_id = event.item_id
                        local delta = event.delta or ""
                        if pending_tool_calls[item_id] then
                            pending_tool_calls[item_id].arguments =
                                pending_tool_calls[item_id].arguments .. delta
                        end
                    elseif ev_type == "response.function_call_arguments.done" then
                        local item_id = event.item_id
                        local pending = pending_tool_calls[item_id]
                        if pending then
                            if event.arguments then
                                pending.arguments = event.arguments
                            end
                            local tc_index = tool_call_index
                            tool_call_index = tool_call_index + 1
                            -- 1) Emit tool_call delta (accumulated by processChunk; early return)
                            emitJSON({
                                id = "resp_stream",
                                object = "chat.completion.chunk",
                                choices = {{
                                    index = 0,
                                    delta = {
                                        tool_calls = {{
                                            index = tc_index,
                                            id = pending.call_id or pending.id,
                                            type = "function",
                                            ["function"] = {
                                                name = pending.name,
                                                arguments = pending.arguments,
                                            },
                                        }},
                                    },
                                }},
                            })
                            -- 2) Emit a separate finish_reason chunk to trigger TOOLCALLS
                            emitJSON({
                                id = "resp_stream",
                                object = "chat.completion.chunk",
                                choices = {{
                                    index = 0,
                                    delta = {},
                                    finish_reason = "tool_calls",
                                }},
                            })
                            pending_tool_calls[item_id] = nil
                        end

                    -- Handle completed event: emit [DONE]
                    elseif ev_type == "response.completed" then
                        ffiutil.writeToFD(child_write_fd, "data: [DONE]\n\n")

                    -- Lifecycle events (no content to emit)
                    elseif ev_type == "response.created" then
                        -- Response created; no content to emit
                    elseif ev_type == "response.in_progress" then
                        -- Response generation in progress; no content to emit

                    -- Content part lifecycle (metadata only; deltas carry the actual text)
                    elseif ev_type == "response.content_part.added" then
                        -- Part metadata (type: output_text|refusal|reasoning_text).
                        -- Actual text arrives via output_text.delta or reasoning_text.delta.
                    elseif ev_type == "response.content_part.done" then
                        -- Content part completed; no content to emit

                    -- Reasoning text streaming (e.g. o-series models)
                    elseif ev_type == "response.reasoning_text.delta" then
                        local delta = event.delta or ""
                        emitJSON({
                            id = "resp_stream",
                            object = "chat.completion.chunk",
                            choices = {{
                                index = 0,
                                delta = { reasoning_content = delta },
                                finish_reason = nil,
                            }},
                        })
                    elseif ev_type == "response.reasoning_text.done" then
                        -- Reasoning text completed; no extra content to emit

                    -- Output item lifecycle
                    elseif ev_type == "response.output_item.done" then
                        -- Output item completed; no content to emit

                    else
                        logger.info("unprocessed", ev_type)
                    end
                end
            end
            -- Ignore event: lines (event type tracked via data line's type field)
            return true  -- continue processing
        end

        local function sink(chunk, err)
            -- logger.info("chunk", chunk)
            if chunk then
                -- Accumulate raw response for error reporting (never consumed)
                raw_body:put(chunk)
                -- Accumulate chunks into strbuf (avoids repeated table.concat string copies)
                buf:put(chunk)
                local full = buf:tostring()
                -- Find the last newline: keep unprocessed trailing data in the buffer
                local last_nl_pos = full:find("\n[^\r\n]*$") or 0
                if last_nl_pos > 0 then
                    -- Extract complete lines (everything up to and including last \n)
                    local complete = full:sub(1, last_nl_pos)
                    -- Advance strbuf read cursor past the processed bytes
                    buf:skip(last_nl_pos)

                    for line in complete:gmatch("[^\r\n]+") do
                        if not processLine(line) then break end
                    end
                end
            else
                -- End of stream: process any remaining data
                if #buf > 0 then
                    local remaining = buf:tostring()
                    if #remaining > 0 then
                        processLine(remaining)
                    end
                end
                -- [DONE] is emitted by the caller after http.request() returns,
                -- only on success.  Emitting it here in sink(nil) would race
                -- ahead of the error path: the frontend sees [DONE] and breaks
                -- before the X-NON-200-STATUS error line arrives.
            end
            return 1 -- return non-nil to continue
        end

        -- Use a simple function sink for incremental chunk processing
        local request = {
            url     = url,
            method  = "POST",
            headers = headers or {},
            source  = ltn12.source.string(body or ""),
            sink    = sink,
        }

        local code, resp_headers, status = socket.skip(1, http.request(request))

        -- Snapshot the full raw response body before sink(nil) flushes it.
        -- We use raw_body (not buf) because buf is consumed by processLine,
        -- which silently drops non-"data:" lines like plain JSON error bodies.
        local raw_body_snapshot = raw_body:tostring()


        if code ~= 200 then
            -- Error path: write the non-200 status marker followed by a JSON
            -- structure containing code, status, headers, and raw_body.
            -- Do NOT emit [DONE] — the frontend breaks on [DONE] and would
            -- never see the error line.
            logger.warn("ResponsesHandler background request non-200:",
                code, "status:", status, "url:", url, "body:", raw_body_snapshot)
            local err_struct = {
                code = code,
                resp_headers = resp_headers,
                status = status,
                raw_body = raw_body_snapshot,
            }
            ffiutil.writeToFD(child_write_fd, "\r\n")
            ffiutil.writeToFD(child_write_fd, self.PROTOCOL_NON_200)
            ffiutil.writeToFD(child_write_fd, json.encode(err_struct))
            ffiutil.writeToFD(child_write_fd, "\r\n")
        else
            -- Success path: flush any remaining buffered SSE data, then emit
            -- [DONE] so the frontend knows the stream is complete.
            sink(nil)
            ffiutil.writeToFD(child_write_fd, "data: [DONE]\n\n")
        end

        ffi.C.close(child_write_fd)
    end
end

-- ---------------------------------------------------------------------------
-- Main query method
-- ---------------------------------------------------------------------------

function ResponsesHandler:query(message_history, query_option)

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. self.api_key,
    }

    local ws_mode = query_option.use_websearch or "none"
    local tools

    -- Build tool definitions based on web search mode
    if ws_mode == "builtin" then
        -- Responses API native web_search tool — no external search needed
        tools = { { type = "web_search" } }
    elseif ToolExecutor.IsExtSearch(ws_mode) then
        -- External search via function calling — Responses API flattened format
        tools = { self:buildExternalSearchToolDef("responses") }
    end

    local body = self:buildRequestBody(message_history, query_option, tools)

    -- -----------------------------------------------------------------------
    -- STREAM path: return background function
    -- -----------------------------------------------------------------------
    if query_option.use_stream_mode then
        local requestBody = json.encode(body)
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(self.responses_url, headers, requestBody)
    end

    -- -----------------------------------------------------------------------
    -- NON-STREAM path
    -- -----------------------------------------------------------------------
    local requestBody = json.encode(body)
    local status, code, response = self:makeRequest(self.responses_url, headers, requestBody)

    if not status then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        -- Try to surface a structured error message from network-level failures
        if response and #response > 0 then
            local ok, rd = pcall(json.decode, response)
            if ok then
                local err_msg = extractErrorMessage(rd)
                if err_msg then
                    logger.warn(self.name, "HTTP", code, "error:", err_msg)
                    return nil, err_msg
                end
            end
        end
        logger.warn(self.name, "HTTP request failed:", code, "response:", response)
        return nil, "Error: " .. tostring(code or "unknown") .. " - " .. tostring(response)
    end

    local ok, responseData = pcall(json.decode, response)
    if not ok or not responseData then
        logger.warn(self.name, "failed to parse response:", response)
        return nil, "Error: failed to parse API response"
    end

    -- Check for API-level error (HTTP 4xx/5xx with JSON error body)
    local api_err = extractErrorMessage(responseData)
    if api_err then
        logger.warn(self.name, "API error (HTTP", code, "):", api_err, "| body:", response)
        return nil, api_err
    end

    -- Check for missing output (graceful fallback for unexpected response shape)
    if type(responseData.output) ~= "table" then
        logger.warn(self.name, "missing 'output' array in response (HTTP", code, "):", response)
        return nil, "Unexpected API response: missing output"
    end

    -- Extract text and tool calls from output array
    local text_content, tool_call_items = parseOutputItems(responseData.output)

    -- If no tool calls, return plain text
    if not tool_call_items then
        if text_content then
            return text_content, nil
        end
        logger.warn(self.name, "no content in output (HTTP", code, "):", response)
        return nil, "No content in API response"
    end

    -- Build raw_assistant in OpenAI format (for Querier tool-call loop compatibility)
    -- and return a tool_call descriptor
    local raw_tool_calls = {}
    for _, tc in ipairs(tool_call_items) do
        table.insert(raw_tool_calls, {
            id        = tc.tool_call_id,
            type      = "function",
            ["function"] = {
                name      = tc.name,
                arguments = tc.arguments,
            },
        })
    end

    local raw_assistant = {
        role       = "assistant",
        content    = text_content,
        tool_calls = raw_tool_calls,
    }

    return {
        __is_tool_call = true,
        raw_assistant  = raw_assistant,
        format         = "openai", -- use OpenAI format for message building
        tool_calls     = tool_call_items,
    }, nil
end

return ResponsesHandler
