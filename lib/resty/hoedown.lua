local setmetatable = setmetatable
local type         = type

local hoedown = {}

function hoedown:__call(source, opts)
    local renderer, extensions, max_nesting, smartypants
    if type(opts) == "table" then
        extensions, max_nesting, smartypants = opts.extensions, opts.max_nesting, opts.smartypants
        local t = type(opts.renderer)
        if t == "string"  then
            if opts.renderer == "html.toc" then
                renderer = self.html.toc.new(opts.nesting)
            else
                renderer = self.html.new(opts.flags, opts.nesting)
            end
        elseif t == "function" then
            renderer = opts.renderer(opts)
        else
            renderer = self.html.new(opts.flags, opts.nesting)
        end
    else
        renderer = self.html.new()
    end
    if smartypants then
        return self.html.smartypants(self.document.new(renderer, extensions, max_nesting):render(source))
    else
        return self.document.new(renderer, extensions, max_nesting):render(source)
    end
end

return setmetatable({
    buffer   = require "resty.hoedown.buffer",
    document = require "resty.hoedown.document",
    html     = require "resty.hoedown.html",
    escape   = require "resty.hoedown.escape",
    version  = require "resty.hoedown.version"
}, hoedown)
