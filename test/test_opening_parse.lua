local helper = require("test.helper")
local assert = helper.assert
local DocUtils = helper.DocUtils
local Prompts = require("core/prompts")

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {

    test("getOpeningText caps output at max chars", function()
        local ui = {
            document = {
                info = { has_pages = true },
                getPageCount = function() return 3 end,
                getPageText = function(self, page)
                    return "ABCDEFGHIJ"
                end,
            },
        }
        local txt = DocUtils.getOpeningText(ui, 12)
        assert.equal(#txt, 12)
    end),

    test("getOpeningText walks reflowable text character by character", function()
        local text = string.rep("abcdefghij", 10) -- 100 chars
        local pos = 0
        local ui = {
            document = {
                info = { has_pages = false },
                getPageXPointer = function() return 0 end,
                getNextVisibleChar = function(self, cur)
                    if pos >= #text then return nil end
                    pos = pos + 1
                    return pos
                end,
                getTextFromXPointers = function(self, from, to)
                    return string.sub(text, from + 1, to)
                end,
            },
        }
        local out = DocUtils.getOpeningText(ui, 12)
        assert.equal(out, "abcdefghijab", "the walk must start at the document start and stop at max chars")

        pos = 0
        out = DocUtils.getOpeningText(ui, 3000)
        assert.equal(out, text, "a long document must be capped by max chars, not by the walk")
        assert.equal(#out, 100)
    end),

    test("getOpeningText returns a document shorter than one screen in full", function()
        -- Regression: gotoPos() is a scroll offset, so a one-screen document
        -- used to collapse to a single character.
        local text = "Short poem."
        local pos = 0
        local ui = {
            document = {
                info = { has_pages = false },
                getPageXPointer = function() return 0 end,
                getNextVisibleChar = function(self, cur)
                    if pos >= #text then return nil end
                    pos = pos + 1
                    return pos
                end,
                getTextFromXPointers = function(self, from, to)
                    return string.sub(text, from + 1, to)
                end,
            },
        }
        assert.equal(DocUtils.getOpeningText(ui, 3000), text)
    end),

    test("getOpeningText yields nothing without a start position", function()
        local ui = {
            document = {
                info = { has_pages = false },
                getPageXPointer = function() return nil end,
                getNextVisibleChar = function() error("must not walk without a start") end,
                getTextFromXPointers = function() error("must not extract without a start") end,
            },
        }
        assert.equal(DocUtils.getOpeningText(ui, 3000), "")
    end),

    test("parseIdentifiedBook handles clean JSON", function()
        local r = DocUtils.parseIdentifiedBook('{"title":"T","authors":["A","B"],"note":"n"}')
        assert.equal(r.title, "T")
        assert.equal(r.authors, "A, B")
        assert.equal(r.description, "n")
    end),

    test("parseIdentifiedBook strips code fences", function()
        local r = DocUtils.parseIdentifiedBook('```json\n{"title":"T","authors":"A","note":"n"}\n```')
        assert.notNil(r)
        assert.equal(r.title, "T")
        assert.equal(r.authors, "A")
    end),

    test("parseIdentifiedBook rejects garbage", function()
        local r = DocUtils.parseIdentifiedBook('not json at all')
        assert.equal(r, nil)
    end),

    test("placeholder substitution survives percent", function()
        local s = "{text}"
        local out = s:gsub("{text}", function() return "50% done" end)
        assert.equal(out, "50% done")
    end),

    test("parse: prose before JSON", function()
        local r = DocUtils.parseIdentifiedBook('Here is the answer: {"title":"T","authors":"A","note":"n"} thanks')
        assert.notNil(r)
        assert.equal(r.title, "T")
    end),

    test("parse: prose after JSON / fenced with trailing sentence", function()
        local r = DocUtils.parseIdentifiedBook('```json\n{"title":"T","authors":"A","note":"n"}\n```\nHope this helps.')
        assert.notNil(r)
        assert.equal(r.title, "T")
    end),

    test("parse: trailing comma tolerated", function()
        local r = DocUtils.parseIdentifiedBook('{"title":"T","authors":["A",],"note":"n",}')
        assert.notNil(r)
        assert.equal(r.authors, "A")
    end),

    test("parse: braces inside strings preserved", function()
        local r = DocUtils.parseIdentifiedBook('{"title":"A {novel}","authors":"X","note":"n"}')
        assert.notNil(r)
        assert.equal(r.title, "A {novel}")
    end),

    test("parse: garbage -> nil", function()
        assert.equal(DocUtils.parseIdentifiedBook('no json here'), nil)
    end),

    test("parse: all-null fields -> nil", function()
        assert.equal(DocUtils.parseIdentifiedBook('{"title":null,"authors":null,"note":""}'), nil)
    end),

    test("identify_book hidden from getSortedPrompts (dialog filter)", function()
        Prompts.invalidateCache()
        local sorted = Prompts.getSortedPrompts(function(prompt)
            if prompt.visible == false then return false end
            return true
        end, false) or {}
        for _, item in ipairs(sorted) do
            if item.idx == "identify_book" then
                error("identify_book must be hidden")
            end
        end
    end),

    test("identify_book hidden from getSortedPrompts (viewer filter)", function()
        Prompts.invalidateCache()
        local sorted = Prompts.getSortedPrompts(function(prompt)
            if prompt.visible == false then return false end
            if (prompt.order or 1000) < 0 then return false end
            return true
        end, false) or {}
        for _, item in ipairs(sorted) do
            if item.idx == "identify_book" then
                error("identify_book must be hidden")
            end
        end
    end),

    test("template: clean single title/author/note", function()
        local r = DocUtils.parseIdentifiedBook("::title{T}::\n::author{A}::\n::note{n}::")
        assert.notNil(r)
        assert.equal(r.title, "T")
        assert.equal(r.authors, "A")
        assert.equal(r.description, "n")
    end),

    test("template: multiple author lines join with comma", function()
        local r = DocUtils.parseIdentifiedBook("::title{T}::\n::author{A}::\n::author{B}::")
        assert.notNil(r)
        assert.equal(r.authors, "A, B")
    end),

    test("template: semicolon-separated names", function()
        local r = DocUtils.parseIdentifiedBook("::title{T}::\n::author{A; B}::")
        assert.notNil(r)
        assert.equal(r.authors, "A, B")
    end),

    test("template: empty braces -> field unknown", function()
        local r = DocUtils.parseIdentifiedBook("::title{}::\n::author{A}::")
        assert.notNil(r)
        assert.equal(r.title, nil)
        assert.equal(r.authors, "A")
    end),

    test("template: omitted line -> field unknown", function()
        local r = DocUtils.parseIdentifiedBook("::author{A}::")
        assert.notNil(r)
        assert.equal(r.title, nil)
        assert.equal(r.authors, "A")
    end),

    test("template: prose/fences around lines ignored", function()
        local r = DocUtils.parseIdentifiedBook("Here you go:\n```\n::title{T}::\n::author{A}::\n```\nDone.")
        assert.notNil(r)
        assert.equal(r.title, "T")
        assert.equal(r.authors, "A")
    end),

    test("template: case-insensitive keys", function()
        local r = DocUtils.parseIdentifiedBook("::Title{T}::\n::Author{A}::")
        assert.notNil(r)
        assert.equal(r.title, "T")
        assert.equal(r.authors, "A")
    end),

    test("template: value with closing brace survives", function()
        local r = DocUtils.parseIdentifiedBook("::title{Rumo {livro} }::\n::author{A}::")
        assert.notNil(r)
        assert.equal(r.title, "Rumo {livro}")
    end),

    test("template: embedded in prose wins", function()
        local r = DocUtils.parseIdentifiedBook("I think ::title{T}:: and ::author{A}:: maybe")
        assert.notNil(r)
        assert.equal(r.title, "T")
        assert.equal(r.authors, "A")
    end),

    test("template and JSON both present -> template wins", function()
        local r = DocUtils.parseIdentifiedBook('::title{Template Title}::\n::author{Tpl Author}::\n{"title":"JSON Title","authors":"JSON Author","note":"n"}')
        assert.notNil(r)
        assert.equal(r.title, "Template Title")
        assert.equal(r.authors, "Tpl Author")
    end),

    test("JSON-only reply still parses via fallback", function()
        local r = DocUtils.parseIdentifiedBook('{"title":"T","authors":"A","note":"n"}')
        assert.notNil(r)
        assert.equal(r.title, "T")
        assert.equal(r.authors, "A")
    end),

    test("template description key parsed", function()
        local r = DocUtils.parseIdentifiedBook("::title{T}::\n::description{Desc}::\n::author{A}::")
        assert.notNil(r)
        assert.equal(r.description, "Desc")
    end),

    test("template note alias fills description when description absent", function()
        local r = DocUtils.parseIdentifiedBook("::title{T}::\n::note{Note}::")
        assert.notNil(r)
        assert.equal(r.description, "Note")
    end),

    test("template description wins when both present", function()
        local r = DocUtils.parseIdentifiedBook("::title{T}::\n::description{Desc}::\n::note{Note}::")
        assert.notNil(r)
        assert.equal(r.description, "Desc")
    end),

    test("template empty description braces -> nil", function()
        local r = DocUtils.parseIdentifiedBook("::title{T}::\n::description{}::")
        assert.notNil(r)
        assert.equal(r.description, nil)
    end),

    test("template garbage -> nil", function()
        assert.equal(DocUtils.parseIdentifiedBook('no usable content here'), nil)
    end),

    test("identify_book use_websearch is enabled in builtin prompt", function()
        assert.equal(Prompts.builtin_prompts.identify_book.use_websearch, true)
    end),

    test("identify mode resolves enabled to configured key", function()
        local Prompts2 = require("core/prompts")
        local pc = (Prompts2.builtin_prompts or {}).identify_book or {}
        local koutil = require("util")
        local settings_val = "tavilyapi"
        local mode = koutil.tableGetValue(pc, "use_websearch") and settings_val or "none"
        assert.equal(mode, "tavilyapi")
    end),

    test("identify mode resolves disabled/unset to none", function()
        local koutil = require("util")
        local mode = false and "tavilyapi" or "none"
        assert.equal(mode, "none")
    end),


    test("identifyWithRetry: garbage first then tagged lines", function()
        local calls = 0
        local qf = function(history)
            calls = calls + 1
            if calls == 1 then
                return "The user wants ... Likely they want to ...", nil
            end
            -- ensure corrective message present in second request history
            local found = false
            for _, m in ipairs(history) do
                if type(m.content) == "string" and m.content:find("Reply ONLY", 1, true) then
                    found = true
                end
            end
            assert.isTrue(found, "corrective message must be present")
            return "::title{T}::\n::author{A}::", nil
        end
        local parsed, answer = DocUtils.identifyWithRetry(qf, {}, "Reply ONLY with lines...")
        assert.notNil(parsed)
        assert.equal(parsed.title, "T")
        assert.equal(parsed.authors, "A")
        assert.equal(calls, 2)
    end),

    test("identifyWithRetry: both replies unusable -> nil and two calls", function()
        local calls = 0
        local qf = function(history)
            calls = calls + 1
            return "still narration garbage", nil
        end
        local parsed = DocUtils.identifyWithRetry(qf, {}, "Reply ONLY with lines...")
        assert.equal(parsed, nil)
        assert.equal(calls, 2)
    end),


    test("buildIdentifyUserMessage contains excerpt exactly once", function()
        local instr = "Rules... Opening excerpt follows."
        local opening = "ABC opening text"
        local msg = DocUtils.buildIdentifyUserMessage(instr, opening)
        assert.matches(msg, instr)
        -- excerpt occurs once
        local count = 0
        local pos = 1
        while true do
            local f = msg:find(opening, pos, true)
            if not f then break end
            count = count + 1
            pos = f + #opening
        end
        assert.equal(count, 1)
    end),

    test("resolveWebSearchMode normalization", function()
        -- access via module table
        local Querier = require("core/querier")
        local r = Querier.resolveWebSearchMode
        assert.equal(r(false, "tavilyapi"), "none")
        assert.equal(r(true, "tavilyapi"), "tavilyapi")
        assert.equal(r("none", "tavilyapi"), "none")
        assert.equal(r("tavilyapi", "x"), "tavilyapi")
        assert.equal(r(nil, "tavilyapi"), "tavilyapi")
    end),

    test("buildIdentifyConfirmMessage: description appended outside placeholders", function()
        local msg = DocUtils.buildIdentifyConfirmMessage(
            { title = "T", authors = "A", description = "D" })
        assert.matches(msg, "Title: T")
        assert.matches(msg, "Author: A")
        assert.matches(msg, "Description: D")
        assert.notMatches(msg, "%%")
    end),

    test("buildIdentifyConfirmMessage: missing description leaves no %N", function()
        local msg = DocUtils.buildIdentifyConfirmMessage({ title = "T", authors = "A" })
        assert.notMatches(msg, "%%")
        assert.notMatches(msg, "Description:")
    end),

    test("buildIdentifyConfirmMessage: unknown fields fall back", function()
        local msg = DocUtils.buildIdentifyConfirmMessage({})
        assert.matches(msg, "Title: Unknown Title")
        assert.matches(msg, "Author: Unknown Author")
        assert.notMatches(msg, "%%")
    end),
}

local maturity_tests = {
test("parse: empty template -> nil, no_data", function()
        local p, st = DocUtils.parseIdentifiedBook("::title{}::\n::author{}::")
        assert.equal(p, nil)
        assert.equal(st, "no_data")
    end),

    test("parse: placeholder-echo template -> nil, no_data", function()
        local p, st = DocUtils.parseIdentifiedBook("::title{<title>}::\n::author{<author>}::\n::description{<description>}::")
        assert.equal(p, nil)
        assert.equal(st, "no_data")
    end),

    test("parse: JSON with placeholder values -> nil, no_data", function()
        local p, st = DocUtils.parseIdentifiedBook('{"title":"<title>","authors":"<author>","description":"<description>"}')
        assert.equal(p, nil)
        assert.equal(st, "no_data")
    end),

    test("parse: all-null JSON -> nil, no_data", function()
        local p, st = DocUtils.parseIdentifiedBook('{"title":null,"authors":null,"description":null}')
        assert.equal(p, nil)
        assert.equal(st, "no_data")
    end),

    test("parse: garbage -> nil, unparseable", function()
        local p, st = DocUtils.parseIdentifiedBook('no json here at all')
        assert.equal(p, nil)
        assert.equal(st, "unparseable")
    end),

    test("parse: mixed empty template + real JSON -> JSON used, ok", function()
        local p, st = DocUtils.parseIdentifiedBook('::title{}::\n{"title":"Real","authors":"Auth","description":"Desc"}')
        assert.notNil(p)
        assert.equal(st, "ok")
        assert.equal(p.title, "Real")
        assert.equal(p.description, "Desc")
    end),

    test("identifyWithRetry: no_data first reply makes no retry", function()
        local calls = 0
        local qf = function(history)
            calls = calls + 1
            return "::title{}::\n::author{}::", nil
        end
        local parsed, answer, status = DocUtils.identifyWithRetry(qf, {}, "corrective")
        assert.equal(parsed, nil)
        assert.equal(status, "no_data")
        assert.equal(calls, 1)
    end),

    test("identifyWithRetry: garbage then tagged lines retries and succeeds", function()
        local calls = 0
        local qf = function(history)
            calls = calls + 1
            if calls == 1 then return "The user wants ... Likely they want to ...", nil end
            return "::title{T}::\n::author{A}::", nil
        end
        local parsed, answer, status = DocUtils.identifyWithRetry(qf, {}, "corrective")
        assert.notNil(parsed)
        assert.equal(status, "ok")
        assert.equal(calls, 2)
    end),
}
helper.runTests("opening_parse_maturity", maturity_tests)
return helper.runTests("opening_parse", tests)
