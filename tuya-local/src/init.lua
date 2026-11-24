-- Tuya Local (LAN) driver for SmartThings Edge
-- Polls Tuya Wi-Fi thermo-hygrometers (protocol 3.3) over TCP and shows temperature / humidity.
-- The device type is chosen from the product ID entered in the settings.
-- Tuya 와이파이 온습도계(프로토콜 3.3)를 TCP로 주기적으로 조회해서 온도와 습도를 표시함.
-- 기기 종류는 설정에 입력한 제품 ID로 정함.

local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local json = require "st.json"
local log = require "log"
local cosock = require "cosock"
local tuya = require "tuya"

local socket = cosock.socket

-- Profile used until the product ID is known / 제품 ID를 알기 전까지 쓰는 초기 프로필
local SETUP_PROFILE = "tuya-setup"

local POLL_INTERVAL = 60      -- seconds between polls / 조회 간격(초)
local TIMEOUT = 5             -- seconds for connect and each receive / 연결·수신 대기(초)
local PORT = 6668             -- Tuya local TCP port / Tuya 로컬 TCP 포트
local MAX_PACKETS = 5         -- packets to read while waiting for the status reply / 상태 응답을 기다리며 읽을 최대 패킷 수
local MAX_PACKET_SIZE = 4096  -- sanity limit / 비정상 패킷 방지

-- Known products: product ID -> profile to use and datapoint numbers.
-- Temperature value is temperature x 10, humidity is percent.
-- 알려진 제품: 제품 ID -> 사용할 프로필과 DP 번호. 온도 값은 온도 x 10, 습도는 %.
local PRODUCTS = {
  ["o2c5btmpepi9pzf8"] = {
    kind = "thermo_hygro",
    profile = "tuya-thermo-hygro-led",
    temperature = "1",
    humidity = "2",
    display = "21"
  },     -- thermo-hygrometer / 온습도계
  ["whs3cty93fzrqkpt"] = { kind = "thermo_hygro", profile = "tuya-thermo-hygro", temperature = "101", humidity = "102" }, -- thermo-hygrometer with IR / IR 블래스터 온습도
  ["7hBwPPNdDP1xHrWv"] = { kind = "power_strip", profile = "tuya-power-strip", outlets = { "1", "2", "3", "4" }, power = "103", power_scale = 10 }, -- power strip / 멀티탭
}

local OUTLET_PROFILE = "tuya-power-strip-outlet"
local seq = 0

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
-- Network / 통신
---------------------------------------------------------------------------

-- Read one whole packet from the socket. Returns packet string, or nil + error.
-- 소켓에서 패킷 하나를 통째로 읽음.
local function read_packet(tcp)
  local header, err = tcp:receive(tuya.HEADER_LEN)
  if not header then return nil, "receive header failed: " .. tostring(err) end
  local size, perr = tuya.packet_size(header)
  if not size then return nil, "bad header: " .. tostring(perr) end
  if size > MAX_PACKET_SIZE then return nil, "packet too large: " .. size end
  local rest, rerr = tcp:receive(size - tuya.HEADER_LEN)
  if not rest then return nil, "receive body failed: " .. tostring(rerr) end
  return header .. rest
end

-- Ask the device for its status. Returns the dps table, or nil + error.
-- 기기에 상태를 물어서 dps 표를 돌려줌.
local function query_status(ip, dev_id, key)
  local tcp = socket.tcp()
  tcp:settimeout(TIMEOUT)

  local ok, err = tcp:connect(ip, PORT)
  if not ok then
    tcp:close()
    return nil, "connect failed: " .. tostring(err)
  end

  seq = seq + 1
  local sent, serr = tcp:send(tuya.build_status_query(dev_id, key, seq, tostring(os.time())))
  if not sent then
    tcp:close()
    return nil, "send failed: " .. tostring(serr)
  end

  local dps, last_err = nil, "no status reply"
  for _ = 1, MAX_PACKETS do
    local packet, perr = read_packet(tcp)
    if not packet then
      last_err = perr
      break
    end
    local cmd = string.unpack(">I4", packet, 9)
    -- Skip anything that is not the reply to our status query (e.g. heartbeat, pushed updates).
    -- 상태 조회 응답이 아닌 패킷(하트비트, 자동 전송 등)은 건너뜀.
    if cmd == tuya.CMD_DP_QUERY then
      local pcmd, retcode, plain = tuya.parse(packet, key)
      if not pcmd then
        last_err = "reply parse failed: " .. tostring(retcode) .. " (wrong Local Key?)"
      elseif retcode ~= 0 then
        last_err = "device returned error code " .. tostring(retcode)
      else
        local decoded = json.decode(plain)
        if type(decoded) == "table" and type(decoded.dps) == "table" then
          dps = decoded.dps
        else
          last_err = "reply has no dps"
        end
      end
      break
    end
  end

  tcp:close()
  if dps then return dps end
  return nil, last_err
