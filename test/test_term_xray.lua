-- test_term_xray.lua
-- Tests for the occurrence-anchored Term X-Ray extractor:
--   * find_term_indices: case-insensitive, punctuation-stripped fallback
--   * build_anchor_context: anchor windows, occurrence sampling, document order
--     and the skip-not-stop character budget
--
-- The CJK case guards the original bug: a byte-wise sentence scanner raised a
-- comparison error on Chinese text with no ASCII punctuation.
local helper = require("test.helper")
local assert = helper.assert
local TermXray = require("assistant_term_xray")
local ASUtils = helper.ASUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Sentences are single tokens ("s1".."sN") so a word count equals the number of
-- concatenated sentences.
local function make_sentences(count, length)
    local sentences = {}
    for i = 1, count do
        local marker = "s" .. i
        sentences[i] = marker .. string.rep("x", math.max(0, length - #marker))
    end
    return sentences
end

local function pad(marker, length)
    return marker .. string.rep("x", length - #marker)
end

local tests = {
    test("find_term_indices: case-insensitive, ascending", function()
        local sentences = { "The Ring was lost.", "It glowed softly.", "Then the RING returned." }
        assert.equal(table.concat(TermXray.find_term_indices(sentences, "ring"), ","), "1,3")
        assert.equal(table.concat(TermXray.find_term_indices(sentences, "RING"), ","), "1,3")
    end),

    test("find_term_indices: stripped-punctuation fallback", function()
        -- "word." is absent verbatim; the stripped term "word" matches.
        local sentences = { "A word here.", "Nothing relevant at all." }
        assert.equal(table.concat(TermXray.find_term_indices(sentences, "word."), ","), "1")
    end),

    test("find_term_indices: absent term yields an empty list", function()
        local sentences = { "alpha beta", "gamma delta" }
        assert.equal(#TermXray.find_term_indices(sentences, "zebra"), 0)
    end),

    test("build_anchor_context: windows expand around anchors in document order", function()
        local sentences = make_sentences(10, 20)
        local built = TermXray.build_anchor_context(sentences, { 5 }, {
            sentences_before = 2,
            sentences_after = 2,
        })
        assert.equal(built.text, table.concat(
            { sentences[3], sentences[4], sentences[5], sentences[6], sentences[7] }, " "))
        assert.equal(built.sentence_count, 5)
        assert.equal(built.sentence_count, select(2, built.text:gsub("%S+", "")))
    end),

    test("build_anchor_context: budget skips an oversized middle sentence", function()
        local sentences = {
            pad("A1", 100),
            pad("B2", 3000), -- overflows the 1000-char budget
            pad("C3", 100),
            pad("D4", 100),
            pad("E5", 100),
            pad("F6", 100),
            pad("G7", 100),
            pad("H8", 100),
        }
        local built = TermXray.build_anchor_context(sentences, { 4 }, {
            sentences_before = 3,
            sentences_after = 4,
            max_characters = 1000,
        })
        assert.isTrue(#built.text <= 1000, "context must respect max_characters")
        assert.equal(built.sentence_count, 7)
        assert.isTrue(built.text:find("H8", 1, true) ~= nil, "late sentences must survive the skip")
        assert.equal(built.text:find("B2", 1, true), nil, "the oversized sentence must be skipped")
    end),

    test("build_anchor_context: samples exactly max_occurrences across the whole list", function()
        local sentences = make_sentences(30, 20)
        local term_indices = {}
        for i = 1, 30 do
            term_indices[i] = i
        end
        local built = TermXray.build_anchor_context(sentences, term_indices, {
            sentences_before = 0,
            sentences_after = 0,
            max_occurrences = 5,
        })
        -- Even spacing over 30 items picks 1, 8, 15, 22 and 30.
        assert.equal(built.text, table.concat(
            { sentences[1], sentences[8], sentences[15], sentences[22], sentences[30] }, " "))
        assert.equal(built.sentence_count, 5)
        assert.equal(built.text:find(sentences[1] .. " ", 1, true), 1, "the first occurrence must be included")
        assert.equal(built.text:sub(-#sentences[30]), sentences[30], "the last occurrence must be included")
    end),

    test("build_anchor_context: max_occurrences of 1 keeps only the first occurrence", function()
        local sentences = make_sentences(10, 20)
        local term_indices = {}
        for i = 1, 10 do
            term_indices[i] = i
        end
        local built = TermXray.build_anchor_context(sentences, term_indices, {
            sentences_before = 0,
            sentences_after = 0,
            max_occurrences = 1,
        })
        assert.equal(built.text, sentences[1])
        assert.equal(built.sentence_count, 1)
    end),

    test("build_anchor_context: empty inputs produce empty text without crashing", function()
        local empty_indices = TermXray.build_anchor_context({ "one", "two" }, {}, {})
        assert.equal(empty_indices.text, "")
        assert.equal(empty_indices.sentence_count, 0)

        local nil_indices = TermXray.build_anchor_context({ "one", "two" }, nil, {})
        assert.equal(nil_indices.text, "")
        assert.equal(nil_indices.sentence_count, 0)

        local no_sentences = TermXray.build_anchor_context({}, { 1 }, {})
        assert.equal(no_sentences.text, "")
        assert.equal(no_sentences.sentence_count, 0)

        local nil_sentences = TermXray.build_anchor_context(nil, { 1 }, {})
        assert.equal(nil_sentences.text, "")
        assert.equal(nil_sentences.sentence_count, 0)
    end),

    test("CJK end-to-end: split, find and build without an ASCII-punctuation error", function()
        local book = "张伟走进那座古老而安静的图书馆。馆内藏书丰富而珍贵。"
            .. "他寻找一本关于星空的稀有书籍。窗外阳光明媚照在书架上。"

        local all_sentences = TermXray.split_sentences(book)
        assert.isTrue(#all_sentences > 0, "the CJK tokenizer must produce sentences")

        local term = "图书馆"
        local term_indices = TermXray.find_term_indices(all_sentences, term)
        assert.isTrue(#term_indices >= 1, "the term must be found in the CJK text")

        local built = TermXray.build_anchor_context(all_sentences, term_indices, {
            max_characters = 60000,
        })
        assert.matches(built.text, term)
        assert.isTrue(built.sentence_count >= 1, "at least the anchor sentence must be emitted")
        assert.isTrue(#built.text <= 60000, "context must respect max_characters")
    end),

    test("tokenize_sentences: long CJK text splits without error", function()
        local book = string.rep("张伟走进那座古老而安静的图书馆。", 300)
        local sentences = TermXray.split_sentences(book)
        assert.isTrue(#sentences > 100, "a long CJK text must split into many sentences")
    end),

    test("find_term_indices: phrase matches across line breaks and doubled spaces", function()
        local sentences = {
            "He walked down Vasil Levski\nBoulevard in the rain.",
            "Vasil  Levski   Boulevard was busy that morning.",
            "Nothing relevant here.",
        }
        local indices = TermXray.find_term_indices(sentences, "Vasil Levski Boulevard")
        assert.equal(#indices, 2, "whitespace differences must not prevent matching")
        assert.equal(indices[1], 1)
        assert.equal(indices[2], 2)
    end),

    test("find_term_indices: non-breaking spaces match regular spaces", function()
        local sentences = { "The office on Vasil\194\160Levski\194\160Boulevard was closed." }
        local indices = TermXray.find_term_indices(sentences, "Vasil Levski Boulevard")
        assert.equal(#indices, 1, "non-breaking spaces must not prevent matching")
    end),

    test("clip_excerpt tail: cut inside a word snaps to the next whole word", function()
        -- The dictionary "... r him ..." case: prev ends "...for him" and the
        -- 100-byte budget slices "fo" off "for".
        assert.equal(TermXray.clip_excerpt("ab for him", 5, "tail"), "him")
        assert.equal(TermXray.clip_excerpt("ab for him", 6, "tail"), "him")
    end),

    test("clip_excerpt head: cut inside a word snaps back to the previous word", function()
        assert.equal(TermXray.clip_excerpt("hello world", 8, "head"), "hello")
        assert.equal(TermXray.clip_excerpt("hi world", 5, "head"), "hi")
    end),

    test("clip_excerpt: clean cuts at spaces are unchanged", function()
        assert.equal(TermXray.clip_excerpt("aa bb cc", 5, "tail"), "bb cc")
        assert.equal(TermXray.clip_excerpt("aa bb cc", 5, "head"), "aa bb")
    end),

    test("clip_excerpt: short strings are returned unchanged", function()
        assert.equal(TermXray.clip_excerpt("abc", 100, "tail"), "abc")
        assert.equal(TermXray.clip_excerpt("abc", 100, "head"), "abc")
        assert.equal(TermXray.clip_excerpt("abc", 3, "tail"), "abc")
        assert.equal(TermXray.clip_excerpt("abc", 3, "head"), "abc")
    end),

    test("clip_excerpt: hyphen and apostrophe count as word characters", function()
        assert.equal(TermXray.clip_excerpt("self-esteem hi", 5, "tail"), "hi")
        assert.equal(TermXray.clip_excerpt("hi don't", 5, "head"), "hi")
    end),

    test("clip_excerpt: single over-long token falls back to un-snapped", function()
        assert.equal(TermXray.clip_excerpt("abcdefghij", 5, "tail"), "fghij")
        assert.equal(TermXray.clip_excerpt("abcdefghij", 5, "head"), "abcde")
    end),

    test("clip_excerpt: CJK cuts on the character boundary within budget", function()
        local cjk = string.rep("中", 40) -- 120 bytes
        local tail = TermXray.clip_excerpt(cjk, 100, "tail")
        local head = TermXray.clip_excerpt(cjk, 100, "head")
        assert.equal(tail, ASUtils.truncateToTailUtf8Safe(cjk, 100))
        assert.equal(head, ASUtils.truncateToHeadUtf8Safe(cjk, 100))
        assert.isTrue(#tail <= 100, "tail excerpt must stay within budget")
        assert.isTrue(#head <= 100, "head excerpt must stay within budget")
        assert.isTrue(#tail < #cjk, "tail excerpt must be truncated")
        assert.isTrue(#head < #cjk, "head excerpt must be truncated")
    end),

    test("clip_excerpt: never longer than the UTF-8-safe truncation", function()
        local prev = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do"
        local next_ctx = "eiusmod tempor incididunt ut labore et dolore magna aliqua"
        for k = 1, 59 do
            local tail = TermXray.clip_excerpt(prev, k, "tail")
            local head = TermXray.clip_excerpt(next_ctx, k, "head")
            assert.isTrue(#tail <= #ASUtils.truncateToTailUtf8Safe(prev, k),
                "tail clip must not exceed the UTF-8-safe truncation")
            assert.isTrue(#head <= #ASUtils.truncateToHeadUtf8Safe(next_ctx, k),
                "head clip must not exceed the UTF-8-safe truncation")
        end
    end),
}

return helper.runTests("term_xray", tests)
