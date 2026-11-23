-- Tuya Local (LAN) driver for SmartThings Edge
-- Skeleton only: creates an empty device on discovery and logs settings changes.

local Driver = require "st.driver"
local log = require "log"

local PROFILE = "tuya-thermo-hygro"

-- Each discovery run creates one empty device; the user fills in IP / ID / key in settings.
local function discovery_handler(driver, _, _)
  local dni = "tuya-local-" .. tostring(os.time())
  log.info("discovery: creating empty device " .. dni)
  driver:try_create_device({
    type = "LAN",
    device_network_id = dni,
    label = "Tuya Thermo-Hygrometer",
    profile = PROFILE,
    manufacturer = "Tuya",
    model = "Thermo-Hygrometer",
  })
end

local function device_added(_, device)
  log.info(device.device_network_id .. ": added")
end

local function device_init(_, device)
  log.info(device.device_network_id .. ": init")
end

-- Never log the local key itself, only its length.
local function info_changed(_, device, _, _)
  local p = device.preferences
  log.info(string.format("%s: settings changed ip=%s id=%s key_len=%d",
    device.device_network_id, tostring(p.deviceIp), tostring(p.deviceId), #(p.localKey or "")))
end

local function device_removed(_, device)
  log.info(device.device_network_id .. ": removed")
end

local driver = Driver("tuya-local", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    infoChanged = info_changed,
    removed = device_removed,
  },
})

driver:run()