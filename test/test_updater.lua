-- test_updater.lua
-- Tests for the pure helper functions exported from core/updater.lua:
--   isVersionNewer, is_excluded_with, parse_ignore_content,
--   extractRepoFromUrl, parseOtaInput, isValidPluginMeta,
--   isValidPluginReleaseIgnore, validatePluginFiles
--
-- The ignore and identity tests read the real .releaseignore and _meta.lua from
-- the project root, so they exercise the same matchers the OTA installer uses.
-- The destructive otaUpgrade/do_install path itself is not tested headlessly.
local helper = require("test.helper")
local assert = helper.assert
local updater = require("core/updater")

local project_root = debug.getinfo(1).source:match("@(.*/)test/")

local function read_project_file(name)
    local f = io.open(project_root .. name, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function read_releaseignore()
    return read_project_file(".releaseignore")
end

local release_pats = updater.parse_ignore_content(read_releaseignore())
local releaseignore_content = read_releaseignore()
local meta_content = read_project_file("_meta.lua")

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
        assert.isFalse(excluded("core/updater.lua"))
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

    -- =========================================================================
    -- extractRepoFromUrl
    -- =========================================================================

    test("extractRepoFromUrl: parses the default codeload URL", function()
        local repo, host = updater.extractRepoFromUrl("https://codeload.github.com/omer-faruq/assistant.koplugin")
        assert.equal("omer-faruq/assistant.koplugin", repo)
        assert.equal("https://codeload.github.com", host)
    end),

    test("extractRepoFromUrl: trims surrounding space and trailing slashes", function()
        local repo, host = updater.extractRepoFromUrl("  https://codeload.github.com/other/fork///  ")
        assert.equal("other/fork", repo)
        assert.equal("https://codeload.github.com", host)
    end),

    test("extractRepoFromUrl: keeps scheme and port", function()
        local repo, host = updater.extractRepoFromUrl("http://localhost:8080/owner/repo")
        assert.equal("owner/repo", repo)
        assert.equal("http://localhost:8080", host)
    end),

    test("extractRepoFromUrl: unparseable input yields nil", function()
        local repo, host = updater.extractRepoFromUrl(nil)
        assert.isTrue(repo == nil and host == nil)
        repo, host = updater.extractRepoFromUrl("")
        assert.isTrue(repo == nil and host == nil)
        repo, host = updater.extractRepoFromUrl("https://codeload.github.com/owner")
        assert.isTrue(repo == nil and host == nil)
        repo, host = updater.extractRepoFromUrl("owner/repo")
        assert.isTrue(repo == nil and host == nil)
    end),

    -- =========================================================================
    -- parseOtaInput
    -- =========================================================================

    test("parseOtaInput: empty input keeps the default repo with main", function()
        local default_repo = "omer-faruq/assistant.koplugin"
        assert.equal(default_repo, select(1, updater.parseOtaInput(nil, default_repo)))
        assert.equal("main", select(2, updater.parseOtaInput(nil, default_repo)))

        local repo, ref = updater.parseOtaInput("   ", default_repo)
        assert.equal(default_repo, repo)
        assert.equal("main", ref)
    end),

    test("parseOtaInput: bare ref targets the default repo", function()
        local repo, ref = updater.parseOtaInput("v1.16", "omer-faruq/assistant.koplugin")
        assert.equal("omer-faruq/assistant.koplugin", repo)
        assert.equal("v1.16", ref, "the leading v must stay so tags vs heads still works")
        repo, ref = updater.parseOtaInput("  dev  ", "omer-faruq/assistant.koplugin")
        assert.equal("omer-faruq/assistant.koplugin", repo)
        assert.equal("dev", ref)
    end),

    test("parseOtaInput: user/repo defaults to main", function()
        local repo, ref = updater.parseOtaInput("someone/assistant.koplugin")
        assert.equal("someone/assistant.koplugin", repo)
        assert.equal("main", ref)
    end),

    test("parseOtaInput: user/repo@ref", function()
        local repo, ref = updater.parseOtaInput("someone/assistant.koplugin@v1.16")
        assert.equal("someone/assistant.koplugin", repo)
        assert.equal("v1.16", ref)

        repo, ref = updater.parseOtaInput("someone/fork@dev")
        assert.equal("someone/fork", repo)
        assert.equal("dev", ref)
    end),

    test("parseOtaInput: slash branch keeps the remaining segments", function()
        local repo, ref = updater.parseOtaInput("someone/assistant.koplugin/feature/nested/x")
        assert.equal("someone/assistant.koplugin", repo)
        assert.equal("feature/nested/x", ref)
    end),

    test("parseOtaInput: invalid repository shapes are rejected", function()
        local repo, err = updater.parseOtaInput("@main")
        assert.isTrue(repo == nil)
        assert.equal("invalid_repo", err)

        repo, err = updater.parseOtaInput("user/../repo")
        assert.isTrue(repo == nil)
        assert.equal("invalid_repo", err)

        repo, err = updater.parseOtaInput("user/re px")
        assert.isTrue(repo == nil)
        assert.equal("invalid_repo", err)
    end),

    test("parseOtaInput: invalid refs are rejected", function()
        local function err_of(input)
            local repo, err = updater.parseOtaInput(input)
            assert.isTrue(repo == nil, "expected failure for " .. input)
            return err
        end
        assert.equal("invalid_ref", err_of("user/repo@"))
        assert.equal("invalid_ref", err_of("user/repo@a@b"))
        assert.equal("invalid_ref", err_of("user/repo@bad ref"))
        assert.equal("invalid_ref", err_of("user/repo@a:b"))
        assert.equal("invalid_ref", err_of("user/repo@a?b"))
        assert.equal("invalid_ref", err_of("user/repo@a#b"))
        assert.equal("invalid_ref", err_of("user/repo@a\\b"))
        assert.equal("invalid_ref", err_of("user/repo@a..b"))
        assert.equal("invalid_ref", err_of("user/repo@.hidden"))
        assert.equal("invalid_ref", err_of("user/repo/"))
        assert.equal("invalid_ref", err_of("user/repo@" .. string.rep("a", 129)))
    end),

    test("parseOtaInput: a 128 char ref is still accepted", function()
        local ref = string.rep("a", 128)
        local repo, parsed = updater.parseOtaInput("user/repo@" .. ref)
        assert.equal("user/repo", repo)
        assert.equal(ref, parsed)
    end),

    test("parseOtaInput: falls back to the built-in repo without a caller default", function()
        local repo, ref = updater.parseOtaInput("dev")
        assert.equal("omer-faruq/assistant.koplugin", repo)
        assert.equal("dev", ref)
    end),

    -- =========================================================================
    -- archive identity predicates
    -- =========================================================================

    test("isValidPluginMeta: accepts the real _meta.lua", function()
        assert.notNil(meta_content, "_meta.lua must be readable")
        assert.isTrue(updater.isValidPluginMeta(meta_content))
    end),

    test("isValidPluginMeta: rejects empty and unrelated content", function()
        assert.isFalse(updater.isValidPluginMeta(nil))
        assert.isFalse(updater.isValidPluginMeta(""))
        assert.isFalse(updater.isValidPluginMeta("local x = 1\n"))
        assert.isFalse(updater.isValidPluginMeta('return { fullname = "AI Assistant" }'))
    end),

    test("isValidPluginReleaseIgnore: accepts the real .releaseignore", function()
        assert.notNil(releaseignore_content, ".releaseignore must be readable")
        assert.isTrue(updater.isValidPluginReleaseIgnore(releaseignore_content))
    end),

    test("isValidPluginReleaseIgnore: rejects empty, comment-only and unrelated lists", function()
        assert.isFalse(updater.isValidPluginReleaseIgnore(nil))
        assert.isFalse(updater.isValidPluginReleaseIgnore(""))
        assert.isFalse(updater.isValidPluginReleaseIgnore("# nothing here\n"))
        -- excludes main.lua, so it does not describe this plugin's layout
        assert.isFalse(updater.isValidPluginReleaseIgnore("main.lua\n*.md\ntest/\n"))
    end),

    test("isValidPluginReleaseIgnore: accepts an equivalent minimal list", function()
        assert.isTrue(updater.isValidPluginReleaseIgnore(".*\n*.md\ntest/\n"))
    end),

    -- =========================================================================
    -- validatePluginFiles
    -- =========================================================================

    test("validatePluginFiles: passes for the real identity files", function()
        local ok, reason = updater.validatePluginFiles(releaseignore_content, meta_content, true)
        assert.isTrue(ok)
        assert.isTrue(reason == nil)
    end),

    test("validatePluginFiles: missing files report their reason code", function()
        local ok, reason = updater.validatePluginFiles(nil, meta_content, true)
        assert.isFalse(ok)
        assert.equal("missing_releaseignore", reason)

        ok, reason = updater.validatePluginFiles(releaseignore_content, nil, true)
        assert.isFalse(ok)
        assert.equal("missing_meta", reason)

        ok, reason = updater.validatePluginFiles(releaseignore_content, meta_content, false)
        assert.isFalse(ok)
        assert.equal("missing_main", reason)
    end),

    test("validatePluginFiles: present but wrong content reports a bad code", function()
        local ok, reason = updater.validatePluginFiles("*.md\n", meta_content, true)
        assert.isFalse(ok)
        assert.equal("bad_releaseignore", reason)

        ok, reason = updater.validatePluginFiles(releaseignore_content, 'return { fullname = "AI Assistant" }', true)
        assert.isFalse(ok)
        assert.equal("bad_meta", reason)
    end),
}

return helper.runTests("core/updater.lua", tests)
