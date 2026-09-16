-- test_utf8_truncate.lua
-- Regression tests for UTF-8-safe truncation helpers in assistant_utils.lua.
--
-- Context: assistant_dictdialog.lua shows a short excerpt of book text around
-- the looked-up word. It used raw string.sub, which sliced multi-byte
-- characters in half and displayed trailing garbage. The excerpt must now be
-- cut on a UTF-8 character boundary.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils
local TermXray = require("assistant_term_xray")
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
        assert.equal(ASUtils.truncateToHeadUtf8Safe("abc", 100), "abc")
    end),

    test("tail: short string is returned unchanged", function()
        assert.equal(ASUtils.truncateToTailUtf8Safe("abc", 100), "abc")
    end),

    test("head: exact byte length is returned unchanged", function()
        assert.equal(ASUtils.truncateToHeadUtf8Safe(CJK, 120), CJK)
    end),

    test("head: ASCII is cut at the byte boundary", function()
        assert.equal(ASUtils.truncateToHeadUtf8Safe("Hello, World!", 5), "Hello")
    end),

    test("head: drops a 3-byte char split at its lead byte", function()
        -- 100 = 3*33 + 1: the 34th char is only partially inside the budget.
        assert.equal(ASUtils.truncateToHeadUtf8Safe(CJK, 100), CJK:sub(1, 99))
    end),

    test("head: drops a 3-byte char split mid-sequence", function()
        -- 101 = 3*33 + 2: lead + one continuation byte available.
        assert.equal(ASUtils.truncateToHeadUtf8Safe(CJK, 101), CJK:sub(1, 99))
    end),

    test("head: keeps a char ending exactly at the cut", function()
        assert.equal(ASUtils.truncateToHeadUtf8Safe(CJK, 99), CJK:sub(1, 99))
    end),

    test("head: drops a 2-byte char split mid-sequence", function()
        assert.equal(ASUtils.truncateToHeadUtf8Safe(ACCENT, 101), ACCENT:sub(1, 100))
    end),

    test("head: drops a 4-byte char split mid-sequence", function()
        assert.equal(ASUtils.truncateToHeadUtf8Safe(EMOJI, 10), EMOJI:sub(1, 8))
    end),

    test("head: never leaves a replacement artifact", function()
        local out = ASUtils.truncateToHeadUtf8Safe(CJK, 100)
        assert.isTrue(is_valid_utf8(out), "head result must be valid UTF-8")
        assert.notMatches(out, "_", "head result must not contain a '_' artifact")
    end),

    test("tail: cuts a 3-byte sequence on a character boundary", function()
        -- sub(-100) starts on a continuation byte; it must be discarded.
        assert.equal(ASUtils.truncateToTailUtf8Safe(CJK, 100), CJK:sub(22))
        assert.isTrue(is_valid_utf8(ASUtils.truncateToTailUtf8Safe(CJK, 100)))
    end),

    test("tail: cuts a 2-byte sequence on a character boundary", function()
        assert.equal(ASUtils.truncateToTailUtf8Safe(ACCENT, 101), ACCENT:sub(21))
    end),

    test("tail: cuts a 4-byte sequence on a character boundary", function()
        assert.equal(ASUtils.truncateToTailUtf8Safe(EMOJI, 11), EMOJI:sub(113))
    end),

    test("dictionary excerpt header stays valid UTF-8", function()
        -- Mirrors createResultText in assistant_dictdialog.lua: prev kept from
        -- its tail, next kept from its head, both capped to 100 bytes.
        local prev = string.rep("字", 50)
        local next_ctx = string.rep("词", 40)
        local prev_lim = ASUtils.truncateToTailUtf8Safe(prev, 100)
        local next_lim = ASUtils.truncateToHeadUtf8Safe(next_ctx, 100)
        local header = "... " .. prev_lim .. " **word** " .. next_lim .. " ..."

        assert.isTrue(#prev_lim <= 100, "prev excerpt must stay within budget")
        assert.isTrue(#next_lim <= 100, "next excerpt must stay within budget")
        assert.isTrue(is_valid_utf8(header), "excerpt header must be valid UTF-8")
        assert.notMatches(next_lim, "_", "next excerpt must not end in a '_' artifact")
        assert.equal(next_lim, next_ctx:sub(1, 99))
    end),

    test("dictionary excerpt clips mid-word cuts to whole words", function()
        -- Mirrors createResultText in assistant_dictdialog.lua, now via
        -- TermXray.clip_excerpt: the 100-byte budget must not leave a
        -- fragment like "r him" when prev ends "...for him".
        local prev = "text before " .. string.rep("lorem ipsum dolor ", 6) .. "said for him"
        local next_ctx = "worldwide " .. string.rep("amet consectetur ", 6) .. "after"
        local prev_lim = TermXray.clip_excerpt(prev, 100, "tail")
        local next_lim = TermXray.clip_excerpt(next_ctx, 100, "head")
        local header = "... " .. prev_lim .. " **word** " .. next_lim .. " ..."

        assert.isTrue(#prev_lim <= 100, "prev excerpt must stay within budget")
        assert.isTrue(#next_lim <= 100, "next excerpt must stay within budget")
        assert.isTrue(is_valid_utf8(header), "excerpt header must be valid UTF-8")
        -- Invariant: when truncated, the cut must not fall inside a word.
        if #prev > 100 then
            local before = prev:sub(#prev - #prev_lim, #prev - #prev_lim)
            local first = prev_lim:sub(1, 1)
            local both_word = before:match("[%w'%-]") and first:match("[%w'%-]")
            assert.isTrue(not both_word, "prev excerpt must start on a word boundary")
        end
        if #next_ctx > 100 then
            local last = next_lim:sub(-1)
            local after = next_ctx:sub(#next_lim + 1, #next_lim + 1)
            local both_word = last:match("[%w'%-]") and after:match("[%w'%-]")
            assert.isTrue(not both_word, "next excerpt must end on a word boundary")
        end
    end),

    test("dictionary excerpt head snaps a partial leading word away", function()
        -- "wor|ld ..." must end before the fragment, not inside it.
        local next_ctx = "hello world " .. string.rep("x ", 60)
        local clipped = TermXray.clip_excerpt(next_ctx, 8, "head")
        assert.equal(clipped, "hello")
    end),

    test("dictionary excerpt tail snaps a partial trailing word away", function()
        local prev = "ab for him"
        assert.equal(TermXray.clip_excerpt(prev, 5, "tail"), "him")
    end),

    test("dictionary excerpt leaves clean and short cuts unchanged", function()
        assert.equal(TermXray.clip_excerpt("aa bb cc", 5, "tail"), "bb cc")
        assert.equal(TermXray.clip_excerpt("aa bb cc", 5, "head"), "aa bb")
        assert.equal(TermXray.clip_excerpt("abc", 100, "tail"), "abc")
        assert.equal(TermXray.clip_excerpt("abc", 100, "head"), "abc")
    end),

    test("dictionary excerpt keeps a single over-long token visible", function()
        assert.equal(TermXray.clip_excerpt("abcdefghij", 5, "tail"), "fghij")
        assert.equal(TermXray.clip_excerpt("abcdefghij", 5, "head"), "abcde")
    end),

    test("dictionary excerpt CJK still cuts on the character boundary", function()
        local prev = string.rep("字", 50)
        local next_ctx = string.rep("词", 40)
        local prev_lim = TermXray.clip_excerpt(prev, 100, "tail")
        local next_lim = TermXray.clip_excerpt(next_ctx, 100, "head")
        assert.equal(prev_lim, ASUtils.truncateToTailUtf8Safe(prev, 100))
        assert.equal(next_lim, ASUtils.truncateToHeadUtf8Safe(next_ctx, 100))
        assert.isTrue(#prev_lim <= 100, "prev excerpt must stay within budget")
        assert.isTrue(#next_lim <= 100, "next excerpt must stay within budget")
        assert.isTrue(is_valid_utf8(prev_lim), "prev excerpt must be valid UTF-8")
        assert.isTrue(is_valid_utf8(next_lim), "next excerpt must be valid UTF-8")
    end),
}

return helper.runTests("utf8_truncate", tests)
