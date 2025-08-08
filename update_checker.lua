local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local meta = require("_meta")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local logger = require("logger")
local t = require("i18n")

local update_url = "https://api.github.com/repos/omer-faruq/assistant.koplugin/releases/latest"

local function checkForUpdates()

  local success, CONFIGURATION = pcall(function() return require("configuration") end)
  if success and CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.updater_disabled then
    return
  end

  local infomsg = InfoMessage:new{
    text = t("checking_for_updates"),
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
    local parsed_data = json.decode(body)
    local latest_version = parsed_data.tag_name -- e.g., "v0.9"
    
    -- Safe version comparison
    if latest_version then
      local stripped_latest_version = latest_version:match("^v(.+)$")
      if stripped_latest_version then
        local latest_number = tonumber(stripped_latest_version)
        if latest_number and meta.version and latest_number > meta.version then
          -- Show notification to the user if a new version is available
          local message = string.format(
            t("new_version_available_please_update"),
            meta.fullname, latest_version
          )
          UIManager:show(InfoMessage:new{ text = message, timeout = 5}) 
        end
      end
    end
  else
    logger.warn("Failed to check for updates. HTTP code:", code)
  end
end

return {
  checkForUpdates = function()
    Trapper:wrap(checkForUpdates)
  end
}