-- test_querier_identity.lua
-- Guards the per-query provider/model snapshot behind every request display:
--   * Querier:getRequestIdentity freezes label+model once per query; the
--     loading toasts, stream dialog description and error box all read the
--     frozen pair instead of live objects, so a mid-flight provider/model
--     switch (the model picker rewrites the shared handler singleton
--     without refreshing the deep-copied provider_setting) cannot desync
--     the display from the frozen request
--   * the snapshot is taken before the first handler:query bg_fn build
-- Headless-safe: the querier pulls the full UI stack and is never required
-- here; file shapes via source scan plus a driver mirroring the
-- freeze-then-display sequence.
local helper = require("test.helper")
local assert = helper.assert

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_source(name)
    local f = io.open(project_root .. name, "r")
    assert.notNil(f, "cannot open " .. name)
    local src = f:read("*a")
    f:close()
    return src
end

local querier_src = read_source("assistant_querier.lua")

local function read_lines(path)
    local f = io.open(project_root .. path, "r")
    assert.notNil(f, "cannot open " .. path)
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    return lines
end

-- Lines following the showStremDialog header (the description sits ~30
-- lines below it).
local function dialog_window()
    local lines = read_lines("assistant_querier.lua")
    local start = nil
    for idx = 1, #lines do
        if lines[idx]:find("function Querier:showStremDialog", 1, true) then
            start = idx
            break
        end
    end
    assert.notNil(start, "showStremDialog header missing")
    local out = {}
    for idx = start, math.min(start + 60, #lines) do
        out[#out + 1] = lines[idx]
    end
    return table.concat(out, "\n")
end

local function count_plain(text, needle)
    local n = 0
    local init = 1
    while true do
        local hit = text:find(needle, init, true)
        if not hit then break end
        n = n + 1
        init = hit + 1
    end
    return n
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("helper: getRequestIdentity freezes label and model", function()
        assert.matches(querier_src, 'function Querier:getRequestIdentity', "snapshot helper missing")
        assert.matches(querier_src, 'label = self:getProviderLabel%(%) or "%?"', "label must come from the provider label")
        assert.matches(querier_src, 'model = self%.handler and self%.handler%.model or "%?"', "model must come from the live handler")
    end),

    test("query: snapshot is taken before the first bg_fn build", function()
        local snap_pos = querier_src:find("request_identity = self:getRequestIdentity()", 1, true)
        assert.notNil(snap_pos, "query must capture the snapshot")
        local bg_pos = querier_src:find("bg_fn, err = self.handler:query", 1, true)
        assert.notNil(bg_pos, "stream bg_fn build site missing")
        assert.isTrue(snap_pos < bg_pos, "snapshot must precede the first bg_fn build")
        assert.matches(querier_src, 'self%.last_request_identity = request_identity', "snapshot must be kept for the error box")
    end),

    test("dialog: description reads the passed snapshot, never live state", function()
        assert.matches(querier_src, 'showStremDialog%(bg_fn, request_title, request_identity%)', "call site must pass the snapshot")
        assert.matches(querier_src, 'function Querier:showStremDialog%(res, request_title, request_identity%)', "dialog must accept the snapshot")
        local window = dialog_window()
        assert.matches(window, 'request_identity%.label', "description must use the frozen label")
        assert.matches(window, 'request_identity%.model', "description must use the frozen model")
        assert.notMatches(window, 'self:getProviderLabel', "description must not live-read the label")
        assert.notMatches(window, 'self%.handler%.model', "description must not live-read the model")
    end),

    test("toasts and error box share the frozen pair", function()
        assert.isTrue(count_plain(querier_src, "request_identity.label") >= 3, "dialog plus both toasts must read the frozen label")
        assert.isTrue(count_plain(querier_src, "request_identity.model") >= 3, "dialog plus both toasts must read the frozen model")
        assert.matches(querier_src, 'self%.last_request_identity or self:getRequestIdentity', "error box must prefer the frozen pair")
        assert.matches(querier_src, 'local provider = identity%.label', "error box must use the frozen label")
        assert.matches(querier_src, 'local model = identity%.model', "error box must use the frozen model")
    end),

    test("driver: frozen display survives a mid-flight handler rewrite", function()
        local live = { label = "Provider A", model = "model-a" }
        local identity = { label = live.label, model = live.model }
        local dialog_desc = "✦ " .. identity.label .. "/" .. identity.model
        local toast = "✦ " .. identity.label .. "/<b>" .. identity.model .. "</b>"
        live.label = "Provider B"
        live.model = "model-b"
        assert.equal(dialog_desc, "✦ Provider A/model-a")
        assert.equal(toast, "✦ Provider A/<b>model-a</b>")
    end),
}

return helper.runTests("querier_identity.lua", tests)
