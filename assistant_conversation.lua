-- assistant_conversation.lua
-- Unified conversation layer: session, turn policy, and query request.
--
-- Replaces the implicit "last message carries control state" protocol
-- with explicit TurnInput -> TurnPolicy -> QueryRequest flow.

local koutil = require("util")
local ASUtils = require("assistant_utils")
local Prompts = require("assistant_prompts")

local Conversation = {}

-- ===========================================================================
-- TurnInput: normalized input from any entry point
-- ===========================================================================

Conversation.TurnInput = {}
Conversation.TurnInput.__index = Conversation.TurnInput

---@param opts table
---@param opts.kind string "free" | "preset" | "feature"
---@param opts.origin string "typed" | "suggested" | "prompt_button"
---@param opts.text string The user question or expanded prompt
---@param opts.prompt_config table|nil Must be a copy, never the cached object
---@param opts.user_input string|nil
---@param opts.web_search_intent boolean|nil Whether this request wants search
function Conversation.TurnInput:new(opts)
    local self = setmetatable({}, Conversation.TurnInput)
    self.kind = opts.kind
    self.origin = opts.origin
    self.text = opts.text
    self.prompt_config = opts.prompt_config
    self.user_input = opts.user_input
    self.web_search_intent = opts.web_search_intent
    return self
end

-- ===========================================================================
-- TurnPolicy: request-level decisions, resolved once per turn
-- ===========================================================================

Conversation.TurnPolicy = {}
Conversation.TurnPolicy.__index = Conversation.TurnPolicy

---@param opts table
---@param opts.tool_requested boolean Whether user/prompt wants search
---@param opts.tool_mode string "none" | "builtin" | external search key
---@param opts.suggestions boolean Whether to show follow-up suggestions
---@param opts.context_mode string "none" | "reuse" | "refresh"
function Conversation.TurnPolicy:new(opts)
    local self = setmetatable({}, Conversation.TurnPolicy)
    self.tool_requested = opts.tool_requested
    self.tool_mode = opts.tool_mode
    self.suggestions = opts.suggestions
    self.context_mode = opts.context_mode
    return self
end

---Resolve a TurnPolicy from TurnInput and global settings.
---@param input Conversation.TurnInput
---@param settings table
---@param global_web_search string Global use_websearch setting value
---@return Conversation.TurnPolicy
function Conversation.TurnPolicy.resolve(input, settings, global_web_search)
    local tool_requested = false
    if input.web_search_intent ~= nil then
        tool_requested = input.web_search_intent
    elseif input.prompt_config and input.prompt_config.use_websearch ~= nil then
        tool_requested = input.prompt_config.use_websearch
    end

    local tool_mode = "none"
    if tool_requested and global_web_search and global_web_search ~= "none" then
        tool_mode = global_web_search
    end

    local suggestions = Prompts.isSuggestionsEnabled(settings, input.prompt_config)

    local context_mode = "none"
    if input.kind == "free" or input.kind == "feature" then
        context_mode = "refresh"
    elseif input.prompt_config and input.prompt_config.use_book_context then
        context_mode = "refresh"
    end

    return Conversation.TurnPolicy:new{
        tool_requested = tool_requested,
        tool_mode = tool_mode,
        suggestions = suggestions,
        context_mode = context_mode,
    }
end

-- ===========================================================================
-- QueryRequest: frozen snapshot for a single API call
-- ===========================================================================

Conversation.QueryRequest = {}
Conversation.QueryRequest.__index = Conversation.QueryRequest

---@param opts table
---@param opts.messages table[] Wire history copy for this request
---@param opts.stream boolean
---@param opts.tool_mode string Resolved tool mode ("none" or provider key)
---@param opts.title string|nil
---@param opts.identity table Provider/model display snapshot
function Conversation.QueryRequest:new(opts)
    local self = setmetatable({}, Conversation.QueryRequest)
    self.messages = opts.messages
    self.stream = opts.stream
    self.tool_mode = opts.tool_mode
    self.title = opts.title
    self.identity = opts.identity
    return self
end

-- ===========================================================================
-- ConversationSession: owns all state for one viewer interaction
-- ===========================================================================

Conversation.Session = {}
Conversation.Session.__index = Conversation.Session

---@param opts table
---@param opts.assistant table The plugin's assistant instance
---@param opts.title string|nil
function Conversation.Session:new(opts)
    local self = setmetatable({}, Conversation.Session)
    self.assistant = opts.assistant
    self.title = opts.title
    self.history = {}
    self.state = "idle"
    self.generation = 0
    self.active_turn = nil
    self.cancel = false
    return self
end

---Append a record to the session history.
---@param record table { role, content, attrs? }
function Conversation.Session:append(record)
    table.insert(self.history, record)
end

---Get the current history length.
function Conversation.Session:len()
    return #self.history
end

---Freeze a QueryRequest from current state + policy.
---@param policy Conversation.TurnPolicy
---@return Conversation.QueryRequest
function Conversation.Session:freeze_request(policy, identity)
    local messages = {}
    for i, msg in ipairs(self.history) do
        messages[i] = koutil.tableDeepCopy(msg)
    end
    return Conversation.QueryRequest:new{
        messages = messages,
        stream = self.assistant.settings:readSetting("use_stream_mode", true),
        tool_mode = policy.tool_mode,
        title = self.title,
        identity = identity,
    }
end

-- ===========================================================================
-- ConversationRenderer: unified result text assembly
-- ===========================================================================

