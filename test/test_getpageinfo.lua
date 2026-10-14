local helper = require("test.helper")
local assert = helper.assert
local DocUtils = helper.DocUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {

    test("reflowable doc prefers BookList percent", function()
        local saved = package.loaded["ui/widget/booklist"]
        package.loaded["ui/widget/booklist"] = {
            getBookInfo = function(file) return { percent_finished = 0.42 } end,
        }
        local ui = {
            paging = false,
            highlight = { selected_text = { pos0 = {} } },
            document = {
                info = { number_of_pages = 10 },
                file = "x.epub",
                getPageFromXPointer = function() return 3 end,
                getPageCount = function() return 10 end,
            },
            toc = { getTocTitleByPage = function() return "Ch1" end },
        }
        local info = DocUtils.getPageInfo(ui)
        assert.matches(info, "42%%")
        assert.matches(info, "Ch1")
        package.loaded["ui/widget/booklist"] = saved
    end),

    test("reflowable doc falls back to sidecar percent", function()
        local saved_bl = package.loaded["ui/widget/booklist"]
        package.loaded["ui/widget/booklist"] = nil
        local saved_ds = package.loaded["docsettings"]
        package.loaded["docsettings"] = {
            open = function(file)
                return { readSetting = function(self, key)
                    if key == "percent_finished" then return 0.75 end
                    return nil
                end }
            end,
        }
        local ui = {
            paging = false,
            highlight = { selected_text = { pos0 = {} } },
            document = {
                info = { number_of_pages = 10 },
                file = "x.epub",
                getPageFromXPointer = function() return 3 end,
                getPageCount = function() return 10 end,
            },
        }
        local info = DocUtils.getPageInfo(ui)
        assert.matches(info, "75%%")
        package.loaded["ui/widget/booklist"] = saved_bl
        package.loaded["docsettings"] = saved_ds
    end),

    test("paging doc keeps page numbers", function()
        local ui = {
            paging = true,
            highlight = { selected_text = { pos0 = { page = 5 } } },
            document = {
                info = { number_of_pages = 10 },
                getPageCount = function() return 10 end,
            },
            toc = { getTocTitleByPage = function() return nil end },
        }
        local info = DocUtils.getPageInfo(ui)
        assert.matches(info, "Page 5")
        assert.matches(info, "50%%")
    end),
}

return helper.runTests("getpageinfo", tests)
