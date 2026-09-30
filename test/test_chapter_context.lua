-- test_chapter_context.lua
-- Owner of the chapter- and page-text extraction coverage for
-- assistant_doc_utils.lua: getCurrentChapterRange, extractCurrentChapterText
-- (plus the internal getDocumentEndXPointer ladder), and the nearby-page-text
-- helpers getPageRangeText and assemblePageContext.
local helper = require("test.helper")
local assert = helper.assert
local DocUtils = helper.DocUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

-- ---------------------------------------------------------------------------
-- Mock builders
-- ---------------------------------------------------------------------------

-- Mock ReaderToc: entry covering a page = last entry with entry.page <= page
-- (nil when the page is before the first entry), like KOReader.
local function makeToc(entries, opts)
    opts = opts or {}
    return {
        toc = entries,
        fillToc = function(self)
            if opts.empty_on_fill then
                self.toc = {}
            end
        end,
        getTocIndexByPage = function(self, page)
            if opts.always_index_one then
                return 1
            end
            local found
            for i, entry in ipairs(self.toc) do
                if entry.page <= page then
                    found = i
                else
                    break
                end
            end
            return found
        end,
    }
end

-- Mock ui for a reflowable (EPUB-like) document.
local function makeReflowableUI(entries, opts)
    opts = opts or {}
    local calls = { restores = {}, extractions = {}, gotopos = {} }
    local ui
    ui = {
        document = {
            info = { has_pages = false },
            getXPointer = function()
                return "cur_xp"
            end,
            getPageFromXPointer = function(self, xp)
                return opts.page or 5
            end,
            getPageCount = function()
                return opts.page_count or 100
            end,
            getPageXPointer = function(self, page)
                return "xp_p" .. tostring(page)
            end,
            getTextFromXPointers = function(self, xp0, xp1)
                if opts.fail_extraction then
                    error("extraction boom")
                end
                local text = opts.text or ("text:" .. tostring(xp0) .. "->" .. tostring(xp1))
                table.insert(calls.extractions, { xp0 = xp0, xp1 = xp1 })
                return text
            end,
            gotoXPointer = function(self, xp)
                table.insert(calls.restores, xp)
            end,
            gotoPos = function(self, pos)
                table.insert(calls.gotopos, pos)
            end,
            -- Optional engine probes, enabled per test via opts:
            isXPointerInDocument = opts.xp_in_document,
            compareXPointers = opts.compare_xpointers,
        },
        toc = makeToc(entries, opts.toc_opts),
    }
    return ui, calls
end

-- Mock ui for a paged (PDF-like) document.
local function makePagedUI(entries, opts)
    opts = opts or {}
    return {
        document = {
            info = { has_pages = true },
            getPageCount = function()
                return opts.page_count or 100
            end,
            getPageText = function(self, page)
                return opts.page_text and opts.page_text(page) or ("page" .. tostring(page))
            end,
        },
        view = { state = { page = opts.page or 5 } },
        toc = makeToc(entries, opts.toc_opts),
    }
end

local SAMPLE_TOC = {
    { page = 10, title = "Chapter One", depth = 1, xpointer = "xp_c1" },
    { page = 50, title = "Chapter Two", depth = 1, xpointer = "xp_c2" },
    { page = 80, title = "Chapter Three", depth = 1, xpointer = "xp_c3" },
}

local function mockAssistant(featuresOrUi, maybeUi)
    local features, ui
    if maybeUi ~= nil then
        features = featuresOrUi or {}
        ui = maybeUi
    elseif featuresOrUi and (featuresOrUi.document or featuresOrUi.view or featuresOrUi.toc) then
        features = {}
        ui = featuresOrUi
    else
        features = featuresOrUi or {}
        ui = nil
    end
    return {
        ui = ui,
        config = {
            getFeature = function(self, feature_key, default)
                local v = features[feature_key]
                if v ~= nil then return v end
                return default
            end
        },
    }
end

