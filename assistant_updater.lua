local json = require("rapidjson")
local TrapWidget  = require("ui/widget/trapwidget")
local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local logger = require("logger")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local koutil = require("util")
local assistant_utils = require("assistant_utils")

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

  local infomsg = TrapWidget:new{ text = _("Checking for updates...") }
  UIManager:show(infomsg)

  local completed, success, code, body = Trapper:dismissableRunInSubprocess(function()
    return assistant_utils.httpRequest(update_url, nil, nil, nil, nil, { ["Accept"] = "application/vnd.github.v3+json" })
  end, infomsg)
  UIManager:close(infomsg)

  if not completed then
    Notification:notify(_("Update check canceled."))
    return
  end
  if not success or code ~= 200 then
    Notification:notify(T(_("Failed to check for updates. HTTP code: %1"), code))
    return
  end

  local ok, parsed_data = pcall(json.decode, body)
  if not ok then
    Notification:notify(T(_("Failed to parse update check response: %1"), parsed_data))
    return
  end

  local latest_version_tag = parsed_data and parsed_data.tag_name -- e.g., "v1.08-rc2"
  if latest_version_tag and meta and meta.version then
    -- Strip optional leading 'v'
    local latest_version_str = latest_version_tag:match("^v?(.*)$")
    local current_version_str = tostring(meta.version)

    if isVersionNewer(latest_version_str, current_version_str) then
      local message = T(_("A new version of the %1 plugin (%2) is available. Please update!"),
        meta.fullname, latest_version_tag)
      Notification:notify(message, Notification.SOURCE_ALWAYS_SHOW)
    end
  end
end

local function otaUpgrade(assistant, version)
  local PLUGIN_NAME = "assistant.koplugin"

  local GITHUB_BASE = koutil.tableGetValue(CONFIGURATION, "features", "ota_github_base")
    or "https://ghfast.top/https://github.com"
  local GITHUB_REPO = koutil.tableGetValue(CONFIGURATION, "features", "ota_github_repo")
    or "omer-faruq/assistant.koplugin"

  local REPO_REF = version:sub(1, 1) == "v" and "tags" or "heads"
  local RELEASE_URL = string.format("%s/%s/archive/refs/%s/%s.zip", GITHUB_BASE, GITHUB_REPO, REPO_REF, version)

  local infomsg = InfoMessage:new{ text = T(_("Updating %1 to %2..."), PLUGIN_NAME, version) }
  UIManager:show(infomsg)
  -- UIManager:forceRePaint()

  local completed, result, err_msg = Trapper:dismissableRunInSubprocess(function()
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    local Archiver = require("ffi/archiver")
    local FFIUtil = require("ffi/util")
    local socket = require("socket")
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local util = require("util")
    local ASUtils = require("assistant_utils")

    local KOREADER_DIR = DataStorage:getFullDataDir()
    local PLUGIN_DIR = KOREADER_DIR .. "/plugins"
    local ASSISTANT_DIR = PLUGIN_DIR .. "/" .. PLUGIN_NAME
    local UPDATE_TMPDIR = KOREADER_DIR .. "/ota/" .. PLUGIN_NAME .. ".update"
    local UPDATE_BAKDIR = UPDATE_TMPDIR .. "/backup"
    local TARGET_PLUGIN_PATH = ASSISTANT_DIR
    local BACKUP_PLUGIN_PATH = UPDATE_BAKDIR .. "/" .. PLUGIN_NAME
    local DL_TAR = string.format("%s/SOURCE-%s-%s.zip", UPDATE_TMPDIR, PLUGIN_NAME, version)


    local function is_excluded(path)
      if path:find("/%.") or path:sub(1,1) == "." then
        return true
      end
      if path:find(".+%.md$")
         or path:find("l10n/templates")
         or path:find("l10n/AI_TRANSLATE%.sh$")
         or path:find("l10n/Makefile$")
      then
        return true
      end
      return false
    end

    util.makePath(UPDATE_BAKDIR)

    local file_handle = io.open(DL_TAR, "wb")
    if not file_handle then
      return false, "Could not create temp file"
    end

    local sink = ltn12.sink.file(file_handle)
    local status_code = socket.skip(1, http.request{
      url = RELEASE_URL,
      method = "GET",
      sink = sink,
    })

    if status_code ~= 200 then
      FFIUtil.purgeDir(UPDATE_TMPDIR)
      return false, "Download failed: HTTP " .. tostring(status_code)
    end

    local arc = Archiver.Reader:new()
    if not arc:open(DL_TAR) then
      FFIUtil.purgeDir(UPDATE_TMPDIR)
      return false, "Failed to open archive"
    end

    for entry in arc:iterate() do
      if not is_excluded(entry.path) then
        local dest_path = UPDATE_TMPDIR .. "/" .. entry.path
        local parent_dir = dest_path:match("(.*)" .. package.config:sub(1,1))
        if parent_dir and not util.pathExists(parent_dir) then
          util.makePath(parent_dir)
        end
        if not arc:extractToPath(entry.path, dest_path) then
          arc:close()
          FFIUtil.purgeDir(UPDATE_TMPDIR)
          return false, "Failed to extract: " .. entry.path
        end
      end
    end
    arc:close()

    if util.pathExists(TARGET_PLUGIN_PATH) then
      if util.pathExists(BACKUP_PLUGIN_PATH) then
        FFIUtil.purgeDir(BACKUP_PLUGIN_PATH)
      end
      os.rename(TARGET_PLUGIN_PATH, BACKUP_PLUGIN_PATH)
    end

    local found_extracted_dir = nil
    for file in lfs.dir(UPDATE_TMPDIR) do
      if file:sub(1, #PLUGIN_NAME) == PLUGIN_NAME then
        if util.directoryExists(UPDATE_TMPDIR .. "/" .. file) then
          found_extracted_dir = UPDATE_TMPDIR .. "/" .. file
          break
        end
      end
    end

    if found_extracted_dir then
      os.rename(found_extracted_dir, TARGET_PLUGIN_PATH)
    else
      if util.pathExists(BACKUP_PLUGIN_PATH) then
        os.rename(BACKUP_PLUGIN_PATH, TARGET_PLUGIN_PATH)
      end
      FFIUtil.purgeDir(UPDATE_TMPDIR)
      return false, "Could not find extracted plugin directory"
    end

    if util.pathExists(BACKUP_PLUGIN_PATH) then
      local restore_targets = {"configuration.lua", "lib"}
      for _, filename in ipairs(restore_targets) do
        local old_file = BACKUP_PLUGIN_PATH .. "/" .. filename
        local new_file = TARGET_PLUGIN_PATH .. "/" .. filename
        if util.pathExists(old_file) then
          if util.pathExists(new_file) then FFIUtil.purgeDir(new_file) end
          os.rename(old_file, new_file)
        end
      end
    end

    FFIUtil.purgeDir(UPDATE_TMPDIR)

    return true, nil
  end, infomsg)

  UIManager:close(infomsg)

  if not completed then
    Notification:notify(_("OTA update canceled."))
    return
  end

  if not result then
    Notification:notify(T(_("OTA update failed: %1"), tostring(err_msg)))
    return
  end

  UIManager:askForRestart()
end

return {
  checkForUpdates = function(assistant)
    CONFIGURATION = assistant.CONFIGURATION
    meta = assistant.meta
    return Trapper:wrap(checkForUpdates)
  end,
  otaUpgrade = function(assistant, version)
    CONFIGURATION = assistant.CONFIGURATION
    return Trapper:wrap(function() otaUpgrade(assistant, version) end)
  end,
}
