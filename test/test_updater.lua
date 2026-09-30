-- test_updater.lua
-- Tests for the pure helper functions exported from assistant_updater.lua:
--   isVersionNewer, is_excluded_with, parse_ignore_content
--
-- The ignore tests parse the real .releaseignore from the project root and
-- feed the resulting patterns to is_excluded_with, so they exercise the same
-- matcher the OTA installer uses. The destructive otaUpgrade/do_install path
-- itself is not tested headlessly.
local helper = require("test.helper")
local assert = helper.assert
local updater = require("assistant_updater")

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_releaseignore()
    local f = io.open(project_root .. ".releaseignore", "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local release_pats = updater.parse_ignore_content(read_releaseignore())

local function excluded(path)
    assert.isTrue(release_pats ~= nil, ".releaseignore must be readable and parse to patterns")
    return updater.is_excluded_with(path, release_pats)
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {

    -- =========================================================================
    -- isVersionNewer
    -- =========================================================================

    test("isVersionNewer: nil/empty returns false", function()
        assert.isFalse(updater.isVersionNewer(nil, "1.0"))
        assert.isFalse(updater.isVersionNewer("1.0", nil))
        assert.isFalse(updater.isVersionNewer(nil, nil))
    end),

    test("isVersionNewer: major version comparison", function()
        assert.isTrue(updater.isVersionNewer("2.0", "1.0"))
        assert.isFalse(updater.isVersionNewer("1.0", "2.0"))
        assert.isFalse(updater.isVersionNewer("1.0", "1.0"))
    end),

    test("isVersionNewer: minor version comparison", function()
        assert.isTrue(updater.isVersionNewer("1.2", "1.1"))
        assert.isFalse(updater.isVersionNewer("1.1", "1.2"))
    end),

    test("isVersionNewer: patch version comparison", function()
        assert.isTrue(updater.isVersionNewer("1.0.2", "1.0.1"))
        assert.isFalse(updater.isVersionNewer("1.0.1", "1.0.2"))
    end),

    test("isVersionNewer: unequal length versions", function()
        assert.isTrue(updater.isVersionNewer("2", "1.9.9"))
        assert.isFalse(updater.isVersionNewer("1.9", "2.0"))
        assert.isTrue(updater.isVersionNewer("1.9.1", "1.9"))
    end),

    test("isVersionNewer: release vs pre-release", function()
        assert.isTrue(updater.isVersionNewer("1.0.0", "1.0.0-rc.1"))
        assert.isFalse(updater.isVersionNewer("1.0.0-rc.1", "1.0.0"))
    end),

    test("isVersionNewer: pre-release comparison (numeric)", function()
        assert.isTrue(updater.isVersionNewer("1.0.0-rc.2", "1.0.0-rc.1"))
        assert.isFalse(updater.isVersionNewer("1.0.0-rc.1", "1.0.0-rc.2"))
    end),

    test("isVersionNewer: pre-release comparison (numeric vs non-numeric)", function()
        -- Numeric identifiers have lower precedence than non-numeric (SemVer spec)
        assert.isFalse(updater.isVersionNewer("1.0.0-1", "1.0.0-alpha"))
        assert.isTrue(updater.isVersionNewer("1.0.0-alpha", "1.0.0-1"))
    end),

    test("isVersionNewer: pre-release with different lengths", function()
        assert.isTrue(updater.isVersionNewer("1.0.0-alpha.1", "1.0.0-alpha"))
        assert.isFalse(updater.isVersionNewer("1.0.0-alpha", "1.0.0-alpha.1"))
    end),

    test("isVersionNewer: equal versions return false", function()
        assert.isFalse(updater.isVersionNewer("1.2.3", "1.2.3"))
        assert.isFalse(updater.isVersionNewer("1.0.0-rc.1", "1.0.0-rc.1"))
    end),

    test("isVersionNewer: handles 'v' prefix", function()
        -- isVersionNewer doesn't strip 'v' prefix, so "v2.0" is treated as non-numeric
        -- but main version parse uses %d+, so it correctly extracts 2 and 0
        assert.isTrue(updater.isVersionNewer("v2.0", "v1.0"))
        assert.isFalse(updater.isVersionNewer("v1.0", "v2.0"))
    end),

    -- =========================================================================
    -- parse_ignore_content
    -- =========================================================================

    test("parse_ignore_content: nil/empty content yields nil", function()
        assert.isTrue(updater.parse_ignore_content(nil) == nil)
        assert.isTrue(updater.parse_ignore_content("") == nil)
    end),

    test("parse_ignore_content: skips blanks, comments and trims", function()
        local pats = updater.parse_ignore_content("# comment\n\n   docs/   \n\t\n*.md\n")
        assert.equal(2, #pats)
        assert.equal("docs", pats[1].core)
        assert.isTrue(pats[1].is_dir)
        assert.equal("*.md", pats[2].core)
        assert.isFalse(pats[2].is_dir)
        assert.isFalse(pats[2].neg)
    end),

    test("parse_ignore_content: '!' marks a negation and drops the marker", function()
        local pats = updater.parse_ignore_content("*.mo\n!l10n/fr/assistant.mo\n")
        assert.equal(2, #pats)
        assert.isFalse(pats[1].neg)
        assert.isTrue(pats[2].neg)
        assert.equal("l10n/fr/assistant.mo", pats[2].core)
    end),

    -- =========================================================================
    -- is_excluded_with against the real .releaseignore
    -- =========================================================================

    test("is_excluded_with: plain pattern from .releaseignore", function()
        -- ".*" entry excludes dot-prefixed names
        assert.isTrue(excluded(".gitignore"))
        assert.isTrue(excluded(".github/workflows/release.yml"))
        assert.isFalse(excluded("main.lua"))
    end),

    test("is_excluded_with: glob crossing '/' from .releaseignore", function()
        -- '*' matches any chars including '/', so "*.md" hits at any depth
        assert.isTrue(excluded("README.md"))
        assert.isTrue(excluded("docs/ARCHITECTURE.md"))
        -- and '**' spans several path segments
        assert.isTrue(excluded("l10n/fr/assistant.pot"))
        assert.isTrue(excluded("l10n/nested/deeper/assistant.pot"))
    end),

    test("is_excluded_with: directory-prefix entries from .releaseignore", function()
        assert.isTrue(excluded("docs/guide.md"))
        assert.isTrue(excluded("test/run.sh"))
        assert.isTrue(excluded("l10n/Makefile"))
        assert.isFalse(excluded("l10n/fr/assistant.mo"))
    end),

    test("is_excluded_with: shippable sources are kept", function()
        assert.isFalse(excluded("main.lua"))
        assert.isFalse(excluded("assistant_updater.lua"))
        assert.isFalse(excluded("api_handlers/openai.lua"))
        assert.isFalse(excluded("configuration.lua"))
        assert.isFalse(excluded("lib/libhoedown.so.3"))
    end),

    test("is_excluded_with: strips ./, leading / and plugin-dir prefix", function()
        assert.isTrue(excluded("./README.md"))
        assert.isTrue(excluded("/docs/ARCHITECTURE.md"))
        assert.isTrue(excluded("assistant.koplugin-1.16/README.md"))
    end),

    -- =========================================================================
    -- is_excluded_with with caller-supplied patterns
    -- =========================================================================

    test("is_excluded_with: explicit patterns, last match wins", function()
        local pats = updater.parse_ignore_content("*.mo\n!l10n/fr/assistant.mo\n")
        assert.isTrue(updater.is_excluded_with("l10n/de/assistant.mo", pats))
        assert.isFalse(updater.is_excluded_with("l10n/fr/assistant.mo", pats))
        assert.isFalse(updater.is_excluded_with("l10n/fr/assistant.po", pats))
    end),

    test("is_excluded_with: negation after a directory rule re-includes", function()
        local pats = updater.parse_ignore_content("l10n/\n!l10n/fr/\n")
        assert.isTrue(updater.is_excluded_with("l10n/de/assistant.mo", pats))
        assert.isTrue(updater.is_excluded_with("l10n/de/nested/assistant.po", pats))
        assert.isFalse(updater.is_excluded_with("l10n/fr/assistant.mo", pats))
        assert.isFalse(updater.is_excluded_with("main.lua", pats))
    end),

    test("is_excluded_with: empty path and nil patterns", function()
        local pats = updater.parse_ignore_content("*.md\n")
        assert.isFalse(updater.is_excluded_with("", pats))
        assert.isFalse(updater.is_excluded_with(nil, pats))
        -- no patterns -> legacy fallback rules
        assert.isTrue(updater.is_excluded_with("README.md", nil))
        assert.isFalse(updater.is_excluded_with("main.lua", nil))
    end),
}

return helper.runTests("assistant_updater.lua", tests)
