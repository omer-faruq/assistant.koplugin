package.path = "./?.lua;" .. package.path
local Companion = require("assistant_companion")

local function eq(got, want, msg)
  assert(got == want, (msg or "assert") .. " — expected [" .. tostring(want) .. "] got [" .. tostring(got) .. "]")
end

-- standard epub
eq(Companion.getCompanionPath("/Books/Middlemarch.epub"), "/Books/Middlemarch.companion.md", "epub")
-- dotted filename: only the final extension is stripped
eq(Companion.getCompanionPath("/Books/My.Book.epub"), "/Books/My.Book.companion.md", "dotted name")
-- no extension: just append
eq(Companion.getCompanionPath("/Books/README"), "/Books/README.companion.md", "no ext")
-- dot in a directory but not in the filename: don't strip the dir dot
eq(Companion.getCompanionPath("/a.d/Book"), "/a.d/Book.companion.md", "dir dot")
-- nil / empty guard
eq(Companion.getCompanionPath(nil), nil, "nil")
eq(Companion.getCompanionPath(""), nil, "empty")

-- loadCompanion: present file
local base = "/tmp/koassist_test_book.epub"
local comp = "/tmp/koassist_test_book.companion.md"
local fh = io.open(comp, "w"); fh:write("HELLO COMPANION"); fh:close()
eq(Companion.loadCompanion(base), "HELLO COMPANION", "load present")

-- loadCompanion: empty file -> nil
local fh2 = io.open(comp, "w"); fh2:write(""); fh2:close()
eq(Companion.loadCompanion(base), nil, "load empty")
os.remove(comp)

-- loadCompanion: absent file -> nil (no throw)
eq(Companion.loadCompanion(base), nil, "load absent")

-- loadCompanion: nil path -> nil
eq(Companion.loadCompanion(nil), nil, "load nil")

-- hasCompanion: present non-empty -> true
local fh3 = io.open(comp, "w"); fh3:write("X"); fh3:close()
eq(Companion.hasCompanion(base), true, "has present")
-- hasCompanion: empty file -> false (mirrors loadCompanion's empty == absent)
local fh4 = io.open(comp, "w"); fh4:write(""); fh4:close()
eq(Companion.hasCompanion(base), false, "has empty")
os.remove(comp)
-- hasCompanion: absent file -> false (no throw)
eq(Companion.hasCompanion(base), false, "has absent")
-- hasCompanion: nil path -> false
eq(Companion.hasCompanion(nil), false, "has nil")

print("companion_spec: OK")
