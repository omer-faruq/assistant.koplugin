-- test_querier_identity.lua
-- Guards the per-query provider/model snapshot behind every request display.
-- The invariant that matters is the ordering: Querier:getRequestIdentity
-- must freeze label+model BEFORE the first handler:query bg_fn is built, so
-- a mid-flight provider/model switch (the model picker rewrites the shared
-- handler singleton without refreshing the deep-copied provider_setting)
-- cannot desync the display from the frozen request.
-- Headless-safe: the querier pulls the full UI stack and is never required
-- here, so the file is read as text and the two build sites are compared
-- by byte offset.
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

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("query: snapshot is taken before the first bg_fn build", function()
        local snap_pos = querier_src:find("request_identity = self:getRequestIdentity()", 1, true)
        assert.notNil(snap_pos, "query must capture the snapshot")
        local bg_pos = querier_src:find("bg_fn, err = self.handler:query", 1, true)
        assert.notNil(bg_pos, "stream bg_fn build site missing")
        assert.isTrue(snap_pos < bg_pos, "snapshot must precede the first bg_fn build")
        assert.matches(querier_src, 'self%.last_request_identity = request_identity', "snapshot must be kept for the error box")
    end),
}

return helper.runTests("querier_identity.lua", tests)
