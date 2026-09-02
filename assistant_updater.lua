local TrapWidget  = require("ui/widget/trapwidget")
local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local Font = require("ui/font")
local logger = require("logger")
local _ = require("assistant_gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local koutil = require("util")
local ASUtils = require("assistant_utils")

-- Variadic path join. Uses FFIUtil.joinPath so we don't sprinkle "/" literals
-- and get the right separator handling for free.
local function join(...)
    local args = { ... }
    local result = args[1]
    if not result then return "" end
    for i = 2, #args do
        result = FFIUtil.joinPath(result, args[i])
    end
    return result
end

local UPDATE_CHECK_INTERVAL = 48 * 3600 -- 48 hours in seconds
local LAST_CHECK_KEY = "updater_last_check"

local meta = nil

-- Throttle helper: true when enough time has passed since last check.
-- `now` is injectable for tests; defaults to os.time().
local function shouldCheckForUpdates(assistant, now)
    now = now or os.time()
    if not assistant or not assistant.settings then return true end
    local last = assistant.settings:readSetting(LAST_CHECK_KEY)
    if last == nil then return true end
    if type(last) == "string" then last = tonumber(last) end
    if type(last) ~= "number" then return true end
    if last > now then return true end -- clock skew: future timestamp treated as expired
    return (now - last) >= UPDATE_CHECK_INTERVAL
end

local function normalize(path) -- strip ./, /, assistant.koplugin-*/ prefix
    if not path or path == "" then return "" end
    local p = path:gsub("\\", "/")
    while p:sub(1, 2) == "./" do p = p:sub(3) end
    while p:sub(1, 1) == "/" do p = p:sub(2) end
    p = p:gsub("^assistant%.koplugin[^/]*/", "")
    return p:gsub("/+$", "")
end
local function glob_match(pat, path) -- * matches /
    local esc = pat:gsub("%%", "%%%%"):gsub("%.", "%%."):gsub("%+", "%%+"):gsub("%-", "%%-"):gsub("%^", "%%^"):gsub("%$", "%%$"):gsub("%(", "%%("):gsub("%)", "%%)")
    esc = esc:gsub("%*", ".*"):gsub("%?", ".")
    return path:match("^" .. esc .. "$") or path:match("/" .. esc .. "$") or path:match("^" .. esc .. "/") or path:match("/" .. esc .. "/")
end
local function parse_ignore_content(content)
    if not content or content == "" then return nil end
    local pats = {}
    for line in content:gmatch("[^\r\n]+") do
        local t = line:match("^%s*(.-)%s*$")
        if t ~= "" and t:sub(1, 1) ~= "#" then
            local neg = t:sub(1, 1) == "!"
            local core = neg and t:sub(2):match("^%s*(.-)%s*$") or t
            local is_dir = core:sub(-1) == "/"
            if is_dir then core = core:sub(1, -2) end
            if core ~= "" then pats[#pats + 1] = { core = core, neg = neg, is_dir = is_dir } end
        end
    end
    return pats
end
local function is_excluded_with(p, pats)
    local n = normalize(p)
    if n == "" then return false end
    if not pats or #pats == 0 then -- fallback legacy rules
        if n:find("/%.") or n:sub(1, 1) == "." then return true end
        if n:find(".+%.md$") then return true end
        if n:find("l10n/.+") and not n:find("%.mo$") then return true end
        if n:find("^test/") or n:find("/test/") then return true end
        return false
    end
    local exc = false
    for _, pt in ipairs(pats) do
        local hit = glob_match(pt.core, n)
        if hit then exc = not pt.neg end
    end
    return exc
end
local cached_pats = nil -- for non-OTA is_excluded compat (tests)
local function is_excluded(path)
    if cached_pats then return is_excluded_with(path, cached_pats) end
    return is_excluded_with(path, nil)
end

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

local function checkForUpdates(assistant)
  if not assistant or not assistant.settings or not assistant.config then
    return
  end
  if assistant.config:getFeature("updater_disabled") then
    return
  end

  -- 48h throttle: skip network check if last check was recent.
  -- Timestamp is persisted in settings so it survives restarts.
  local now = os.time()
  if not shouldCheckForUpdates(assistant, now) then
    return
  end
  -- In-memory guard prevents parallel network calls from rapid
  -- re-entries before the first request completes. Persistent timestamp
  -- is only saved after a successful response, so transient failures
  -- (offline, 5xx) can retry on the next window entry.
  if assistant._update_check_running then
    return
  end
  assistant._update_check_running = true

  local update_url = assistant.config:getFeature("update_check_url")
    or "https://api.github.com/repos/omer-faruq/assistant.koplugin/releases/latest"

  local parsed_data, err = ASUtils.fetchJSON(update_url,
      { ["Accept"] = "application/vnd.github.v3+json" },
      _("Checking for updates..."))

  if not parsed_data then
    assistant._update_check_running = nil
    Notification:notify(T(_("AI Assistant: Failed to check updates: %2"), err or _("Empty Error")), Notification.SOURCE_ALWAYS_SHOW)
    return
  end

  -- Success: persist timestamp so we don't check again within 48h
  assistant.settings:saveSetting(LAST_CHECK_KEY, now)
  assistant.updated = true
  assistant._update_check_running = nil

  local latest_version_tag = parsed_data.tag_name
  if latest_version_tag and meta and meta.version then
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

  local GITHUB_BASE = assistant.config:getFeature("ota_github_base")
    or "https://github.com"
  local GITHUB_REPO = assistant.config:getFeature("ota_github_repo")
    or "omer-faruq/assistant.koplugin"

  local REPO_REF = version:sub(1, 1) == "v" and "tags" or "heads"
  local RELEASE_URL = string.format("%s/%s/archive/refs/%s/%s.zip", GITHUB_BASE, GITHUB_REPO, REPO_REF, version)

  local DataStorage = require("datastorage")
  local lfs = require("libs/libkoreader-lfs")
  local Archiver = require("ffi/archiver")
  local util = require("util")

  -- OTA target is intentionally DataStorage (writable) — not self-location (may be read-only install dir).
  local KOREADER_DIR = DataStorage:getFullDataDir()
  local PLUGIN_DIR = join(KOREADER_DIR, "plugins")
  local ASSISTANT_DIR = join(PLUGIN_DIR, PLUGIN_NAME)
  local UPDATE_TMPDIR = join(KOREADER_DIR, "ota", PLUGIN_NAME .. ".update")
  local UPDATE_BAKDIR = join(UPDATE_TMPDIR, "backup")
  local TARGET_PLUGIN_PATH = ASSISTANT_DIR
  local BACKUP_PLUGIN_PATH = join(UPDATE_BAKDIR, PLUGIN_NAME)
  local DL_TAR = join(UPDATE_TMPDIR, string.format("SOURCE-%s-%s.zip", PLUGIN_NAME, version))

  util.makePath(UPDATE_BAKDIR)

  -- Phase 1: Download the archive (dismissable by user)
  local download_msg = InfoMessage:new{
    face = Font:getFace("xx_smallinfofont"),
      text = ASUtils.bold_format(
      T(_("<b>Downloading ...</b>\n<b>Github: </b>%1\n<b>Repo: </b>%2\n<b>Branch/Tag: </b>%3"),
        GITHUB_BASE, GITHUB_REPO, version)
    ),
  }
  UIManager:show(download_msg)

  local completed, dl_result, dl_err = Trapper:dismissableRunInSubprocess(function()
    local sub_logger = require("logger")
    local _ok, _r1, _r2 = xpcall(function()
      local socket = require("socket")
      local http = require("socket.http")
      local ltn12 = require("ltn12")
      local lfs = require("libs/libkoreader-lfs")

      local file_handle = io.open(DL_TAR, "wb")
      if not file_handle then
        sub_logger.warn("[OTA] failed to create temp file: " .. tostring(DL_TAR))
        return false, "Could not create temp file"
      end

      local sink = ltn12.sink.file(file_handle)
      local status_code, headers, status_line = socket.skip(1, http.request{
        url = RELEASE_URL,
        method = "GET",
        sink = sink,
      })

      -- Ensure file is flushed and closed so Archiver can read it
      -- ltn12 sink.file auto-closes handle on EOF (chunk==nil); explicit close must be pcall-guarded to avoid "attempt to use a closed file"
      if file_handle then
        pcall(file_handle.close, file_handle)
      end

      local size = lfs.attributes(DL_TAR, "size")

      if status_code ~= 200 then
        sub_logger.warn("[OTA] download failed: status_code=" .. tostring(status_code) .. " url=" .. tostring(RELEASE_URL) .. " size=" .. tostring(size))
        if status_code == 404 then
          return false, T(_("Branch/Tag \"%1\" was not found."), version)
        end
        if status_code and status_code >= 300 and status_code < 400 then
          local loc = headers and (headers.location or headers.Location or headers["Location"] or headers["location"])
          return false, "Download failed: HTTP " .. tostring(status_code) .. " redirect to " .. tostring(loc)
        end
        return false, "Download failed: HTTP " .. tostring(status_code)
      end

      if not size or size == 0 then
        sub_logger.warn("[OTA] downloaded file is empty: " .. tostring(DL_TAR) .. " size=" .. tostring(size))
        return false, "Download failed: empty file"
      end

      return true, nil
    end, debug.traceback)
    if not _ok then
      sub_logger.warn("[OTA] Phase 1 task exception: " .. tostring(_r1))
      return false, tostring(_r1)
    end
    return _r1, _r2
  end, download_msg)

  UIManager:close(download_msg)

  if not completed then
    FFIUtil.purgeDir(UPDATE_TMPDIR)
    Notification:notify(_("OTA update canceled."), Notification.SOURCE_ALWAYS_SHOW)
    return
  end

  if not dl_result then
    logger.warn("[OTA] Phase 1 download failed: dl_err=" .. tostring(dl_err))
    FFIUtil.purgeDir(UPDATE_TMPDIR)
    Notification:notify(T(_("OTA update failed: %1"), tostring(dl_err)), Notification.SOURCE_ALWAYS_SHOW)
    return
  end

  -- Phase 2: Extract and install (NOT dismissable)
  local extract_msg = InfoMessage:new{
    text = ASUtils.bold_format(
          T(_("<b>Installing %1...</b>"), version)
      ),
  }
  UIManager:show(extract_msg)
  UIManager:forceRePaint()
  local function closeInstalling()
    if extract_msg then
      pcall(UIManager.close, UIManager, extract_msg)
      extract_msg = nil
    end
  end

  local function do_install()
    local arc = Archiver.Reader:new()
    local ok_open = arc:open(DL_TAR)
    if not ok_open then
      FFIUtil.purgeDir(UPDATE_TMPDIR)
      return false, "Failed to open archive"
    end
    -- 2a: read .releaseignore from archive if present (in-memory, no temp file)
    -- Archiver.Reader supports extractToMemory(entry.path) -> string; no file object API.
    local pats = nil
    for entry in arc:iterate() do
      if normalize(entry.path) == ".releaseignore" then
        local content = arc:extractToMemory(entry.path)
        if content then
          pats = parse_ignore_content(content)
        end
        break
      end
    end
    cached_pats = pats
    arc:close()
    -- Archiver.Reader is single-use: do not reuse after close, create a fresh instance.
    arc = Archiver.Reader:new()

    local ok_open2 = arc:open(DL_TAR)
    if not ok_open2 then
      FFIUtil.purgeDir(UPDATE_TMPDIR)
      return false, "Failed to open archive"
    end
    for entry in arc:iterate() do
      if is_excluded_with(entry.path, pats) then
        -- skip (dotfiles like .releaseignore already excluded via ".*" / legacy fallback)
      else
        local dest_path = join(UPDATE_TMPDIR, entry.path)
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

    -- Locate the extracted top-level plugin directory (e.g. assistant.koplugin-<ver>)
    -- Fail early before touching the existing installation so we don't have to roll back.
    local found_extracted_dir = nil
    for file in lfs.dir(UPDATE_TMPDIR) do
      if file:sub(1, #PLUGIN_NAME) == PLUGIN_NAME then
        local candidate = join(UPDATE_TMPDIR, file)
        local is_dir = util.directoryExists(candidate)
        if is_dir then
          found_extracted_dir = candidate
          break
        end
      end
    end
    if not found_extracted_dir then
      FFIUtil.purgeDir(UPDATE_TMPDIR)
      return false, "Could not find extracted plugin directory"
    end

    -- Move the currently installed plugin aside as a backup
    if util.pathExists(TARGET_PLUGIN_PATH) then
      if util.pathExists(BACKUP_PLUGIN_PATH) then
        FFIUtil.purgeDir(BACKUP_PLUGIN_PATH)
      end
      local ok_ren, err_ren = os.rename(TARGET_PLUGIN_PATH, BACKUP_PLUGIN_PATH)
      if not ok_ren then
        FFIUtil.purgeDir(UPDATE_TMPDIR)
        return false, "Failed to backup existing plugin: " .. tostring(err_ren)
      end
    end

    -- Install the freshly extracted plugin into its target location
    local ok_ren2, err_ren2 = os.rename(found_extracted_dir, TARGET_PLUGIN_PATH)
    if not ok_ren2 then
      return false, "Failed to install plugin: " .. tostring(err_ren2)
    end

    -- Restore user-owned files from the backup
    if util.pathExists(BACKUP_PLUGIN_PATH) then
      local restore_targets = {"configuration.lua"}
      for _, filename in ipairs(restore_targets) do
        local old_file = join(BACKUP_PLUGIN_PATH, filename)
        local new_file = join(TARGET_PLUGIN_PATH, filename)
        if util.pathExists(old_file) then
          if util.pathExists(new_file) then
            FFIUtil.purgeDir(new_file)
            -- FFIUtil.purgeDir handles both files and dirs; also try os.remove for file case
            if util.pathExists(new_file) then
              os.remove(new_file)
            end
          end
          os.rename(old_file, new_file)
        end
      end
    end

    -- Clean up temp/backup directory
    FFIUtil.purgeDir(UPDATE_TMPDIR)
    return true, nil
  end

  local pcall_ok, ok, err_msg = pcall(do_install)
  if not pcall_ok then
    logger.warn("[OTA] Phase 2: do_install crashed: " .. tostring(ok))
    -- ok here is the error message from pcall
    closeInstalling()
    UIManager:show(InfoMessage:new{ text = T(_("OTA update failed: %1"), tostring(ok)) })
    -- Ensure temp is cleaned on crash
    pcall(function() FFIUtil.purgeDir(UPDATE_TMPDIR) end)
    return
  end

  if not ok then
    logger.warn("[OTA] Phase 2: do_install failed: " .. tostring(err_msg))
    closeInstalling()
    UIManager:show(InfoMessage:new{ text = T(_("OTA update failed: %1"), tostring(err_msg)) })
    return
  end

  closeInstalling()
  Notification:notify(T(_("OTA UPDATE OK.\n Restart is required.")), Notification.SOURCE_ALWAYS_SHOW)
  UIManager:askForRestart()
end

return {
  isVersionNewer = isVersionNewer,
  is_excluded = is_excluded,
  join = join,
  UPDATE_CHECK_INTERVAL = UPDATE_CHECK_INTERVAL,
  LAST_CHECK_KEY = LAST_CHECK_KEY,
  shouldCheckForUpdates = shouldCheckForUpdates,
  checkForUpdates = function(assistant)
    meta = assistant.meta
    return Trapper:wrap(function() checkForUpdates(assistant) end)
  end,
  otaUpgrade = function(assistant, version)
    meta = assistant.meta
    return Trapper:wrap(function() otaUpgrade(assistant, version) end)
  end,
}