local tests = {

    -- =========================================================================
    -- getPageRangeText: availability guards
    -- =========================================================================

    test("page range: nil ui returns empty string", function()
        assert.equal(DocUtils.getPageRangeText(nil, 1, 1, 6000), "",
            "nil ui should yield empty string")
    end),

    test("page range: ui without document returns empty string", function()
        assert.equal(DocUtils.getPageRangeText({}, 1, 1, 6000), "",
            "missing ui.document should yield empty string")
    end),

    test("page range: document without selection pos0 returns empty string", function()
        assert.equal(DocUtils.getPageRangeText({ document = {} }, 1, 1, 6000), "",
            "missing selection pos0 should yield empty string")
    end),

    -- =========================================================================
    -- assemblePageContext: budget assembly
    -- =========================================================================

    test("assemble: all empty returns empty string", function()
        assert.equal(DocUtils.assemblePageContext("", "", "", 6000), "",
            "all-empty input should yield empty string")
        assert.equal(DocUtils.assemblePageContext(nil, nil, nil, 6000), "",
            "nil inputs should yield empty string")
    end),

    test("assemble: only current within budget returned unchanged", function()
        assert.equal(DocUtils.assemblePageContext("", "hello world", "", 6000), "hello world",
            "current-only text should pass through unchanged")
    end),

    test("assemble: short segments joined in order with blank lines", function()
        local out = DocUtils.assemblePageContext("PREV", "CUR", "NEXT", 6000)
        assert.equal(out, "PREV\n\nCUR\n\nNEXT",
            "segments should join prev/current/next separated by blank lines")
    end),

    test("assemble: over-budget sides keep tail-of-prev / head-of-next", function()
        local prev = string.rep("p", 100)
        local next = string.rep("n", 100)
        local out = DocUtils.assemblePageContext(prev, "CUR", next, 200)
        -- remaining = 197, half = 98 -> prev keeps last 98 chars, next keeps first 98
        local expected = string.rep("p", 98) .. "\n\nCUR\n\n" .. string.rep("n", 98)
        assert.equal(out, expected,
            "prev should be tail-truncated and next head-truncated to half budget each")
    end),

    test("assemble: current alone exceeding budget keeps head only", function()
        local out = DocUtils.assemblePageContext("", string.rep("c", 300), "", 100)
        assert.equal(out, string.rep("c", 100),
            "over-budget current should keep exactly max_chars head bytes")
    end),

    test("assemble: UTF-8 truncation does not crash and respects budget", function()
        local current = string.rep("\228\184\173", 100) -- 300 bytes
        local ok, out = pcall(DocUtils.assemblePageContext, "", current, "", 100)
        assert.isTrue(ok, "mid-character truncation should not error")
        assert.isTrue(#out <= 101, "output should stay within budget (small fixup slack)")
        assert.matches(out, string.rep("\228\184\173", 33),
            "complete leading characters should be preserved")
    end),

    test("assemble: zero side-budget drops side segments gracefully", function()
        -- remaining = 1 -> half = 0 -> prev cannot fit and is dropped without error
        local out = DocUtils.assemblePageContext("pp", string.rep("c", 9), "", 10)
        assert.equal(out, string.rep("c", 9),
            "side segment with zero budget should be dropped, current intact")
    end),

    -- =========================================================================
    -- getCurrentChapterRange: visibility gating (nil cases)
    -- =========================================================================

    test("range: nil when ui is nil", function()
        assert.equal(DocUtils.getCurrentChapterRange(nil), nil)
    end),

    test("range: nil when document missing", function()
        assert.equal(DocUtils.getCurrentChapterRange({ toc = makeToc(SAMPLE_TOC) }), nil)
    end),

    test("range: nil when toc module missing", function()
        local ui = makeReflowableUI(SAMPLE_TOC)
        ui.toc = nil
        assert.equal(DocUtils.getCurrentChapterRange(ui), nil)
    end),

    test("range: nil when TOC is empty after fillToc", function()
        local ui = makeReflowableUI(SAMPLE_TOC, { toc_opts = { empty_on_fill = true } })
        assert.equal(DocUtils.getCurrentChapterRange(ui), nil)
    end),

    test("range: nil when user is before the first TOC entry (outside TOC)", function()
        local ui = makeReflowableUI(SAMPLE_TOC, { page = 3 })
        assert.equal(DocUtils.getCurrentChapterRange(ui), nil)
    end),

    test("range: nil when toc index points past current page (defensive)", function()
        -- getTocIndexByPage implementations that always return 1 must not
        -- yield a bogus range for pages before the first entry.
        local ui = makeReflowableUI(SAMPLE_TOC, {
            page = 3,
            toc_opts = { always_index_one = true },
        })
        assert.equal(DocUtils.getCurrentChapterRange(ui), nil)
    end),

    -- =========================================================================
    -- getCurrentChapterRange: range resolution
    -- =========================================================================

    test("range: reflowable page inside a chapter", function()
        local ui = makeReflowableUI(SAMPLE_TOC, { page = 55 })
        local range = DocUtils.getCurrentChapterRange(ui)
        assert.notNil(range)
        assert.equal(range.start_page, 50)
        assert.equal(range.end_page, 79)
        assert.equal(range.next_page, 80)
        assert.equal(range.title, "Chapter Two")
        assert.equal(range.start_xp, "xp_c2")
        assert.equal(range.end_xp, "xp_c3")
    end),

    test("range: reflowable exactly on a chapter start page", function()
        local ui = makeReflowableUI(SAMPLE_TOC, { page = 50 })
        local range = DocUtils.getCurrentChapterRange(ui)
        assert.notNil(range)
        assert.equal(range.start_page, 50)
        assert.equal(range.end_page, 79)
        assert.equal(range.next_page, 80)
        assert.equal(range.title, "Chapter Two")
    end),

    test("range: last chapter ends at page count with nil end_xp", function()
        local ui = makeReflowableUI(SAMPLE_TOC, { page = 90, page_count = 100 })
        local range = DocUtils.getCurrentChapterRange(ui)
        assert.notNil(range)
        assert.equal(range.start_page, 80)
        assert.equal(range.end_page, 100)
        assert.equal(range.next_page, nil)
        assert.equal(range.title, "Chapter Three")
        assert.equal(range.end_xp, nil)
    end),

    test("range: first chapter starts at first entry", function()
        local ui = makeReflowableUI(SAMPLE_TOC, { page = 10 })
        local range = DocUtils.getCurrentChapterRange(ui)
        assert.notNil(range)
        assert.equal(range.start_page, 10)
        assert.equal(range.end_page, 49)
    end),

    test("range: paged document uses view.state.page", function()
        local ui = makePagedUI(SAMPLE_TOC, { page = 55 })
        local range = DocUtils.getCurrentChapterRange(ui)
        assert.notNil(range)
        assert.equal(range.start_page, 50)
        assert.equal(range.end_page, 79)
        assert.equal(range.title, "Chapter Two")
    end),

    -- =========================================================================
    -- extractCurrentChapterText: reflowable
    -- =========================================================================

    test("extract: reflowable uses entry xpointers and restores position", function()
        local ui, calls = makeReflowableUI(SAMPLE_TOC, { page = 55 })
        local text = DocUtils.extractCurrentChapterText(mockAssistant(ui))
        assert.equal(text, "text:xp_c2->xp_c3")
        assert.equal(#calls.extractions, 1)
        assert.equal(calls.extractions[1].xp0, "xp_c2")
        assert.equal(calls.extractions[1].xp1, "xp_c3")
        -- xpointer restored after extraction
        assert.equal(#calls.restores, 1)
        assert.equal(calls.restores[1], "cur_xp")
    end),

    test("extract: reflowable falls back to next-chapter page xpointer when entries lack them", function()
        local entries = {
            { page = 10, title = "Chapter One", depth = 1 },
            { page = 50, title = "Chapter Two", depth = 1 },
        }
        local ui = makeReflowableUI(entries, { page = 20 })
        local text = DocUtils.extractCurrentChapterText(mockAssistant(ui))
        -- end xpointer = start of next chapter's page: includes page 49 fully
        assert.equal(text, "text:xp_p10->xp_p50")
    end),

    test("extract: last chapter falls back to page xpointer of page count", function()
        local entries = {
            { page = 10, title = "Chapter One", depth = 1 },
        }
        -- Minimal mock: no isXPointerInDocument/compareXPointers/gotoPos,
        -- so the end-of-document ladder degrades to the last page xpointer.
        local ui = makeReflowableUI(entries, { page = 90, page_count = 100 })
        local text = DocUtils.extractCurrentChapterText(mockAssistant(ui))
        assert.equal(text, "text:xp_p10->xp_p100")
    end),

    test("extract: last chapter prefers post-last-page xpointer when engine validates it", function()
        local entries = {
            { page = 10, title = "Chapter One", depth = 1 },
        }
        local ui, calls = makeReflowableUI(entries, {
            page = 90,
            page_count = 100,
            xp_in_document = function(self, xp)
                return true
            end,
            compare_xpointers = function(self, xp1, xp2)
                return 1
            end,
        })
        local text = DocUtils.extractCurrentChapterText(mockAssistant(ui))
        -- xpointer of the page after the last is accepted as document end
        assert.equal(text, "text:xp_p10->xp_p101")
        -- view position restored (ladder's own restore + extraction restore)
        assert.equal(#calls.restores, 2)
        assert.equal(calls.restores[1], "cur_xp")
        assert.equal(calls.restores[2], "cur_xp")
    end),

    test("extract: nil when chapter range unavailable", function()
        local ui = makeReflowableUI(SAMPLE_TOC, { page = 3 })
        assert.equal(DocUtils.extractCurrentChapterText(mockAssistant(ui)), nil)
    end),

    test("extract: extraction error returns nil but still restores position", function()
        local ui, calls = makeReflowableUI(SAMPLE_TOC, {
            page = 55,
            fail_extraction = true,
        })
        local text = DocUtils.extractCurrentChapterText(mockAssistant(ui))
        assert.equal(text, nil)
        assert.equal(#calls.restores, 1)
        assert.equal(calls.restores[1], "cur_xp")
    end),

    test("extract: tail truncation honors max_text_length_for_analysis", function()
        local big = string.rep("x", 5000)
        local ui = makeReflowableUI(SAMPLE_TOC, { page = 55, text = big })
        local text = DocUtils.extractCurrentChapterText(
            mockAssistant({ max_text_length_for_analysis = 1000 }, ui))
        assert.notNil(text)
        assert.equal(#text, 1000)
        -- tail kept: must equal the last 1000 characters of the source text
        assert.equal(text, big:sub(-1000))
    end),

    test("extract: short chapter text is returned unmodified", function()
        local ui = makeReflowableUI(SAMPLE_TOC, { page = 55, text = "short chapter" })
        local text = DocUtils.extractCurrentChapterText(
            mockAssistant({ max_text_length_for_analysis = 1000 }, ui))
        assert.equal(text, "short chapter")
    end),

    -- =========================================================================
    -- extractCurrentChapterText: paged documents
    -- =========================================================================

    test("extract: paged document concatenates chapter pages", function()
        local ui = makePagedUI(SAMPLE_TOC, { page = 55 })
        local text = DocUtils.extractCurrentChapterText(mockAssistant(ui))
        assert.matches(text, "page50")
        assert.matches(text, "page79")
        assert.notMatches(text, "page49")
        assert.notMatches(text, "page80")
    end),

    test("extract: paged document handles block/word table shape", function()
        local ui = makePagedUI(SAMPLE_TOC, {
            page = 55,
            page_text = function(page)
                return { { { word = "Hello" }, { word = "page" }, { word = tostring(page) } } }
            end,
        })
        local text = DocUtils.extractCurrentChapterText(mockAssistant(ui))
        assert.matches(text, "Hello page 50")
        assert.matches(text, "Hello page 51")
    end),

    test("extract: paged document tail truncation", function()
        local ui = makePagedUI(SAMPLE_TOC, { page = 55 })
        local text = DocUtils.extractCurrentChapterText(
            mockAssistant({ max_text_length_for_analysis = 10 }, ui))
        assert.notNil(text)
        assert.equal(#text, 10)
    end),
}

return helper.runTests("chapter context (doc_utils)", tests)
