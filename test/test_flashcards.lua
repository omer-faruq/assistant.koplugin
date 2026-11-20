local helper = require("test.helper")
local assert = helper.assert
local Flashcards = require("feature/flashcards")

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("parseResponse: accepts JSON and trims card text", function()
        local cards, err = Flashcards.parseResponse(
            '{"cards":[{"question":"  What is a model? ","answer":" A simplified representation. "}] }'
        )

        assert.notNil(cards, err)
        assert.equal(#cards, 1)
        assert.equal(cards[1].question, "What is a model?")
        assert.equal(cards[1].answer, "A simplified representation.")
    end),

    test("parseResponse: accepts fenced JSON with surrounding text", function()
        local cards, err = Flashcards.parseResponse(
            'Flashcards:\n```json\n{"cards":[{"question":"Why?","answer":"Because."}]}\n```'
        )

        assert.notNil(cards, err)
        assert.equal(#cards, 1)
        assert.equal(cards[1].question, "Why?")
    end),

    test("parseResponse: rejects malformed JSON and incomplete cards", function()
        local malformed, malformed_err = Flashcards.parseResponse('{"cards":[')
        assert.equal(malformed, nil)
        assert.notNil(malformed_err)

        local incomplete, incomplete_err = Flashcards.parseResponse(
            '{"cards":[{"question":"Only a question","answer":"  " }]}'
        )
        assert.equal(incomplete, nil)
        assert.notNil(incomplete_err)
    end),

    test("buildTSV: writes two tab-separated fields per card", function()
        local tsv, err = Flashcards.buildTSV({
            { question = "Question one", answer = "Answer one" },
            { question = "Question two", answer = "Answer two" },
        })

        assert.notNil(tsv, err)
        assert.equal(tsv, "Question one\tAnswer one\nQuestion two\tAnswer two\n")
    end),

    test("buildTSV: removes tabs and line breaks from card fields", function()
        local tsv, err = Flashcards.buildTSV({
            { question = "What is\tthis?", answer = "A line one\nline two." },
        })

        assert.notNil(tsv, err)
        assert.equal(tsv, "What is this?\tA line one line two.\n")
    end),

    test("buildTSV: rejects empty or incomplete card sets", function()
        local empty, empty_err = Flashcards.buildTSV({})
        assert.equal(empty, nil)
        assert.notNil(empty_err)

        local incomplete, incomplete_err = Flashcards.buildTSV({
            { question = "Question only", answer = "" },
        })
        assert.equal(incomplete, nil)
        assert.notNil(incomplete_err)
    end),
}

return helper.runTests("flashcards", tests)
