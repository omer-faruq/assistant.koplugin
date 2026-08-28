-- test_prompts.lua
-- Tests for the Phase-1 prompt-context feature:
--   * built-in prompt flag defaults (use_book_context)
--   * deep-merge override semantics via M.getMergedPrompts
--   * inline copy of AssistantDialog:_buildBookContextMessage content assembly
--   * ASUtils.set_attr/get_attr roundtrip for is_context metadata
-- Tests for the Phase-2 nearby-page-text feature:
--   * ASUtils.getPageRangeText availability guards
--   * inline copy of the pure budget-assembly helper (assemblePageContext)
--   * inline copy of the page-text injection decision logic
local helper = require("test.test_helper")
local assert = helper.assert
local M = require("assistant_prompts")
local ASUtils = helper.ASUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

-- Inline copy of AssistantDialog:_buildBookContextMessage pure content-assembly
-- logic (assistant_dialog.lua:305-331). The real method is a dialog method with
-- UI deps, so we test only its pure logic here, per AGENTS.md testing policy.
local function build_context_content(book_title, book_author, highlighted_text, page_info)
  local content
  if highlighted_text and highlighted_text ~= "" then
    content = string.format([[I'm reading something titled '%s' by %s.
I have a question about the following highlighted text: ```%s```.
If the question is not clear enough, analyze the highlighted text.]],
      book_title, book_author, highlighted_text)
  elseif book_title and book_author then
    content = string.format([[I'm reading something titled '%s' by %s.
I have a question about this book.]], book_title, book_author)
  else
    content = string.format([[You are a helpful assistant. I have a question.]])
  end
  if page_info and page_info ~= "" then
    content = content .. string.format("\n\nMy current reading position is:%s.", page_info)
  end
  return content
end

local tests = {

    -- =========================================================================
    -- 1. Built-in flag defaults
    -- =========================================================================

    test("builtin_prompts: all 13 keys exist", function()
        local keys = {
            "term_xray", "dictionary", "quick_note", "vocabulary", "grammar",
            "translate", "summarize", "simplify", "key_points", "ELI5",
            "explain", "historical_context", "wikipedia",
        }
        for _, key in ipairs(keys) do
            assert.notNil(M.builtin_prompts[key], "builtin_prompts." .. key .. " should exist")
        end
    end),

    test("builtin_prompts: use_book_context == true on the 5 expected keys", function()
        local true_keys = { "summarize", "key_points", "ELI5", "explain", "historical_context" }
        for _, key in ipairs(true_keys) do
            assert.equal(M.builtin_prompts[key].use_book_context, true,
                key .. ".use_book_context should be true")
        end
    end),

    test("builtin_prompts: use_book_context == false on the other 8 keys", function()
        local false_keys = {
            "term_xray", "dictionary", "quick_note", "vocabulary", "grammar",
            "translate", "simplify", "wikipedia",
        }
        for _, key in ipairs(false_keys) do
            assert.equal(M.builtin_prompts[key].use_book_context, false,
                key .. ".use_book_context should be false")
        end
    end),

    -- =========================================================================
    -- 2. Deep-merge override semantics
    -- =========================================================================

    test("getMergedPrompts: field-level merge (explain flipped to false)", function()
        M.invalidateCache()
        local merged = M.getMergedPrompts({ explain = { use_book_context = false } })
        assert.equal(merged.explain.use_book_context, false,
            "explain.use_book_context should be overridden to false")
        -- other fields preserved (field-level merge, not whole-entry replace)
        assert.notNil(merged.explain.text, "explain.text should be preserved")
        assert.notNil(merged.explain.order, "explain.order should be preserved")
    end),

    test("getMergedPrompts: flip default-false vocabulary up to true", function()
        M.invalidateCache()
        local merged = M.getMergedPrompts({ vocabulary = { use_book_context = true } })
        assert.equal(merged.vocabulary.use_book_context, true,
            "vocabulary.use_book_context should be flipped to true")
        assert.notNil(merged.vocabulary.text, "vocabulary.text should be preserved")
    end),

    test("getMergedPrompts: nil conf after invalidateCache returns built-in defaults", function()
        M.invalidateCache()
        local merged = M.getMergedPrompts(nil)
        assert.equal(merged.summarize.use_book_context, true, "summarize should default true")
        assert.equal(merged.vocabulary.use_book_context, false, "vocabulary should default false")
        assert.equal(merged.explain.use_book_context, true, "explain should default true")
    end),

    -- =========================================================================
    -- 3. Context-content assembly snippet
    -- =========================================================================

    test("build_context_content: highlighted branch includes title/author/highlight", function()
        local c = build_context_content("My Book", "Jane Doe", "some highlight", "")
        assert.matches(c, "My Book")
        assert.matches(c, "Jane Doe")
        assert.matches(c, "some highlight")
        assert.notMatches(c, "My current reading position is:")
    end),

    test("build_context_content: book-only branch when highlight empty", function()
        local c = build_context_content("My Book", "Jane Doe", "", "")
        assert.matches(c, "My Book")
        assert.matches(c, "Jane Doe")
        assert.matches(c, "I have a question about this book.")
        assert.notMatches(c, "highlighted text")
        assert.notMatches(c, "My current reading position is:")
    end),

    test("build_context_content: fallback branch when title/author absent", function()
        local c = build_context_content(nil, nil, nil, "")
        assert.matches(c, "You are a helpful assistant. I have a question.")
        assert.notMatches(c, "My Book")
        assert.notMatches(c, "My current reading position is:")
    end),

    test("build_context_content: non-empty page_info appends position sentence", function()
        local c = build_context_content("My Book", "Jane Doe", "hl", " (Page 12 - 34%) - Chapter Title")
        assert.matches(c, "My current reading position is:")
        assert.matches(c, "Chapter Title")
    end),

    test("build_context_content: empty page_info omits position sentence", function()
        local c = build_context_content("My Book", "Jane Doe", "hl", "")
        assert.notMatches(c, "My current reading position is:")
    end),

    test("build_context_content: nil page_info omits position sentence", function()
        local c = build_context_content("My Book", "Jane Doe", "hl", nil)
        assert.notMatches(c, "My current reading position is:")
    end),

    -- =========================================================================
    -- 4. ASUtils.set_attr/get_attr roundtrip (is_context metadata)
    -- =========================================================================

    test("ASUtils.set_attr/get_attr roundtrip (is_context=true)", function()
        local msg = { role = "user", content = "hi" }
        ASUtils.set_attr(msg, "is_context", true)
        assert.isTrue(ASUtils.get_attr(msg, "is_context") == true,
            "is_context should roundtrip as true")
    end),

    -- =========================================================================
    -- 5. Phase-2: getPageRangeText availability guards (real module)
    -- =========================================================================

    test("getPageRangeText: nil ui returns empty string", function()
        assert.equal(ASUtils.getPageRangeText(nil, 1, 1, 6000), "",
            "nil ui should yield empty string")
    end),

    test("getPageRangeText: ui without document returns empty string", function()
        assert.equal(ASUtils.getPageRangeText({}, 1, 1, 6000), "",
            "missing ui.document should yield empty string")
    end),

    test("getPageRangeText: document without selection pos0 returns empty string", function()
        assert.equal(ASUtils.getPageRangeText({ document = {} }, 1, 1, 6000), "",
            "missing selection pos0 should yield empty string")
    end),
}

