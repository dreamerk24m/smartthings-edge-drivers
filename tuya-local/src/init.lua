-- Tuya Local (LAN) driver for SmartThings Edge
-- Discovery, device lifecycle, persistent connections and command dispatch.
-- 기기 검색, 생명주기, 지속 연결 및 명령 분배.
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local ledTime = capabilities["travellaugh21607.ledTime"]
local transport = require "transport"
local tuya = require "tuya"
local json = require "st.json"
local st_device = require "st.device"

local PRODUCTS = require "products"
local handlers = {
  thermo_hygro = require "devices.thermo_hygro",
  thermo_hygro_led = require "devices.thermo_hygro_led",
  power_strip = require "devices.power_strip",
  ir_blaster = require "devices.ir_blaster",
}

-- Profile used until the product ID is known / 제품 ID를 알기 전까지 쓰는 초기 프로필
local SETUP_PROFILE = "tuya-setup"

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
-- Persistent connection / 지속 연결
---------------------------------------------------------------------------

local RECONNECT_INTERVAL = 10
local INITIAL_QUERY_TIMEOUT = 5

local start_push

local function cancel_reconnect(device)
  local timer = device:get_field("reconnect_timer")

  if timer then
    device:set_field("reconnect_timer", nil)
    device.thread:cancel_timer(timer)
  end
end

local function cancel_initial_query(session)
  if session.initial_query_timer then
    session.thread:cancel_timer(session.initial_query_timer)
    session.initial_query_timer = nil
  end
end

local function stop_push(device)
  cancel_reconnect(device)

  local session = device:get_field("tuya_session")

  if session then
    device:set_field("tuya_session", nil)
    cancel_initial_query(session)
    transport.close_session(session)
  end
end

-- Schedule a single reconnection attempt.
-- 재연결 시도를 한 번만 예약함.
local function schedule_reconnect(device)
  local p = device.preferences or {}
  local product = PRODUCTS[p.productId]

  if not is_configured(p) or not product then
    return
  end

  if device:get_field("tuya_session")
    or device:get_field("reconnect_timer") then
    return
  end

  local timer

  timer = device.thread:call_with_delay(
    RECONNECT_INTERVAL,

    function()
      if device:get_field("reconnect_timer") ~= timer then
        return
      end

      device:set_field("reconnect_timer", nil)

      local prefs = device.preferences or {}
      local current_product = PRODUCTS[prefs.productId]

      if not is_configured(prefs)
        or not current_product then
        return
      end

      if device:get_field("tuya_session") then
        return
      end

      log.info(device.device_network_id ..
        ": reconnecting")

      start_push(device, current_product)
    end,

    "tuya-reconnect"
  )

  if timer then
    device:set_field("reconnect_timer", timer)

    log.info(string.format(
        "%s: reconnect scheduled in %d seconds",
        device.device_network_id,
        RECONNECT_INTERVAL
    ))
  else
    log.warn(device.device_network_id ..
      ": failed to schedule reconnect")
  end
end

local function handle_session_packet(device, product,
    session, cmd, retcode, plain)

  if device:get_field("tuya_session") ~= session then
    return
  end

  if retcode ~= 0 then
    log.warn(string.format(
        "%s: command=%d error=%d",
        device.device_network_id, cmd, retcode
    ))
    return
  end

  if cmd == tuya.CMD_CONTROL then
    log.debug(device.device_network_id .. ": control ACK")
  end

  if cmd ~= tuya.CMD_DP_QUERY
    and cmd ~= tuya.CMD_STATUS then
    return
  end

  if plain == "" then return end

  local ok, decoded = pcall(json.decode, plain)

  if not ok or type(decoded) ~= "table"
    or type(decoded.dps) ~= "table" then
    log.warn(device.device_network_id .. ": invalid DP data")
    return
  end

  -- Confirm the initial status response.
  -- 최초 상태 조회 응답을 확인함.
  if cmd == tuya.CMD_DP_QUERY
    and session.initial_query_timer then

    cancel_initial_query(session)

    log.info(device.device_network_id ..
      ": session initialized")
  end

  -- Merge received values into the session cache.
  -- 수신한 값을 세션 캐시에 반영함.
  for dp, value in pairs(decoded.dps) do
    session.dps[dp] = value
  end

  log.debug(string.format(
      "%s: %s received",
      device.device_network_id,
      cmd == tuya.CMD_DP_QUERY and "status reply" or "DP push"
  ))

  local handler = handlers[product.kind]

  if handler and handler.apply then
    handler.apply(device, product, decoded.dps, session.dps)
  end

  if cmd == tuya.CMD_STATUS
    and handler
    and handler.handle_push then
    handler.handle_push(device, product, decoded.dps, session)
  end
