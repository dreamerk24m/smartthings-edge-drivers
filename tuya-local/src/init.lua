-- Tuya Local (LAN) driver for SmartThings Edge
-- Discovery, device lifecycle, polling and command dispatch.
-- 기기 검색, 생명주기, 주기 조회 및 명령 분배.
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local ledTime = capabilities["travellaugh21607.ledTime"]
local transport = require "transport"
local PRODUCTS = require "products"
local handlers = {
  thermo_hygro = require "devices.thermo_hygro",
  thermo_hygro_led = require "devices.thermo_hygro_led",
  power_strip = require "devices.power_strip",
}

local query_status = transport.query_status
local send_control = transport.send_control
-- Profile used until the product ID is known / 제품 ID를 알기 전까지 쓰는 초기 프로필
local SETUP_PROFILE = "tuya-setup"
local POLL_INTERVAL = 60      -- seconds between polls / 조회 간격(초)

---------------------------------------------------------------------------
-- Settings check / 설정 확인
---------------------------------------------------------------------------
-- True when IP, device ID, key and product ID are filled in (not the placeholder defaults).
-- IP, 기기 ID, 키, 제품 ID가 기본값이 아닌 실제 값으로 채워졌는지 확인.

local function is_configured(p)
  local ip, id, key = p.deviceIp or "", p.deviceId or "", p.localKey or ""
  local pid = p.productId or ""
  if #pid ~= 16 or pid == string.rep("0", 16) then return false end
  if not ip:match("^%d+%.%d+%.%d+%.%d+$") or ip == "0.0.0.0" then return false end
  if #id ~= 20 and #id ~= 22 then return false end
  if id == string.rep("0", 20) then return false end
  if #key ~= 16 or key == string.rep("0", 16) then return false end
  return true
end

---------------------------------------------------------------------------
-- Polling / 주기 조회
---------------------------------------------------------------------------

local function poll(device)
  if device:get_field("polling") then return end
  local p = device.preferences
  if not is_configured(p) then return end
  local product = PRODUCTS[p.productId]
  if not product then return end
  device:set_field("polling", true)
  local ok, dps, err = pcall(query_status, p.deviceIp, p.deviceId, p.localKey)
  device:set_field("polling", false)
  if not ok then
    log.warn(device.device_network_id .. ": poll error: " .. tostring(dps))
    return
  end
  if not dps then
    log.warn(device.device_network_id .. ": poll failed: " .. tostring(err))
    return
  end
  local handler = handlers[product.kind]
  if handler and handler.apply then handler.apply(device, product, dps) end
end

local function stop_polling(device)
  local timer = device:get_field("poll_timer")
  if timer then
    device.thread:cancel_timer(timer)
    device:set_field("poll_timer", nil)
  end
end

-- (Re)start the poll timer, and poll once right away. Does nothing until settings are filled in.
-- 조회 타이머를 (다시) 걸고 바로 한 번 조회함. 설정이 채워지기 전에는 아무것도 안 함.

local function start_polling(driver, device)
  stop_polling(device)
  local p = device.preferences or {}
  if not is_configured(p) then
    log.info(device.device_network_id .. ": settings not complete yet, not polling")
    return
  end
  local product = PRODUCTS[p.productId]
  if not product then
    log.warn(device.device_network_id .. ": unknown product ID " .. tostring(p.productId) .. ", not polling")
    return
  end

  -- Switch to the profile of this product once (remembered across restarts).
  -- 이 제품의 프로필로 한 번만 바꿈(재시작해도 기억).
  if device:get_field("applied_profile") ~= product.profile then
    device:set_field("applied_profile", product.profile, { persist = true })
    log.info(device.device_network_id .. ": switching profile to " .. product.profile)
    device:try_update_metadata({ profile = product.profile })
  end
  local handler = handlers[product.kind]
  if handler and handler.create_children then
    handler.create_children(driver, device, product)
  end
  local timer = device.thread:call_on_schedule(POLL_INTERVAL, function() poll(device) end, "tuya-poll")
  device:set_field("poll_timer", timer)
  device.thread:call_with_delay(0, function() poll(device) end)
end

---------------------------------------------------------------------------
-- Commands / 명령 처리
---------------------------------------------------------------------------
-- Send the control command. If a poll is running, wait a moment and try again.
-- Afterwards read the real state right away.
-- 제어 명령을 보냄. 조회 중이면 잠시 뒤 다시 시도하고, 끝나면 실제 상태를 바로 읽음.

