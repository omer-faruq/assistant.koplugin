local lib          = require "resty.hoedown.library"
local ffi          = require "ffi"
local ffi_new      = ffi.new
local ffi_cdef     = ffi.cdef
local tonumber     = tonumber
local concat       = table.concat
local setmetatable = setmetatable

ffi_cdef[[
void hoedown_version(int *major, int *minor, int *revision);
]]

local version = {}

function version:__tostring()
    return concat({ self.major, self.minor, self.revision }, '.')
end

do
    local major    = ffi_new("int[1]", 0)
    local minor    = ffi_new("int[1]", 0)
    local revision = ffi_new("int[1]", 0)

    lib.hoedown_version(major, minor, revision)

    version.major    = tonumber(major[0])
    version.minor    = tonumber(minor[0])
    version.revision = tonumber(revision[0])
end

return setmetatable(version, version)