-- =========================================================================
-- 6. Phase-2: inline copy of the pure budget-assembly helper
-- (verbatim from assistant_utils.lua assemblePageContext; kept local there,
--  so per AGENTS.md policy we test an inline copy of the pure logic)
-- =========================================================================

local util = require("util")

local function assemblePageContext(prev, current, next, max_chars)
  prev = (type(prev) == "string" and prev ~= "") and prev or ""
  current = (type(current) == "string" and current ~= "") and current or ""
  next = (type(next) == "string" and next ~= "") and next or ""

  if prev == "" and current == "" and next == "" then
    return ""
  end

  max_chars = max_chars or 6000
  local parts = {}

  if #current <= max_chars then
    parts.current = current
    local remaining = max_chars - #current
    local half = math.floor(remaining / 2)

    if prev ~= "" then
      if #prev <= half then
        parts.prev = prev
      else
        -- keep the TAIL of prev (closest to the highlight)
        local s = #prev - half + 1
        parts.prev = prev:sub(s)
        parts.prev = parts.prev:gsub("^[\128-\191]+", "")
        parts.prev = util.fixUtf8(parts.prev, "_")
      end
    end

    if next ~= "" then
      if #next <= half then
        parts.next = next
      else
        -- keep the HEAD of next (closest to the highlight)
        local e = half
        parts.next = next:sub(1, e)
        parts.next = parts.next:gsub("[\128-\191]+$", "")
        parts.next = util.fixUtf8(parts.next, "_")
      end
    end
  else
    -- current alone exceeds the budget: keep its HEAD only
    parts.current = current:sub(1, max_chars)
    parts.current = parts.current:gsub("[\128-\191]+$", "")
    parts.current = util.fixUtf8(parts.current, "_")
  end

  local out = {}
  if parts.prev and parts.prev ~= "" then table.insert(out, parts.prev) end
  if parts.current and parts.current ~= "" then table.insert(out, parts.current) end
  if parts.next and parts.next ~= "" then table.insert(out, parts.next) end
  return table.concat(out, "\n\n")
