-- test_utf8_truncate.lua
-- Owns the UTF-8 byte-boundary matrix for the truncation helpers in
-- assistant_text_utils.lua (truncateToTailUtf8Safe / truncateToHeadUtf8Safe):
-- how a budget of any size lands on a character boundary for 2-, 3- and 4-byte
-- sequences, and that a cut never leaves invalid bytes or a replacement mark.
-- Word-boundary snapping of a dictionary excerpt is TermXray.clip_excerpt and
-- is covered by test_term_xray.lua.
local helper = require("test.helper")
local assert = helper.assert
local TextUtils = helper.TextUtils
local util = require("util")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- True when `s` is well-formed UTF-8 (a replacement sentinel must not appear).
local function is_valid_utf8(s)
    return util.fixUtf8(s, "\1") == s
end

local CJK = string.rep("中", 40)   -- 3 bytes per char, 120 bytes
local ACCENT = string.rep("é", 60) -- 2 bytes per char, 120 bytes
local EMOJI = string.rep("😀", 30) -- 4 bytes per char, 120 bytes

local tests = {
    test("head: short string is returned unchanged", function()
        assert.equal(TextUtils.truncateToHeadUtf8Safe("abc", 100), "abc")
    end),

    test("tail: short string is returned unchanged", function()
        assert.equal(TextUtils.truncateToTailUtf8Safe("abc", 100), "abc")
    end),

    test("head: exact byte length is returned unchanged", function()
        assert.equal(TextUtils.truncateToHeadUtf8Safe(CJK, 120), CJK)
    end),

    test("head: ASCII is cut at the byte boundary", function()
        assert.equal(TextUtils.truncateToHeadUtf8Safe("Hello, World!", 5), "Hello")
    end),

    test("head: drops a 3-byte char split at its lead byte", function()
        -- 100 = 3*33 + 1: the 34th char is only partially inside the budget.
        assert.equal(TextUtils.truncateToHeadUtf8Safe(CJK, 100), CJK:sub(1, 99))
    end),

    test("head: drops a 3-byte char split mid-sequence", function()
        -- 101 = 3*33 + 2: lead + one continuation byte available.
        assert.equal(TextUtils.truncateToHeadUtf8Safe(CJK, 101), CJK:sub(1, 99))
    end),

    test("head: keeps a char ending exactly at the cut", function()
        assert.equal(TextUtils.truncateToHeadUtf8Safe(CJK, 99), CJK:sub(1, 99))
    end),

    test("head: drops a 2-byte char split mid-sequence", function()
        assert.equal(TextUtils.truncateToHeadUtf8Safe(ACCENT, 101), ACCENT:sub(1, 100))
    end),

    test("head: drops a 4-byte char split mid-sequence", function()
        assert.equal(TextUtils.truncateToHeadUtf8Safe(EMOJI, 10), EMOJI:sub(1, 8))
    end),

    test("head: never leaves a replacement artifact", function()
        local out = TextUtils.truncateToHeadUtf8Safe(CJK, 100)
        assert.isTrue(is_valid_utf8(out), "head result must be valid UTF-8")
        assert.notMatches(out, "_", "head result must not contain a '_' artifact")
    end),

    test("tail: cuts a 3-byte sequence on a character boundary", function()
        -- sub(-100) starts on a continuation byte; it must be discarded.
        assert.equal(TextUtils.truncateToTailUtf8Safe(CJK, 100), CJK:sub(22))
        assert.isTrue(is_valid_utf8(TextUtils.truncateToTailUtf8Safe(CJK, 100)))
    end),

    test("tail: cuts a 2-byte sequence on a character boundary", function()
        assert.equal(TextUtils.truncateToTailUtf8Safe(ACCENT, 101), ACCENT:sub(21))
    end),

    test("tail: cuts a 4-byte sequence on a character boundary", function()
        assert.equal(TextUtils.truncateToTailUtf8Safe(EMOJI, 11), EMOJI:sub(113))
    end),

    test("tail: never leaves a replacement artifact", function()
        local out = TextUtils.truncateToTailUtf8Safe(EMOJI, 11)
        assert.isTrue(is_valid_utf8(out), "tail result must be valid UTF-8")
        assert.notMatches(out, "_", "tail result must not contain a '_' artifact")
    end),

    test("excerpt header composed from both truncation sides stays valid UTF-8", function()
        -- The dictionary header shape: a prev-context excerpt kept from its
        -- tail, the looked-up word, and a next-context excerpt kept from its
        -- head -- both capped to the same byte budget.
        local prev = string.rep("字", 50)
        local next_ctx = string.rep("词", 40)
        local prev_lim = TextUtils.truncateToTailUtf8Safe(prev, 100)
        local next_lim = TextUtils.truncateToHeadUtf8Safe(next_ctx, 100)
        local header = "... " .. prev_lim .. " **word** " .. next_lim .. " ..."

        assert.isTrue(#prev_lim <= 100, "prev excerpt must stay within budget")
        assert.isTrue(#next_lim <= 100, "next excerpt must stay within budget")
        assert.isTrue(is_valid_utf8(header), "excerpt header must be valid UTF-8")
        assert.notMatches(next_lim, "_", "next excerpt must not end in a '_' artifact")
        assert.equal(next_lim, next_ctx:sub(1, 99))
    end),
}

return helper.runTests("utf8_truncate", tests)