Conversation.Renderer = {}

---Render the full history into result text.
---All entry points (dialog, feature, dict) share this pipeline; domain
---differences are expressed through the `opts` table.
---
---@param history table[] Full message history (system prompt at [1])
---@param opts table
---   - `header string|nil` — prepended header text (e.g. book info, word excerpt)
---   - `highlighted_text string|nil` — highlighted text to show before history
---   - `title string|nil` — title for formatSingleMessage
---   - `settings table` — assistant settings
---   - `default_config table` — default suggestion config
---   - `assistant table|nil` — for feature flag checks (hide_highlighted_text etc.)
---@return string
function Conversation.Renderer.render(history, opts)
    local TextUtils = require("assistant_text_utils")
    local ASUtils = require("assistant_utils")
    local _ = require("assistant_gettext")

    local minimal = opts.settings:readSetting("minimalist_mode", false)
    local parts = {}

    -- Header (book info, word excerpt, etc.)
    if opts.header then
        table.insert(parts, opts.header)
    end

    -- Highlighted text (dialog only)
    if opts.highlighted_text and opts.highlighted_text ~= "" then
        local show_highlighted = true
        -- Check hide_highlighted_text feature flag
        if opts.assistant and opts.assistant.config:getFeature("hide_highlighted_text") then
            show_highlighted = false
        end
        -- Check long highlight threshold
        if show_highlighted and opts.assistant and opts.assistant.config:getFeature("hide_long_highlights") then
            local threshold = opts.assistant.config:getFeature("long_highlight_threshold", 99999)
            if #opts.highlighted_text > threshold then
                show_highlighted = false
            end
        end
        if show_highlighted then
            table.insert(parts, string.format("__%s__\"%s\"\n\n", _("Highlighted text:"), opts.highlighted_text))
        end
    end

    -- History: skip [1] (system prompt) and is_context messages
    for i = 2, #history do
        local msg = history[i]
        local is_context = ASUtils.get_attr(msg, "is_context")
        if not is_context then
            table.insert(parts, TextUtils.formatSingleMessage(history, msg, {
                title = opts.title,
                msg_idx = i,
                settings = opts.settings,
                default_config = opts.default_config,
                minimal = minimal,
            }))
        end
    end

    return table.concat(parts)
end

---Render a follow-up increment (appends to existing text).
---@param history table[] Full message history
---@param opts table Same as render(), but `header` and `highlighted_text` are ignored
---@return string The increment text (starts with --- separator)
function Conversation.Renderer.render_increment(history, opts)
    local TextUtils = require("assistant_text_utils")
    local ASUtils = require("assistant_utils")

    local minimal = opts.settings:readSetting("minimalist_mode", false)
    local parts = { "---\n\n" }

    local last_user = history[#history - 1]
    local last_assistant = history[#history]

    if last_user then
        table.insert(parts, TextUtils.formatSingleMessage(history, last_user, {
            title = opts.title,
            msg_idx = #history - 1,
            settings = opts.settings,
            default_config = opts.default_config,
            minimal = minimal,
        }))
    end
    if last_assistant then
        table.insert(parts, TextUtils.formatSingleMessage(history, last_assistant, {
            title = opts.title,
            msg_idx = #history,
            settings = opts.settings,
            default_config = opts.default_config,
            minimal = minimal,
        }))
    end

    return table.concat(parts)
end

-- ===========================================================================
-- QueryRun: per-request transaction state for the tool-call loop
-- ===========================================================================

Conversation.QueryRun = {}
Conversation.QueryRun.__index = Conversation.QueryRun

function Conversation.QueryRun:new()
    local self = setmetatable({}, Conversation.QueryRun)
    self.wire_additions = {}   -- messages to append on successful completion
    self.tool_events = {}      -- search progress events (for UI feedback)
    self.state = "pending"     -- pending | committed | rolled_back
    return self
end

---Add wire messages (tool call + results) to the pending set.
---These are NOT yet visible to the canonical history.
---@param messages table[] Messages to append on commit
function Conversation.QueryRun:add_wire_messages(messages)
    for _, msg in ipairs(messages) do
        table.insert(self.wire_additions, msg)
    end
end

---Record a search progress event (keywords, round).
---@param event table { keywords: string, round: integer }
function Conversation.QueryRun:add_tool_event(event)
    table.insert(self.tool_events, event)
end

---Commit: append all pending wire messages to the canonical history.
---@param message_history table[] The canonical history to extend
function Conversation.QueryRun:commit(message_history)
    for _, msg in ipairs(self.wire_additions) do
        table.insert(message_history, msg)
    end
    self.wire_additions = {}
    self.state = "committed"
end

---Rollback: discard all pending wire messages.
function Conversation.QueryRun:rollback()
    self.wire_additions = {}
    self.state = "rolled_back"
end

-- ===========================================================================
-- Answer appending: shared by all entry adapters
-- ===========================================================================

---Append an assistant answer to the history with the suggestion switch set.
---@param message_history table[] Canonical history to extend
---@param answer string The final answer text
---@param suggestions boolean Whether follow-up suggestions are enabled
function Conversation.append_answer(message_history, answer, suggestions)
    local assistant_msg = {
        role = "assistant",
        content = answer,
    }
    ASUtils.set_attr(assistant_msg, "show_suggestions", suggestions)
    table.insert(message_history, assistant_msg)
end

return Conversation