end

local phase2_tests = {
    test("assemblePageContext: all empty returns empty string", function()
        assert.equal(assemblePageContext("", "", "", 6000), "",
            "all-empty input should yield empty string")
        assert.equal(assemblePageContext(nil, nil, nil, 6000), "",
            "nil inputs should yield empty string")
    end),

    test("assemblePageContext: only current within budget returned unchanged", function()
        assert.equal(assemblePageContext("", "hello world", "", 6000), "hello world",
            "current-only text should pass through unchanged")
    end),

    test("assemblePageContext: short segments joined in order with blank lines", function()
        local out = assemblePageContext("PREV", "CUR", "NEXT", 6000)
        assert.equal(out, "PREV\n\nCUR\n\nNEXT",
            "segments should join prev/current/next separated by blank lines")
    end),

    test("assemblePageContext: over-budget sides keep tail-of-prev / head-of-next", function()
        local prev = string.rep("p", 100)
        local next = string.rep("n", 100)
        local out = assemblePageContext(prev, "CUR", next, 200)
        -- remaining = 197, half = 98 -> prev keeps last 98 chars, next keeps first 98
        local expected = string.rep("p", 98) .. "\n\nCUR\n\n" .. string.rep("n", 98)
        assert.equal(out, expected,
            "prev should be tail-truncated and next head-truncated to half budget each")
    end),

    test("assemblePageContext: current alone exceeding budget keeps head only", function()
        local out = assemblePageContext("", string.rep("c", 300), "", 100)
        assert.equal(out, string.rep("c", 100),
            "over-budget current should keep exactly max_chars head bytes")
    end),

    test("assemblePageContext: UTF-8 truncation does not crash and respects budget", function()
        local current = string.rep("你", 100) -- 300 bytes
        local ok, out = pcall(assemblePageContext, "", current, "", 100)
        assert.isTrue(ok, "mid-character truncation should not error")
        assert.isTrue(#out <= 101, "output should stay within budget (small fixup slack)")
        assert.matches(out, string.rep("你", 33),
            "complete leading characters should be preserved")
    end),

    test("assemblePageContext: zero side-budget drops side segments gracefully", function()
        -- remaining = 1 -> half = 0 -> prev cannot fit and is dropped without error
        local out = assemblePageContext("pp", string.rep("c", 9), "", 10)
        assert.equal(out, string.rep("c", 9),
            "side segment with zero budget should be dropped, current intact")
    end),
}

-- =========================================================================
-- 7. Phase-2: inline copy of the page-text injection decision logic
-- (from AssistantDialog:_buildBookContextMessage, assistant_dialog.lua:325-334)
-- =========================================================================

local function append_page_text_block(highlighted_text, include_page_text, page_text)
  if highlighted_text and highlighted_text ~= ""
      and include_page_text then
    if page_text ~= "" then
      return string.format(
        "\n\nSurrounding text from the book (for reference only - the task applies ONLY to the highlighted passage):\n```\n%s\n```",
        page_text)
    end
  end
  return ""
end

table.insert(phase2_tests,
    test("page-text injection: skipped when highlight is empty", function()
        assert.equal(append_page_text_block("", true, "some text"), "",
            "no highlight should mean no page-text block")
    end))

table.insert(phase2_tests,
    test("page-text injection: skipped when switch is off", function()
        assert.equal(append_page_text_block("hl", false, "some text"), "",
            "include_page_text=false should mean no page-text block")
    end))

table.insert(phase2_tests,
    test("page-text injection: skipped when extracted text is empty", function()
        assert.equal(append_page_text_block("hl", true, ""), "",
            "empty extraction (e.g. scanned PDF) should mean no page-text block")
    end))

table.insert(phase2_tests,
    test("page-text injection: appended block is fenced and scope-limited", function()
        local out = append_page_text_block("hl", true, "nearby book text")
        assert.matches(out, "Surrounding text from the book",
            "block should carry the surrounding-text marker sentence")
        assert.matches(out, "ONLY to the highlighted passage",
            "block must instruct the model to apply the task only to the highlight")
        assert.matches(out, "```", "block should wrap the text in a code fence")
        assert.matches(out, "nearby book text", "block should contain the extracted text")
    end))

for _, t in ipairs(phase2_tests) do
    table.insert(tests, t)
end

return helper.runTests("assistant_prompts.lua", tests)
