-- test_gettext_ascii_msgids.lua
-- Static guard: gettext msgids must be US-ASCII.
--
-- History: commit 0353186 ("keep msgids ASCII, inject glyphs outside _()")
-- documented that non-ASCII source characters inside msgids trigger gettext's
-- msgattrib header-loss bug -- the fuzzy header is cleared, msgattrib falls
-- back to an ASCII charset, then `invalid multibyte` warnings follow and the
-- glyphs (— , ▸ , … ) are corrupted to double spaces, leaving fuzzy entries.
-- The offenders in that commit spanned U+2011 (‑) through U+1F4A1 (💡), i.e.
-- ANY codepoint outside US-ASCII -- not one narrow range. Unicode dashes
-- (— U+2014, – U+2013, ‑ U+2011) and the ellipsis (… U+2026) are in the bad
-- set; the ASCII hyphen "-" and "..." are the safe replacements.
--
-- This test scans shipped plugin sources (project root + api_handlers/) and
-- fails if a string literal passed to _()/N_()/C_()/NC_() contains a byte
-- > 0x7F. Inject glyphs outside the call instead:
--   "🌐 " .. _("Web Search")
--   T(_("%1 Provider NOT CONFIGURED"), "▸")
--   _("Provider Name - shown in menus")
--
-- Scope mirrors test_gettext_loop_shadow.lua: test/, l10n/, lib/ (vendored)
-- and the user-owned configuration.lua are skipped.
local helper = require("test.helper")
local assert = helper.assert

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not lfs_ok then
    lfs_ok, lfs = pcall(require, "lfs")
end

local GETTEXT_NAMES = { "_", "N_", "C_", "NC_" }

