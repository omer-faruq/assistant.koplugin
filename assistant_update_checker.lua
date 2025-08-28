local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local TrapWidget  = require("ui/widget/trapwidget")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local logger = require("logger")
local _ = require("assistant_gettext")
local koutil = require("util")

local update_url = "https://api.github.com/repos/omer-faruq/assistant.koplugin/releases/latest"

local CONFIGURATION = nil
local meta = nil

-- A more robust version comparison function compliant with Semantic Versioning.
-- Returns true if v1_str is newer than v2_str, false otherwise.
-- Handles versions like "1.8", "1.8.0-rc.1", "1.8.0-rc.11", "1.8.0".
local function isVersionNewer(v1_str, v2_str)
    if not v1_str or not v2_str then return false end

    -- Helper to parse a version string into its main and pre-release parts
    -- according to SemVer rules.
    local function parseVersion(v_str)
        local parts = {}
        local pre_release_parts = {}
        local main_part = v_str

        -- Separate pre-release tag (e.g., -alpha.1)
        local pre_release_start = v_str:find("-")
        if pre_release_start then
            main_part = v_str:sub(1, pre_release_start - 1)
            local pre_release_str = v_str:sub(pre_release_start + 1)
            -- Split pre-release by '.' and convert numeric parts to numbers
            for part in pre_release_str:gmatch("([^.]+)") do
                local num = tonumber(part)
                -- A valid numeric identifier in SemVer is just digits.
                if num and part:match("^[0-9]+$") then
                    table.insert(pre_release_parts, num)
                else
                    table.insert(pre_release_parts, part)
                end
            end
        end

        -- Split main part (e.g., 1.8.0) into numbers
        for part in main_part:gmatch("%d+") do
            table.insert(parts, tonumber(part))
        end

        return parts, pre_release_parts
    end

    local parts1, pre1_parts = parseVersion(tostring(v1_str))
    local parts2, pre2_parts = parseVersion(tostring(v2_str))

    -- 1. Compare main version parts (MAJOR.MINOR.PATCH)
    local max_len = math.max(#parts1, #parts2)
    for i = 1, max_len do
        local p1 = parts1[i] or 0
        local p2 = parts2[i] or 0
        if p1 > p2 then return true end
        if p1 < p2 then return false end
    end

    -- Main versions are equal, so we proceed to pre-release comparison.
    local has_pre1 = #pre1_parts > 0
    local has_pre2 = #pre2_parts > 0

    -- 2. A version with a pre-release has lower precedence than a normal version.
    if has_pre1 and not has_pre2 then return false end -- e.g., 1.0.0-rc < 1.0.0
    if not has_pre1 and has_pre2 then return true end  -- e.g., 1.0.0 > 1.0.0-rc
    if not has_pre1 and not has_pre2 then return false end -- e.g., 1.0.0 == 1.0.0

    -- 3. Both have pre-release tags, compare them identifier by identifier.
    local pre_max_len = math.max(#pre1_parts, #pre2_parts)
    for i = 1, pre_max_len do
        local p1 = pre1_parts[i]
        local p2 = pre2_parts[i]

        if p1 == nil then return false end -- v1 is shorter, so older (e.g., 1.0-alpha < 1.0-alpha.1)
        if p2 == nil then return true end  -- v2 is shorter, so older

        local p1_is_num, p2_is_num = type(p1) == "number", type(p2) == "number"

        if p1_is_num and p2_is_num then
            if p1 > p2 then return true elseif p1 < p2 then return false end
        elseif p1_is_num then return false -- Numeric identifiers have lower precedence
        elseif p2_is_num then return true  -- Non-numeric has higher precedence
        else -- Both are strings
            if p1 > p2 then return true elseif p1 < p2 then return false end
        end
    end

    return false -- Versions are identical
end

local function checkForUpdates()
  
  if koutil.tableGetValue(CONFIGURATION, "features", "updater_disabled") then
    return
  end

  local infomsg = TrapWidget:new{
    text = _("Checking for updates..."),
  }
  UIManager:show(infomsg)
  local success, code, body = Trapper:dismissableRunInSubprocess(function()
    local response_body = {}
    local _, code = http.request {
      url = update_url,
      headers = {
          ["Accept"] = "application/vnd.github.v3+json"
      },
      sink = ltn12.sink.table(response_body)
    }

    return code, table.concat(response_body)
  end, infomsg)
  UIManager:close(infomsg)

  if not success then
    logger.warn("user interrupted the update check.")
    return
  end

  if code == 200 then
    local ok, parsed_data = pcall(json.decode, body)
    if not ok then
      logger.warn("Failed to parse update check response:", parsed_data) -- parsed_data contains the error
      return
    end

    local latest_version_tag = parsed_data and parsed_data.tag_name -- e.g., "v1.08-rc2"
    if latest_version_tag and meta and meta.version then
      -- Strip optional leading 'v'
      local latest_version_str = latest_version_tag:match("^v?(.*)$")
      local current_version_str = tostring(meta.version)

      if isVersionNewer(latest_version_str, current_version_str) then
        local message = string.format(
          _("A new version of the %s plugin (%s) is available. Please update!"),
          meta.fullname, latest_version_tag
        )
        Notification:notify(message, Notification.SOURCE_ALWAYS_SHOW)
      end
    end
  else
    logger.warn("Failed to check for updates. HTTP code:", code)
  end
end

return {
  checkForUpdates = function(assistant)
    CONFIGURATION = assistant.CONFIGURATION
    meta = assistant.meta
    return Trapper:wrap(checkForUpdates)
  end
}