end

start_push = function(device, product)
  local p = device.preferences or {}
  local current = device:get_field("tuya_session")

  if not is_configured(p) or not product then
    stop_push(device)
    return
  end

  -- Keep the session if connection settings have not changed.
  -- 연결 설정이 바뀌지 않았다면 기존 연결을 유지함.
  if current and not current.closed
    and current.ip == p.deviceIp
    and current.dev_id == p.deviceId
    and current.key == p.localKey
    and current.product_id == p.productId then
    return
  end

  stop_push(device)

  local session, err = transport.open_session(
    device,

    function(s, cmd, retcode, plain)
      handle_session_packet(
        device, product, s, cmd, retcode, plain
      )
    end,

    function(s, reason)
      cancel_initial_query(s)

      local handler = handlers[product.kind]

      if handler and handler.cancel_learning then
        handler.cancel_learning(s)
      end

      if device:get_field("tuya_session") == s then
        device:set_field("tuya_session", nil)
        schedule_reconnect(device)
      end
    end
  )

  if not session then
    log.warn(device.device_network_id ..
        ": connection failed: " .. tostring(err))

    schedule_reconnect(device)
    return
  end

  session.ip = p.deviceIp
  session.product_id = p.productId
  session.dps = {}

  device:set_field("tuya_session", session)

  local ok, query_err = transport.session_query(session)

  if not ok then
    log.warn(device.device_network_id ..
        ": initial query failed: " .. tostring(query_err))

    if not session.closed then
      transport.close_session(session, "initial query failed")
    end

    return
  end

  log.debug(device.device_network_id ..
    ": initial status query TX")

  -- Disconnect if the initial status response is missing.
  -- 최초 상태 조회 응답이 없으면 연결을 종료함.
  session.initial_query_timer = device.thread:call_with_delay(
    INITIAL_QUERY_TIMEOUT,

    function()
      if device:get_field("tuya_session") ~= session
        or session.closed
        or not session.initial_query_timer then
        return
      end

      session.initial_query_timer = nil

      transport.close_session(
        session,
        "initial status query timeout"
      )
    end,

    "tuya-initial-query"
  )

  if not session.initial_query_timer then
    transport.close_session(
      session,
      "failed to schedule initial query timeout"
    )
  end
end

---------------------------------------------------------------------------
-- Device configuration / 기기 설정
---------------------------------------------------------------------------

-- Configure the device and establish a persistent connection.
-- 기기를 설정하고 지속 연결을 시작함.

local function configure_device(driver, device)
  local p = device.preferences or {}

  if not is_configured(p) then
    stop_push(device)
    log.info(device.device_network_id ..
      ": settings not complete yet")
    return
  end

  local product = PRODUCTS[p.productId]

  if not product then
    stop_push(device)
    log.warn(device.device_network_id ..
        ": unknown product ID " .. tostring(p.productId))
    return
  end

  if device:get_field("applied_profile") ~= product.profile then
    device:set_field("applied_profile",
      product.profile, { persist = true })

    log.info(device.device_network_id ..
        ": switching profile to " .. product.profile)

    device:try_update_metadata({
        profile = product.profile
    })
  end

  local handler = handlers[product.kind]

  if handler and handler.create_children then
    handler.create_children(driver, device, product)
  end

  start_push(device, product)
end

