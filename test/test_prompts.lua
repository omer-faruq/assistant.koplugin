-- test_prompts.lua
-- Tests for the Phase-1 prompt-context feature:
--   * built-in prompt flag defaults (use_book_context)
--   * deep-merge override semantics via M.getMergedPrompts
--   * inline copy of AssistantDialog:_buildBookContextMessage content assembly
--   * ASUtils.set_attr/get_attr roundtrip for is_context metadata
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
}

return helper.runTests("assistant_prompts.lua", tests)
