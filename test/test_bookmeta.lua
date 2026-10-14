-- test_bookmeta.lua
-- Runtime tests for DocUtils.getBookMeta and describeBook.
local helper = require("test.helper")
local assert = helper.assert
local DocUtils = helper.DocUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {

    test("ui.doc_props wins (custom metadata honored)", function()
        local ui = { doc_props = { title = "Custom Title", authors = "Custom Author", display_title = "Custom Display" } }
        local meta = DocUtils.getBookMeta(ui, "book.epub")
        assert.equal(meta.title, "Custom Title")
        assert.equal(meta.authors, "Custom Author")
        assert.equal(meta.display_title, "Custom Display")
    end),

    test("bookinfo.getDocProps is the second fallback", function()
        local ui = {
            bookinfo = {
                getDocProps = function(self, file, a, b)
                    return { title = "Bookinfo Title", authors = { "A", "B" }, display_title = "Bookinfo Display" }
                end,
            },
        }
        local meta = DocUtils.getBookMeta(ui, "book.epub")
        assert.equal(meta.title, "Bookinfo Title")
        assert.equal(meta.authors, "A, B")
        assert.equal(meta.display_title, "Bookinfo Display")
    end),

    test("sidecar doc_props is the third fallback", function()
        local saved_docsettings = package.loaded["docsettings"]
        local saved_util = package.loaded["apps/filemanager/filemanagerutil"]
        package.loaded["docsettings"] = {
            open = function(file)
                return {
                    child = function(self, name)
                        return {
                            readSetting = function(self, key)
                                if key == "title" then return "Sidecar Title" end
                                if key == "authors" then return "Sidecar Author" end
                                return nil
                            end,
                        }
                    end,
                    readSetting = function(self, key) return nil end,
                }
            end,
        }
        package.loaded["apps/filemanager/filemanagerutil"] = {
            splitFileNameType = function(file) return "Stem" end,
        }
        local meta = DocUtils.getBookMeta(nil, "book.epub")
        assert.equal(meta.title, "Sidecar Title")
        assert.equal(meta.authors, "Sidecar Author")
        package.loaded["docsettings"] = saved_docsettings
        package.loaded["apps/filemanager/filemanagerutil"] = saved_util
    end),

    test("filename stem becomes display_title only when unresolved", function()
        local saved_docsettings = package.loaded["docsettings"]
        local saved_util = package.loaded["apps/filemanager/filemanagerutil"]
        package.loaded["docsettings"] = {
            open = function(file) return nil end,
        }
        package.loaded["apps/filemanager/filemanagerutil"] = {
            splitFileNameType = function(file) return "File Stem" end,
        }
        local meta = DocUtils.getBookMeta(nil, "/books/x.epub")
        assert.equal(meta.title, nil)
        assert.equal(meta.authors, nil)
        assert.equal(meta.display_title, "File Stem")
        package.loaded["docsettings"] = saved_docsettings
        package.loaded["apps/filemanager/filemanagerutil"] = saved_util
    end),

    test("describeBook variants", function()
        assert.equal(DocUtils.describeBook({ title = "T", author = "A" }), "titled 'T' by A")
        assert.equal(DocUtils.describeBook({ title = "T" }), "titled 'T'")
        assert.equal(DocUtils.describeBook({ author = "A" }), "by A")
        assert.equal(DocUtils.describeBook({ display_title = "F" }), "whose title/author metadata is unavailable (file name: F, not the title)")
        assert.equal(DocUtils.describeBook({}), "whose title/author metadata is unavailable")
    end),
}

return helper.runTests("bookmeta", tests)