local function run_dps_control(parent, dps, attempt)
  if parent:get_field("polling") then
    if attempt < 5 then
      parent.thread:call_with_delay(1, function()
          run_dps_control(parent, dps, attempt + 1)
      end)
    else
      log.warn(parent.device_network_id .. ": control skipped, device is busy")
    end
    return
  end
  local p = parent.preferences
  if not is_configured(p) then return end
  parent:set_field("polling", true)
  local ok, result, err = pcall(
    send_control, p.deviceIp, p.deviceId, p.localKey, dps
  )
  parent:set_field("polling", false)
  if not ok then
    log.warn(parent.device_network_id .. ": control error: " .. tostring(result))
  elseif not result then
    log.warn(parent.device_network_id .. ": control failed: " .. tostring(err))
  end
  parent.thread:call_with_delay(0.2, function()
      poll(parent)
  end)
end

local function run_control(parent, targets, is_on, attempt)
  local dps = {}
  for _, dp in ipairs(targets) do
    dps[dp] = is_on
  end
  run_dps_control(parent, dps, attempt)
end

-- Switch on/off from the main switch, an outlet component, or a child device.
-- 메인 스위치, outlet component, 자식 기기 어디서 눌러도 여기로 옴.

local function handle_switch(driver, device, command)
  local is_on = command.command == "on"
  local found, parent_device = pcall(device.get_parent_device, device)
  local parent = (found and parent_device) or device
  local product = PRODUCTS[(parent.preferences or {}).productId]
  if not product then return end
  local handler = handlers[product.kind]
  if handler and handler.handle_switch then
    handler.handle_switch(device, parent, product, command, is_on, run_control)
  end
end

local function handle_led_time(driver, device, command)
  local p = device.preferences or {}
  local product = PRODUCTS[p.productId]
  local handler = product and handlers[product.kind]
  if handler and handler.handle_led_time then
    handler.handle_led_time(device, product, command, run_dps_control)
  end
end

local function handle_refresh(driver, device, command)
  poll(device)
end

---------------------------------------------------------------------------
-- Lifecycle / 기기 생명주기
---------------------------------------------------------------------------
-- Each discovery run creates one empty device; the user fills in IP / ID / key in settings.
-- 기기 검색을 누를 때마다 빈 기기 하나를 만들고, 사용자가 설정에 IP / ID / 키를 입력함.

local function discovery_handler(driver, _, _)
  local dni = "tuya-local-" .. tostring(os.time())
  log.info("discovery: creating empty device " .. dni)
  driver:try_create_device({
      type = "LAN",
      device_network_id = dni,
      label = "Tuya Device",
      profile = SETUP_PROFILE,
      manufacturer = "Tuya",
      model = "Tuya Device",
  })
end

local function device_init(driver, device)
  log.info(device.device_network_id .. ": init")
  start_polling(driver, device)
end

-- Never log the local key itself, only its length.
-- Local Key는 로그에 남기지 않고 글자 수만 남김.

local function info_changed(driver, device, event, args)
  local p = device.preferences or {}
  log.info(string.format(
      "%s: settings changed ip=%s id=%s product=%s key_len=%d",
      device.device_network_id,
      tostring(p.deviceIp),
      tostring(p.deviceId),
      tostring(p.productId),
      #(p.localKey or "")
  ))
  local old = (args and args.old_st_store
      and args.old_st_store.preferences) or {}
  local product = PRODUCTS[p.productId]
  if product and is_configured(p)
    and old.productId == p.productId then
    local handler = handlers[product.kind]
    if handler and handler.info_changed then
      handler.info_changed(device, product, p, old, run_dps_control)
    end
  end
  start_polling(driver, device)
end

local function device_removed(_, device)
  log.info(device.device_network_id .. ": removed")
  stop_polling(device)
end

local driver = Driver("tuya-local", {
    discovery = discovery_handler,
    lifecycle_handlers = {
      init = device_init,
      infoChanged = info_changed,
      removed = device_removed,
    },
    capability_handlers = {
      [capabilities.switch.ID] = {
        [capabilities.switch.commands.on.NAME] = handle_switch,
        [capabilities.switch.commands.off.NAME] = handle_switch,
      },
      [capabilities.refresh.ID] = {
        [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
      },
      [ledTime.ID] = {
        [ledTime.commands.setTime.NAME] = handle_led_time,
      },
    },
})

driver:run()
