package.path = "./?.lua;" .. package.path
local BookFilter = require("assistant_book_filter")

local function eq(got, want, msg)
  assert(got == want, (msg or "assert") .. " — expected [" .. tostring(want) .. "] got [" .. tostring(got) .. "]")
end

local mm = { title = "Middlemarch - George Eliot", authors = "George Eliot" }

eq(BookFilter.matches(nil, mm), true, "nil filter")
eq(BookFilter.matches({ title_contains = "middlemarch" }, mm), true, "title ci match")
eq(BookFilter.matches({ title_contains = "Bleak House" }, mm), false, "title no match")
eq(BookFilter.matches({ author_contains = "eliot" }, mm), true, "author ci match")
eq(BookFilter.matches({ author_contains = "Dickens" }, mm), false, "author no match")
eq(BookFilter.matches({ title_contains = "Middlemarch", author_contains = "Eliot" }, mm), true, "both match")
eq(BookFilter.matches({ title_contains = "Middlemarch", author_contains = "Dickens" }, mm), false, "one fails")
eq(BookFilter.matches({ title_contains = "Middlemarch" }, nil), false, "nil props")
eq(BookFilter.matches({ title_contains = "Middlemarch" }, {}), false, "empty props")
eq(BookFilter.matches({}, mm), true, "empty filter table")
-- non-string field → safe false, no crash
eq(BookFilter.matches({ author_contains = "Eliot" }, { title = "X", authors = 42 }), false, "non-string field")

print("book_filter_spec: OK")