-- Blank out Lua comments while preserving offsets and newlines, so a
-- commented-out sample like `-- _("…")` never trips the scanner.
local function strip_comments(src)
    local out = {}
    local i, n = 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then
                    j = j + 2
                elseif d == c then
                    j = j + 1
                    break
                else
                    j = j + 1
                end
            end
            out[#out + 1] = src:sub(i, j - 1)
            i = j
        elseif c == "-" and src:sub(i + 1, i + 1) == "-" then
            local eq = src:match("^%-%-%[(=*)%[", i)
            local stop
            if eq then
                local close = "]" .. eq .. "]"
                local s = src:find(close, i + 2 + #eq + 2, true)
                stop = s and (s + #close - 1) or n
            else
                local nl = src:find("\n", i, true)
                stop = nl and (nl - 1) or n
            end
            out[#out + 1] = src:sub(i, stop):gsub("[^\n]", " ")
            i = stop + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Decode a quoted Lua string literal starting at `i`; returns its text and
-- the index just past the closing quote. Escape tails are ASCII, so their
-- exact decoding does not matter for the ASCII check.
local function read_literal(src, i)
    local quote = src:sub(i, i)
    local buf = {}
    local j = i + 1
    while j <= #src do
        local c = src:sub(j, j)
        if c == "\\" then
            buf[#buf + 1] = src:sub(j + 1, j + 1)
            j = j + 2
        elseif c == quote then
            return table.concat(buf), j + 1
        else
            buf[#buf + 1] = c
            j = j + 1
        end
    end
    return table.concat(buf), j
end

-- Collect every string literal argument of a _()/N_()/C_()/NC_() call, with
-- its source offset.
local function collect_msgids(src)
    local results = {}
    local i, n = 1, #src
    while i <= n do
        local matched
        for _, name in ipairs(GETTEXT_NAMES) do
            if src:sub(i, i + #name - 1) == name then
                local prev = i > 1 and src:sub(i - 1, i - 1) or ""
                if not prev:match("[%w_%.%:]") then
                    local j = i + #name
                    while j <= n and src:sub(j, j):match("%s") do j = j + 1 end
                    if src:sub(j, j) == "(" then
                        matched = name
                        i = j + 1
                        break
                    end
                end
            end
        end
        if not matched then
            i = i + 1
        else
            local depth = 1
            while i <= n and depth > 0 do
                local c = src:sub(i, i)
                if c == "(" then
                    depth = depth + 1
                    i = i + 1
                elseif c == ")" then
                    depth = depth - 1
                    i = i + 1
                elseif c == '"' or c == "'" then
                    local start = i
                    local lit
                    lit, i = read_literal(src, i)
                    results[#results + 1] = { text = lit, pos = start }
                else
                    i = i + 1
                end
            end
        end
    end
    return results
end

local function non_ascii_codepoints(s)
    local cps = {}
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        if b < 128 then
            i = i + 1
        else
            local len, cp
            if b >= 0xF0 then
                len, cp = 4, b % 0x08
            elseif b >= 0xE0 then
                len, cp = 3, b % 0x10
            else
                len, cp = 2, b % 0x20
            end
            for k = 1, len - 1 do
                local nb = s:byte(i + k)
                if nb then cp = cp * 64 + (nb % 64) end
            end
            cps[#cps + 1] = string.format("U+%04X", cp)
            i = i + len
        end
    end
    return cps
end

-- Returns every non-ASCII msgid in `src` as { pos, text, cps }.
local function violations_in(src)
    local clean = strip_comments(src)
    local bad = {}
    for _, m in ipairs(collect_msgids(clean)) do
        local cps = non_ascii_codepoints(m.text)
        if #cps > 0 then
            bad[#bad + 1] = { pos = m.pos, text = m.text, cps = cps }
        end
    end
    return bad
end

local function line_of(src, pos)
    local _, count = src:sub(1, pos):gsub("\n", "")
    return count + 1
end

local function collect_source_files()
    local files = {}
    if not project_root then return files end
    local function add_dir(dir)
        if not (lfs and lfs.attributes and lfs.attributes(dir, "mode") == "directory") then
            return
        end
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".."
                and entry ~= "configuration.lua"
                and entry:match("%.lua$") then
                files[#files + 1] = dir .. entry
            end
        end
    end
    add_dir(project_root)
    add_dir(project_root .. "api_handlers/")
    return files
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("scanner self-check: catches non-ASCII msgids, allows injected glyphs", function()
        -- Unicode dash inside _() must be flagged.
        local bad = violations_in('local x = _("a - b") .. _("a — b")')
        assert.equal(#bad, 1, "expected the em-dash msgid to be flagged")
        assert.equal(bad[1].cps[1], "U+2014")

        -- Glyphs concatenated/placed outside _() are allowed.
        assert.equal(#violations_in('local x = "🌐 " .. _("Web Search")'), 0)
        assert.equal(#violations_in('local x = T(_("%1 NOT CONFIGURED"), "▸")'), 0)

        -- ASCII hyphen and three-dot ellipsis are fine inside _().
        assert.equal(#violations_in('local x = _("Provider Name - shown ...")'), 0)

        -- Commented-out samples are ignored.
        assert.equal(#violations_in('-- _("bad — sample")'), 0)
    end),

    test("shipped sources: all gettext msgids are US-ASCII", function()
        assert.notNil(project_root, "could not locate project root")
        assert.isTrue(lfs_ok and lfs ~= nil, "lfs is unavailable; cannot scan sources")
        local files = collect_source_files()
        assert.isTrue(#files > 0, "no source files found to scan")

        local offenders = {}
        for _, path in ipairs(files) do
            local f = io.open(path, "r")
            if f then
                local src = f:read("*a")
                f:close()
                for _, v in ipairs(violations_in(src)) do
                    local rel = path:gsub("^" .. project_root:gsub("%W", "%%%0"), "")
                    offenders[#offenders + 1] = string.format("%s:%d  %s  [%s]",
                        rel, line_of(src, v.pos), v.text, table.concat(v.cps, " "))
                end
            end
        end

        if #offenders > 0 then
            error("non-ASCII gettext msgid(s) found:\n  " .. table.concat(offenders, "\n  ")
                .. "\nMove the glyph outside _() (e.g. \"🌐 \" .. _(\"Web Search\"), "
                .. "T(_(\"%1\"), \"▸\")) or use ASCII punctuation (- and ...).", 2)
        end
    end),
}

return helper.runTests("gettext_ascii_msgids", tests)