---------------------------------------------------------------------------
-- Commands / 명령 처리
---------------------------------------------------------------------------
-- Send a control command using the persistent TCP session.
-- 지속 TCP 연결을 통해 제어 명령을 전송함.

local function run_dps_control(parent, dps)
  local prefs = parent.preferences or {}
  local product = PRODUCTS[prefs.productId]

  if not product or not is_configured(prefs) then
    return
  end

  local session = parent:get_field("tuya_session")

  if not session or session.closed then
    log.warn(parent.device_network_id ..
      ": control skipped, not connected")
    return
  end

  local ok, err = transport.session_control(session, dps)

  if ok then
    log.debug(parent.device_network_id .. ": control TX")
  else
    log.warn(parent.device_network_id ..
        ": control failed: " .. tostring(err))
  end
end

local function run_control(parent, targets, is_on)
  local dps = {}

  for _, dp in ipairs(targets) do
    dps[dp] = is_on
  end

  run_dps_control(parent, dps)
end

-- Switch on/off from the main switch, an outlet component, or a child device.
-- 메인 스위치, outlet component, 자식 기기 어디서 눌러도 여기로 옴.

local function handle_switch(driver, device, command)
  local is_on = command.command == "on"
  local parent = device

  -- Resolve the parent only for child devices.
  -- 자식 기기인 경우에만 부모 기기를 조회함.
  if device.network_type == st_device.NETWORK_TYPE_CHILD then
    local found, parent_device =
    pcall(device.get_parent_device, device)

    if not found or not parent_device then
      return
    end

    parent = parent_device
  end

  local product = PRODUCTS[(parent.preferences or {}).productId]

  if not product then return end

  local handler = handlers[product.kind]

  if handler and handler.handle_switch then
    if device ~= parent then
      -- Execute child commands on the parent device thread.
      -- 자식 기기 명령을 부모 기기 스레드에서 실행함.
      parent.thread:call_with_delay(0, function()
          handler.handle_switch(
            device, parent, product, command, is_on, run_control
          )
      end)
    else
      handler.handle_switch(
        device, parent, product, command, is_on, run_control
      )
    end
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

local function handle_ir_learn(driver, device, command)
  local p = device.preferences or {}
  local product = PRODUCTS[p.productId]

  if not product or product.kind ~= "ir_blaster" then
    return
  end

  if not is_configured(p) then return end

  local handler = handlers[product.kind]

  if command.component == "main" then
    handler.learn(device, product)
  elseif command.component == "irSendTest" then
    handler.send(device, product, run_dps_control)
  end
end

local function handle_refresh(driver, device, command)
  local p = device.preferences or {}

  if is_configured(p) then
    local product = PRODUCTS[p.productId]

    if not product then return end

    local session = device:get_field("tuya_session")

    if session and not session.closed then
      transport.session_query(session)
    else
      configure_device(driver, device)
    end

    return
  end

  if device.network_type ~= st_device.NETWORK_TYPE_CHILD then
    return
  end

  local ok, parent = pcall(device.get_parent_device, device)

  if not ok or not parent then return end

  local product = PRODUCTS[(parent.preferences or {}).productId]

  if not product or product.kind ~= "ir_blaster" then
    return
  end

  local child = parent:get_child_by_parent_assigned_key(
    "thermo-hygro"
  )

  if child and child.id == device.id then
    parent.thread:call_with_delay(0, function()
        handle_refresh(driver, parent, command)
    end)
  end
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
  configure_device(driver, device)
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

  configure_device(driver, device)

  if product and is_configured(p)
    and old.productId == p.productId then

    local handler = handlers[product.kind]

    if handler and handler.info_changed then
      handler.info_changed(
        device, product, p, old, run_dps_control
      )
    end
  end
end

local function device_removed(_, device)
  log.info(device.device_network_id .. ": removed")
  stop_push(device)
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
      [capabilities.momentary.ID] = {
        [capabilities.momentary.commands.push.NAME] = handle_ir_learn,
      },
    },
})

driver:run()
