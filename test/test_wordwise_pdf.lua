-- test_wordwise_pdf.lua
-- utils/wordwise_pdf: position keys, the words of a PDF page and the room above a line.
local helper = require("test.helper")
local assert = helper.assert
local PDF = require("utils/wordwise_pdf")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- A word box; lines are lists of words with their own y extent.
local function w(text, x0, x1, y0, y1)
    return { word = text, x0 = x0, x1 = x1, y0 = y0 or 0, y1 = y1 or 10 }
end

local function line(y0, y1, ...)
    local l = { y0 = y0, y1 = y1, x0 = 0, x1 = 100 }
    for _i, word in ipairs({ ... }) do l[#l + 1] = word end
    return l
end

local tests = {
    test("keys sort in document order and compare like the store expects", function()
        local a, b = PDF.key(2, 10, 3), PDF.key(10, 0, 0)
        assert.isTrue(a < b, "zero padding keeps string order")
        assert.equal(PDF.compare(a, b), 1)
        assert.equal(PDF.compare(b, a), -1)
        assert.equal(PDF.compare(a, a), 0)
        assert.equal(PDF.compare(a, "nonsense"), nil)
        local p, l, k = PDF.parse(a)
        assert.equal(p, 2)
        assert.equal(l, 10)
        assert.equal(k, 3)
        assert.equal(PDF.parse(12), nil)
    end),

    test("pageRange: the last page has no end", function()
        local a, b = PDF.pageRange(3, 10)
        assert.equal(a, PDF.key(3, 0, 0))
        assert.equal(b, PDF.key(4, 0, 0))
        local _a, last = PDF.pageRange(10, 10)
        assert.equal(last, nil)
    end),

    test("collect: words in reading order with their keys, text per line", function()
        local boxes = {
            line(0, 10, w("The", 0, 20), w("quick", 25, 60)),
            line(12, 22, w("fox", 0, 20)),
        }
        local words, text = PDF.collect(boxes, 4)
        assert.equal(#words, 3)
        assert.equal(words[2].text, "quick")
        assert.equal(words[2].xp0, PDF.key(4, 1, 2))
        assert.equal(text, "The quick\nfox")
    end),

    test("collect joins a word hyphenated at the end of a line", function()
        local boxes = {
            line(0, 10, w("an", 0, 10), w("inter-", 15, 50)),
            line(12, 22, w("esting", 0, 40), w("book", 45, 80)),
        }
        local words = PDF.collect(boxes, 1)
        assert.equal(#words, 3, "the second half is not a word of its own")
        assert.equal(words[2].text, "interesting")
        assert.equal(words[2].xp0, PDF.key(1, 1, 2))
        assert.equal(words[2].xp1, PDF.key(1, 2, 1), "xp1 points at the second half")
        assert.equal(words[3].text, "book")
    end),

    test("collect does not join when the next word starts with a capital", function()
        local boxes = {
            line(0, 10, w("well-", 0, 40)),
            line(12, 22, w("Known", 0, 40)),
        }
        local words = PDF.collect(boxes, 1)
        assert.equal(#words, 2)
        assert.equal(words[1].text, "well-")
    end),

    test("collect honours the word cap", function()
        local boxes = { line(0, 10, w("a", 0, 1), w("b", 2, 3), w("c", 4, 5)) }
        local words = PDF.collect(boxes, 1, 2)
        assert.equal(#words, 2)
    end),

    test("gapAbove: free space to the nearest line above that overlaps horizontally", function()
        local boxes = {
            line(0, 10, w("top", 0, 50)),
            line(18, 28, w("low", 0, 50)),
            line(18, 28, w("elsewhere", 200, 300)),
        }
        assert.equal(PDF.gapAbove(boxes, 2, 0, 50), 8)
        assert.equal(PDF.gapAbove(boxes, 1, 0, 50), nil, "nothing above the first line")
        assert.equal(PDF.gapAbove(boxes, 3, 200, 300), nil, "no line above in that column")
    end),

    test("gapAbove is never negative when lines overlap", function()
        local boxes = {
            line(0, 12, w("a", 0, 50)),
            line(10, 22, w("b", 0, 50)),
        }
        assert.equal(PDF.gapAbove(boxes, 2, 0, 50), 0)
    end),

    test("hintBottom: close, middle and high inside the gap", function()
        -- line starts at y=100, label 10 high, 30 px of room, no inner reach
        assert.equal(PDF.hintBottom(100, 30, 10, "close"), 99)
        assert.equal(PDF.hintBottom(100, 30, 10, "high"), 99 - 19)
        assert.equal(PDF.hintBottom(100, 30, 10, "middle"), math.floor(99 - 19 / 2))
        assert.equal(PDF.hintBottom(100, 5, 10, "high"), 99, "no room: stays next to the word")
        assert.equal(PDF.hintBottom(100, 30, 10, "close", 4), 103, "inner lets it reach into the line box")
    end),

    test("locate finds the first word and spans a phrase on one line", function()
        local boxes = { line(0, 10, w("pick", 0, 20), w("it", 25, 35), w("up", 40, 55)) }
        local one = PDF.locate(boxes, PDF.key(1, 1, 2), PDF.key(1, 1, 2))
        assert.equal(one.word, "it")
        assert.equal(one.x0, 25)
        local span = PDF.locate(boxes, PDF.key(1, 1, 1), PDF.key(1, 1, 3))
        assert.equal(span.x0, 0)
        assert.equal(span.x1, 55)
        assert.equal(PDF.locate(boxes, PDF.key(1, 9, 1), nil), nil, "a stale position finds nothing")
    end),

    test("pageExtent bounds all the text of the page", function()
        local boxes = {
            line(5, 15, w("a", 10, 40)),
            line(20, 30, w("b", 5, 90)),
        }
        local ext = PDF.pageExtent(boxes)
        assert.equal(ext.x0, 5)
        assert.equal(ext.x1, 90)
        assert.equal(ext.y0, 5)
        assert.equal(ext.y1, 30)
        assert.equal(PDF.pageExtent({}), nil)
    end),
}

return helper.runTests("wordwise_pdf", tests)