end

-- Send a control command. Returns true, or nil + error. The result is checked by polling afterwards.
-- 제어 명령을 보냄. 결과는 이후 조회로 확인함.
local function send_control(ip, dev_id, key, dps)
  local tcp = socket.tcp()
  tcp:settimeout(TIMEOUT)

  local ok, err = tcp:connect(ip, PORT)
  if not ok then
    tcp:close()
    return nil, "connect failed: " .. tostring(err)
  end

  seq = seq + 1
  local sent, serr = tcp:send(tuya.build_control(dev_id, key, seq, tostring(os.time()), dps))
  if not sent then
    tcp:close()
    return nil, "send failed: " .. tostring(serr)
  end

  -- Read one reply only to see what the device answers (for debugging).
  -- 기기의 응답을 로그로 확인하려고 하나만 읽음.
  local packet = read_packet(tcp)
  if packet then
    log.info(string.format("control reply: cmd=%d size=%d", string.unpack(">I4", packet, 9), #packet))
  end

  tcp:close()
  return true
end

---------------------------------------------------------------------------
-- Polling / 주기 조회
---------------------------------------------------------------------------

-- Emit an event without letting an error (e.g. profile not switched yet) stop the driver.
-- 프로필이 아직 안 바뀐 경우 등의 오류로 드라이버가 멈추지 않게 이벤트를 보냄.
local function emit(device, event)
  local ok, err = pcall(device.emit_event, device, event)
  if not ok then log.warn(device.device_network_id .. ": could not emit event: " .. tostring(err)) end
end

-- Emit an event to one component of a device (e.g. "outlet1").
-- 기기의 특정 component(예: "outlet1")에 이벤트를 보냄.
local function emit_component(device, component_id, event)
  local component = device.profile.components[component_id]
  if not component then
    log.warn(device.device_network_id .. ": no component " .. component_id)
    return
  end
  local ok, err = pcall(device.emit_component_event, device, component, event)
  if not ok then log.warn(device.device_network_id .. ": could not emit event to " .. component_id .. ": " .. tostring(err)) end
end

local function switch_event(is_on)
  if is_on then return capabilities.switch.switch.on() end
  return capabilities.switch.switch.off()
end

local function apply_thermo_hygro(device, product, dps)
  local temp, hum = dps[product.temperature], dps[product.humidity]

  if type(temp) == "number" then
    emit(device, capabilities.temperatureMeasurement.temperature({
      value = temp / 10,
      unit = "C"
    }))
  end

  if type(hum) == "number" then
    emit(device, capabilities.relativeHumidityMeasurement.humidity(hum))
  end

  -- LED display state / LED 디스플레이 상태
  if product.display then
    local display = dps[product.display]

    if type(display) == "boolean" then
      emit_component(device, "display", switch_event(display))

      log.info(string.format("%s: display=%s",
        device.device_network_id, tostring(display)))
    end
  end

  log.info(string.format("%s: temperature=%s humidity=%s",
    device.device_network_id,
    tostring(type(temp) == "number" and temp / 10 or nil),
    tostring(hum)))
end

-- Outlet states go to the child devices and to the outlet components of this device.
-- The main switch is on when at least one outlet is on. Power is DP value / power_scale (W).
-- 콘센트 상태는 자식 기기와 이 기기의 outlet component에 보냄. 메인 스위치는 하나라도 켜져 있으면 on.
local function apply_power_strip(device, product, dps)
  local seen, any_on = false, false
  for i, dp in ipairs(product.outlets) do
    local value = dps[dp]
    if type(value) == "boolean" then
      seen = true
      if value then any_on = true end
      local child = device:get_child_by_parent_assigned_key(dp)
      if child then emit(child, switch_event(value)) end
      emit_component(device, "outlet" .. i, switch_event(value))
    end
  end
  if seen then emit(device, switch_event(any_on)) end

  local power = dps[product.power]
  if type(power) == "number" then
    emit(device, capabilities.powerMeter.power({ value = power / product.power_scale, unit = "W" }))
  end
  log.info(string.format("%s: any_on=%s power=%s",
    device.device_network_id, tostring(seen and any_on or nil),
    tostring(type(power) == "number" and power / product.power_scale or nil)))
end

local APPLY = {
  thermo_hygro = apply_thermo_hygro,
  power_strip = apply_power_strip,
}

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

  local apply = APPLY[product.kind]
  if apply then apply(device, product, dps) end
end

local function stop_polling(device)
  local timer = device:get_field("poll_timer")
  if timer then
    device.thread:cancel_timer(timer)
    device:set_field("poll_timer", nil)
  end
end


-- Create one child device per outlet, only once. The child key is the DP number ("1".."4").
-- 콘센트마다 자식 기기를 한 번만 만듦. 자식 키는 DP 번호("1"~"4").
local function create_children(driver, device, product)
  if device:get_field("children_created") then return end
  device:set_field("children_created", true, { persist = true })
  for i, dp in ipairs(product.outlets) do
    if not device:get_child_by_parent_assigned_key(dp) then
      local ok, err = driver:try_create_device({
        type = "EDGE_CHILD",
        label = "콘센트 " .. i,
        profile = OUTLET_PROFILE,
        manufacturer = "Tuya",
        parent_device_id = device.id,
        parent_assigned_child_key = dp,
      })
      log.info(string.format("%s: create child %s -> %s %s",
        device.device_network_id, dp, tostring(ok), tostring(err)))
    end
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
  if product.kind == "power_strip" then
    create_children(driver, device, product)
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
local function run_control(parent, targets, is_on, attempt)
  if parent:get_field("polling") then
    if attempt < 5 then
      parent.thread:call_with_delay(1, function() run_control(parent, targets, is_on, attempt + 1) end)
    else
      log.warn(parent.device_network_id .. ": control skipped, device is busy")
    end
    return
  end
  local p = parent.preferences
  if not is_configured(p) then return end

  local dps = {}
  for _, dp in ipairs(targets) do dps[dp] = is_on end

  parent:set_field("polling", true)
  local ok, result, err = pcall(send_control, p.deviceIp, p.deviceId, p.localKey, dps)
  parent:set_field("polling", false)

  if not ok then
    log.warn(parent.device_network_id .. ": control error: " .. tostring(result))
  elseif not result then
    log.warn(parent.device_network_id .. ": control failed: " .. tostring(err))
  end
  parent.thread:call_with_delay(0.2, function() poll(parent) end)
end

-- Switch on/off from the main switch, an outlet component, or a child device.
-- 메인 스위치, outlet component, 자식 기기 어디서 눌러도 여기로 옴.
local function handle_switch(driver, device, command)
  local is_on = command.command == "on"
  local found, parent_device = pcall(device.get_parent_device, device)
  local parent = (found and parent_device) or device

  local product = PRODUCTS[(parent.preferences or {}).productId]

  if not product then return end

  -- Thermo-hygrometer LED control / 온습도계 LED 제어
  if product.kind == "thermo_hygro" then
    if parent == device and
      command.component == "display" and
      product.display then

      log.info(string.format("%s: display -> %s",
        device.device_network_id, command.command))

      run_control(parent, { product.display }, is_on, 1)
    end

    return
  end

  if product.kind ~= "power_strip" then return end

  local targets = {}
  if parent == device then
    if command.component == "main" then
      for _, dp in ipairs(product.outlets) do targets[#targets + 1] = dp end
    else
      local index = tonumber(string.match(command.component, "^outlet(%d+)$"))
      if index and product.outlets[index] then targets[1] = product.outlets[index] end
    end
  else
    for _, dp in ipairs(product.outlets) do
      local child = parent:get_child_by_parent_assigned_key(dp)
      if child and child.id == device.id then targets[1] = dp end
    end
  end

  if #targets == 0 then
    log.warn(device.device_network_id .. ": no target for " .. tostring(command.component))
    return
  end
  log.info(string.format("%s: %s -> %s", device.device_network_id, table.concat(targets, ","), command.command))
  run_control(parent, targets, is_on, 1)
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
local function info_changed(driver, device, _, _)
  local p = device.preferences or {}
  log.info(string.format("%s: settings changed ip=%s id=%s product=%s key_len=%d",
    device.device_network_id, tostring(p.deviceIp), tostring(p.deviceId), tostring(p.productId), #(p.localKey or "")))
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
  },
})

driver:run()