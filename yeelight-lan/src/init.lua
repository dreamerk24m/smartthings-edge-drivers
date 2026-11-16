-- Yeelight LAN driver
--   Light Bar (lamp15): front light + back light
--   Ceiling light (ceilb): main light + moonlight
-- Yeelight LAN 드라이버
--   Light Bar (lamp15): 앞 조명 + 뒤 조명
--   천장등 (ceilb): 본등 + 달빛
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local socket = require "cosock.socket"
local json = require "st.json"
local log = require "log"

local YEELIGHT_PORT = 55443
local SSDP_ADDR = "239.255.255.250"
local SSDP_PORT = 1982

-- Supported models → profile to use
-- 지원하는 모델 → 사용할 프로필
local SUPPORTED_MODELS = {
  lamp15 = { profile = "yeelight-lightbar", label = "Yeelight Light Bar" },
  ceilb = { profile = "yeelight-ceiling", label = "Yeelight Ceiling Light" },
}

-- Properties read on refresh (a model returns "" for ones it does not have)
-- 새로고침 때 읽어 올 값들 (모델에 없는 값은 ""로 옴)
local PROPS = { "power", "main_power", "bright", "ct", "active_mode", "nl_br",
  "bg_power", "bg_bright", "bg_ct", "bg_hue", "bg_sat", "bg_lmode", "bg_proact" }

-- set_power mode values
-- set_power 모드 값
local MODE_NORMAL = 1 -- Normal (color temperature) light / 일반 조명 (색온도)
local MODE_MOON = 5   -- Moonlight / 달빛

-- Method names per component (front light / back light)
-- 구성 요소별 명령 이름 (앞 조명 / 뒤 조명)
local METHODS = {
  main = { power = "set_power", bright = "set_bright", ct = "set_ct_abx", scene = "set_scene" },
  background = { power = "bg_set_power", bright = "bg_set_bright", ct = "bg_set_ct_abx", scene = "bg_set_scene" },
}

-- Power property name per component
-- 구성 요소별 전원 상태 이름
local POWER_PROP = { main = "main_power", background = "bg_power" }

local CT_MIN, CT_MAX = 2700, 6500

local POLL_INTERVAL = 300    -- Health-check poll interval (s) / 확인용 폴링 간격 (초)
local POLL_TIMEOUT = 5       -- No answer within this time means a dead connection (s) / 이 시간 안에 응답이 없으면 연결이 조용히 끊긴 것으로 봄 (초)
local RETRY_FIRST = 30       -- First wait after a failed reconnect (s) / 다시 연결에 실패했을 때 첫 대기 시간 (초)
local RETRY_MAX = 60         -- Maximum wait; doubles on each failure (s) / 대기 시간 최대. 실패할 때마다 두 배로 늘어남 (초)
local REDISCOVER_EVERY = 3   -- After this many failures in a row, search for a new IP / 이 횟수만큼 연달아 실패하면 IP가 바뀌었는지 검색

-- IPs found during discovery, kept briefly (device id → IP)
-- 검색 중에 찾은 기기의 IP를 잠깐 기억해 두는 곳 (기기 id → IP)
local discovered_ips = {}

-------------------------------------------------------------------
-- 1. Discovery (SSDP)
--    기기 검색 (SSDP)
-------------------------------------------------------------------
local function parse_ssdp(data)
  local info = {}
  for line in data:gmatch("[^\r\n]+") do
    local key, value = line:match("^([%w_%-]+):%s*(.-)%s*$")
    if key then info[key:lower()] = value end
  end
  return info
end

local SSDP_REQUEST = table.concat({
  "M-SEARCH * HTTP/1.1",
  "HOST: 239.255.255.250:1982",
  'MAN: "ssdp:discover"',
  "ST: wifi_bulb",
  "", "",
}, "\r\n")

local function ssdp_ip(info, sender_ip)
  return (info["location"] or ""):match("yeelight://([%d%.]+):") or sender_ip
end

local function discovery_handler(driver, _, should_continue)
  log.info("[yeelight] discovery started")
  local udp = socket.udp()
  udp:setsockname("*", 0)
  udp:settimeout(2)

  local known = {}
  for _, device in ipairs(driver:get_devices()) do
    known[device.device_network_id] = true
  end

  local tries = 0
  while should_continue() and tries < 5 do
    tries = tries + 1
    udp:sendto(SSDP_REQUEST, SSDP_ADDR, SSDP_PORT)
    while true do
      local data, sender_ip = udp:receivefrom()
      if not data then break end
      local info = parse_ssdp(data)
      local model = info["model"]
      local ip = ssdp_ip(info, sender_ip)
      log.info(string.format("[yeelight] found: id=%s model=%s ip=%s",
        tostring(info["id"]), tostring(model), tostring(ip)))

      local supported = model and SUPPORTED_MODELS[model]
      if info["id"] and supported then
        local dni = "yl-" .. info["id"]
        if not known[dni] then
          known[dni] = true
          discovered_ips[dni] = ip
          driver:try_create_device({
            type = "LAN",
            device_network_id = dni,
            label = supported.label,
            profile = supported.profile,
            manufacturer = "Yeelight",
            model = model,
            vendor_provided_label = supported.label,
          })
        end
      end
    end
  end
  udp:close()
  log.info("[yeelight] discovery finished")
end

-- Find the current IP of an already added device (when the router assigned a new IP)
-- 이미 추가된 기기의 현재 IP를 검색으로 다시 찾기 (공유기가 IP를 바꿨을 때)
local function find_ip(device)
  local udp = socket.udp()
  udp:setsockname("*", 0)
  udp:settimeout(1)
  local found
  for _ = 1, 3 do
    udp:sendto(SSDP_REQUEST, SSDP_ADDR, SSDP_PORT)
    while true do
      local data, sender_ip = udp:receivefrom()
      if not data then break end
      local info = parse_ssdp(data)
      if info["id"] and "yl-" .. info["id"] == device.device_network_id then
        found = ssdp_ip(info, sender_ip)
        break
      end
    end
    if found then break end
  end
  udp:close()
  return found
end

-------------------------------------------------------------------
-- 2. Applying state (device values → SmartThings)
--    상태 반영 (기기 값 → 스마트싱스 화면)
-------------------------------------------------------------------
-- Emit only if this device's profile has the component (e.g. moonlight exists only on the ceiling light)
-- 이 기기의 프로필에 그 구성 요소가 있을 때만 반영 (예: 달빛은 천장등에만 있음)
local function emit(device, comp_id, event)
  local comp = device.profile.components[comp_id]
  if comp then device:emit_component_event(comp, event) end
end

local function has_moonlight(device)
  return device.profile.components["moonlight"] ~= nil
end

local function switch_event(value)
  if value == "on" then return capabilities.switch.switch.on() end
  return capabilities.switch.switch.off()
end

-- Apply values reported by the device (props notifications, get_prop results).
-- State changes only here; command handlers never emit state directly.
-- 기기가 알려 준 값(props 알림, get_prop 결과)을 화면에 반영
-- 화면 상태는 이 함수로만 바뀜 (명령을 보낸 쪽에서는 직접 바꾸지 않음)
local function apply_props(device, props)
  for key, value in pairs(props) do
    if value ~= nil and value ~= "" then
      local num = tonumber(value)
      if key == "main_power" or key == "power" then
        -- Front light on/off is computed once after the loop
        -- 앞 조명 켜짐/꺼짐은 반복문이 끝난 뒤에 한 번에 계산
        device:set_field(key, value)
      elseif key == "active_mode" and num then
        -- Main light mode (0 = normal, 1 = moonlight); switches are computed after the loop
        -- 본등 모드 (0 = 일반, 1 = 달빛). 스위치는 반복문이 끝난 뒤에 계산
        device:set_field("active_mode", num)
      elseif key == "nl_br" and num and num > 0 then
        -- Moonlight brightness (reported as 0 outside moonlight, so 0 is ignored)
        -- 달빛 밝기 (달빛이 아닐 때는 0으로 와서 0은 무시)
        emit(device, "moonlight", capabilities.switchLevel.level(num))
      elseif key == "bright" and num then
        emit(device, "main", capabilities.switchLevel.level(num))
      elseif key == "ct" and num then
        emit(device, "main", capabilities.colorTemperature.colorTemperature(num))
      elseif key == "bg_power" then
        emit(device, "background", switch_event(value))
      elseif key == "bg_bright" and num then
        emit(device, "background", capabilities.switchLevel.level(num))
      elseif key == "bg_ct" and num then
        emit(device, "background", capabilities.colorTemperature.colorTemperature(num))
      elseif key == "bg_hue" and num then
        -- Yeelight 0–359 → SmartThings 0–100
        -- Yeelight 0~359 → 스마트싱스 0~100
        emit(device, "background", capabilities.colorControl.hue(math.floor(num / 359 * 100 + 0.5)))
      elseif key == "bg_sat" and num then
        emit(device, "background", capabilities.colorControl.saturation(num))
      elseif key == "bg_lmode" and num then
        -- Back light mode (1 = RGB, 2 = color temperature, 3 = HSV)
        -- 뒤 조명 모드 (1 = RGB, 2 = 색온도, 3 = HSV)
        device:set_field("bg_lmode", num)
      elseif key == "bg_proact" and num then
        -- Device front/back link setting (1 = linked; can only be changed in the Yeelight app)
        -- 기기의 앞뒤 연동 설정 (1 = 연동, Yeelight 앱에서만 바꿀 수 있음)
        device:set_field("bg_proact", num)
      end
    end
  end
  -- Front light is on only when both power (whole device) and main_power are on
  -- (the device may report main_power "on" while turning off, so power is checked too)
  -- 앞 조명: 전체 전원(power)과 앞 조명 전원(main_power)이 둘 다 on일 때만 켜짐
  -- (끌 때 기기가 main_power를 "on"으로 잘못 보내서 power도 같이 봐야 함)
  if props.power or props.main_power or props.active_mode then
    local main_on = device:get_field("power") == "on" and device:get_field("main_power") == "on"
    emit(device, "main", switch_event(main_on and "on" or "off"))
    -- Ceiling light: the main switch is the power (on in moonlight too);
    -- the moonlight switch is the mode
    -- 천장등: 본등 스위치는 전원(달빛 중에도 켜짐), 달빛 스위치는 모드
    local moon_on = main_on and device:get_field("active_mode") == 1
    emit(device, "moonlight", switch_event(moon_on and "on" or "off"))
  end
end

-------------------------------------------------------------------
-- 3. Persistent connection (one TCP connection per device, kept open)
--    연결 유지 (기기마다 TCP 연결 하나를 열어 두고 계속 사용)
-------------------------------------------------------------------
local driver -- Created below; needed to register channel handlers / 아래에서 만든 드라이버 (연결 등록에 필요)
local next_id = 0
-- Defined below (declared first because they call each other)
-- 아래에서 정의 (서로 부르기 때문에 미리 이름만 선언)
local get_conn, refresh, verify_main

-- Handle one line received from the device
-- 기기에서 받은 한 줄 처리
local function handle_line(device, line)
  local ok, decoded = pcall(json.decode, line)
  if not ok or type(decoded) ~= "table" then
    log.warn("[yeelight] unknown message: " .. line)
    return
  end

  if decoded.method == "props" and decoded.params then
    -- Changes pushed by the device (from SmartThings, remote, Yeelight app — all come here)
    -- 기기가 먼저 알려 준 변경 사항 (스마트싱스, 리모컨, Yeelight 앱 등 모두 여기로 들어옴)
    log.debug("[yeelight] props: " .. line)
    local params = decoded.params
    if params.main_power ~= nil then
      -- main_power in notifications is unreliable (it says "on" when the front turns off
      -- while the back is still on). Ignore it and re-read with get_prop shortly (get_prop is correct).
      -- 알림의 main_power는 믿을 수 없음 (뒤 조명이 켜져 있으면 앞 조명을 꺼도 "on"으로 옴)
      -- 그래서 이 값은 쓰지 않고 잠시 뒤 get_prop으로 다시 읽어서 반영 (get_prop 값은 정확함)
      params.main_power = nil
      verify_main(device)
    end
    apply_props(device, params)
    return
  end

  if decoded.id then
    -- Answer to a command we sent
    -- 보낸 명령에 대한 응답
    local requests = device:get_field("requests") or {}
    local req = requests[decoded.id]
    requests[decoded.id] = nil
    if decoded.error then
      log.warn(string.format("[yeelight] error (%s): %s",
        req and req.method or "?", tostring(decoded.error.message)))
    else
      log.debug("[yeelight] result: " .. line)
      if req and req.on_result then req.on_result(decoded.result) end
    end
  end
end

local function close_conn(device, reason)
  local sock = device:get_field("sock")
  if sock then
    log.warn("[yeelight] connection closed: " .. tostring(reason))
    driver:unregister_channel_handler(sock)
    sock:close()
    device:set_field("sock", nil)
  end
  device:set_field("requests", {})
end

-- Reconnect after `delay` seconds (does nothing if already scheduled).
-- Without `delay`, waits 30s → 60s → 60s … after each failure.
-- delay초 뒤에 다시 연결 시도 (이미 예약돼 있으면 그대로 둠)
-- delay를 주지 않으면 실패할 때마다 30초 → 60초 → 60초 …로 기다림
local function schedule_reconnect(device, delay)
  if device:get_field("removed") or device:get_field("reconnect_timer") then return end
  if delay then
    device:set_field("retry_delay", RETRY_FIRST)
  else
    delay = device:get_field("retry_delay") or RETRY_FIRST
    device:set_field("retry_delay", math.min(delay * 2, RETRY_MAX))
  end
  log.info(string.format("[yeelight] reconnecting in %ds", delay))
  local timer = device.thread:call_with_delay(delay, function()
    device:set_field("reconnect_timer", nil)
    -- Already reconnected by a command in the meantime
    -- 그 사이 명령으로 이미 연결됨
    if device:get_field("sock") then return end
    -- Catch up on changes missed while disconnected
    -- 끊긴 동안 바뀐 상태 맞추기
    if get_conn(device) then refresh(device) end
  end)
  device:set_field("reconnect_timer", timer)
end

-- Open a connection if there is none, and register it to receive lines from the device
-- 연결이 없으면 새로 열고, 기기가 보내는 줄을 받을 수 있게 등록
function get_conn(device)
  local sock = device:get_field("sock")
  if sock then return sock end

  local ip = device:get_field("ip")
  if not ip then
    log.warn("[yeelight] unknown IP: " .. device.label)
    return nil
  end

  sock = socket.tcp()
  sock:settimeout(3)
  local ok, err = sock:connect(ip, YEELIGHT_PORT)
  if not ok then
    log.error("[yeelight] connect failed " .. ip .. ": " .. tostring(err))
    sock:close()
    device:offline()

    -- After several failures in a row, check whether the IP changed
    -- 여러 번 연달아 실패하면 IP가 바뀌었는지 검색
    local fails = (device:get_field("fail_count") or 0) + 1
    device:set_field("fail_count", fails)
    if fails % REDISCOVER_EVERY == 0 then
      local new_ip = find_ip(device)
      if new_ip and new_ip ~= ip then
        log.info(string.format("[yeelight] IP changed: %s -> %s", ip, new_ip))
        device:set_field("ip", new_ip, { persist = true })
        schedule_reconnect(device, 1)
        return nil
      end
      log.info("[yeelight] not found by search, keeping IP " .. ip)
    end
    schedule_reconnect(device)
    return nil
  end
  pcall(sock.setoption, sock, "keepalive", true)

  device:set_field("sock", sock)
  device:set_field("requests", {})
  driver:register_channel_handler(sock, function(_, s)
    local line, rerr = s:receive("*l")
    if line then
      handle_line(device, line)
    elseif rerr ~= "timeout" then
      close_conn(device, rerr)
      -- The device closed the connection; reconnect in 5s
      -- 기기가 연결을 끊으면 5초 뒤 바로 다시 연결
      schedule_reconnect(device, 5)
    end
  end, "yeelight-" .. device.device_network_id)

  log.info("[yeelight] connected: " .. ip)
  device:set_field("retry_delay", nil)
  device:set_field("fail_count", 0)
  device:online()
  return sock
end

-- Send a command without waiting for the answer (on_result is called when it arrives)
-- 명령 보내기 (답을 기다리지 않음. 답이 오면 on_result가 불림)
local function send_command(device, method, params, on_result)
  for attempt = 1, 2 do
    local sock = get_conn(device)
    if not sock then return false end

    next_id = next_id % 100000 + 1
    local requests = device:get_field("requests") or {}
    requests[next_id] = { method = method, on_result = on_result }
    device:set_field("requests", requests)

    local payload = json.encode({ id = next_id, method = method, params = params })
    log.debug("[yeelight] send: " .. payload)
    local ok, err = sock:send(payload .. "\r\n")
    if ok then return true end

    -- The kept connection was already dead; reconnect once and resend
    -- 열어 둔 연결이 이미 끊겨 있었으면 한 번만 새로 연결해서 다시 보냄
    requests[next_id] = nil
    close_conn(device, err)
    if attempt == 2 then return false end
  end
end

-- Re-check the front light on/off with get_prop (runs once even if called several times within 0.5s)
-- 앞 조명 켜짐/꺼짐을 get_prop으로 다시 확인 (0.5초 안에 여러 번 불려도 한 번만 확인)
function verify_main(device)
  if device:get_field("verify_timer") then return end
  local timer = device.thread:call_with_delay(0.5, function()
    device:set_field("verify_timer", nil)
    send_command(device, "get_prop", { "power", "main_power" }, function(result)
      if type(result) == "table" then
        apply_props(device, { power = result[1], main_power = result[2] })
      end
    end)
  end)
  device:set_field("verify_timer", timer)
end

-------------------------------------------------------------------
-- 4. Refresh and commands
--    새로고침과 버튼 동작
-------------------------------------------------------------------
function refresh(device, on_answer)
  return send_command(device, "get_prop", PROPS, function(result)
    if on_answer then on_answer() end
    if type(result) ~= "table" then return end
    local props = {}
    for i, name in ipairs(PROPS) do props[name] = result[i] end
    apply_props(device, props)
  end)
end

-- Health-check poll: sync state; no answer means a dead connection, so reconnect
-- 확인용 폴링: 상태를 맞추고, 응답이 없으면 연결이 조용히 끊긴 것으로 보고 다시 연결
local function poll(device)
  local answered = false
  if not refresh(device, function() answered = true end) then return end
  device.thread:call_with_delay(POLL_TIMEOUT, function()
    if not answered and device:get_field("sock") then
      close_conn(device, "no answer to poll")
      schedule_reconnect(device, 1)
    end
  end)
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function is_on(device, comp_id)
  return device:get_latest_state(comp_id, capabilities.switch.ID, capabilities.switch.switch.NAME) == "on"
end

local function current_level(device, comp_id)
  local level = device:get_latest_state(comp_id, capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME)
  return clamp(math.floor(tonumber(level) or 100), 1, 100)
end

local function current_ct(device, comp_id)
  local ct = device:get_latest_state(comp_id, capabilities.colorTemperature.ID, capabilities.colorTemperature.colorTemperature.NAME)
  return clamp(math.floor(tonumber(ct) or CT_MAX), CT_MIN, CT_MAX)
end

-- SmartThings 0–100 → Yeelight 0–359
-- 스마트싱스 0~100 → Yeelight 0~359
local function to_yeelight_hue(hue_pct)
  return clamp(math.floor(hue_pct / 100 * 359 + 0.5), 0, 359)
end

-- Build set_scene params that turn on with color and brightness at once.
-- Uses the value saved while off if there is one, otherwise the current mode and values.
-- 켜면서 색과 밝기를 한 번에 정하는 set_scene 값 만들기
-- 꺼져 있는 동안 저장해 둔 값이 있으면 그 값, 없으면 지금 모드와 값 그대로
local function scene_params(device, comp_id, level)
  level = level or current_level(device, comp_id)
  local pending = device:get_field("pending_" .. comp_id)
  if pending and pending.kind == "hsv" then
    return { "hsv", pending.hue, pending.sat, level }
  elseif pending and pending.kind == "ct" then
    return { "ct", pending.ct, level }
  elseif comp_id == "background" and device:get_field("bg_lmode") == 3 then
    local hue = device:get_latest_state("background", capabilities.colorControl.ID, "hue") or 0
    local sat = device:get_latest_state("background", capabilities.colorControl.ID, "saturation") or 100
    return { "hsv", to_yeelight_hue(hue), clamp(math.floor(sat), 0, 100), level }
  end
  return { "ct", current_ct(device, comp_id), level }
end

-- Defined below (declared first because it and power call each other)
-- 아래에서 정의 (power와 서로 부르기 때문에 이름만 먼저 선언)
local turn_on_with_scene

-- On/off state is updated by the device's props notifications
-- 화면의 켜짐/꺼짐은 기기가 보내는 props 알림으로 바뀜
local function power(device, comp_id, on)
  if on and device:get_field("pending_" .. comp_id) then
    -- Color temperature or color was changed while off: turn on straight to it (no flash of the old color)
    -- 꺼져 있는 동안 색온도나 색을 바꿨으면 그 값으로 바로 켜기 (예전 색이 잠깐 보이지 않게)
    return turn_on_with_scene(device, comp_id)
  end
  local params = { on and "on" or "off", "smooth", 500 }
  if on and comp_id == "main" and has_moonlight(device) then
    -- Ceiling light: the main switch turns on the normal light (leaves moonlight)
    -- 천장등: 본등 스위치는 일반 조명으로 켬 (달빛이면 일반으로 바뀜)
    params[4] = MODE_NORMAL
  end
  send_command(device, METHODS[comp_id].power, params)
end

local function in_moonlight(device)
  return has_moonlight(device) and is_on(device, "moonlight")
end

-- Turn on with set_scene (the saved value is used and cleared here)
-- set_scene으로 켜기 (저장해 둔 값은 여기서 사용하고 지움)
function turn_on_with_scene(device, comp_id, level)
  local params = scene_params(device, comp_id, level)
  device:set_field("pending_" .. comp_id, nil)
  send_command(device, METHODS[comp_id].scene, params)
  -- The device's front/back link applies to set_power only, not set_scene,
  -- so when linked, turn the back light on ourselves
  -- 기기의 앞뒤 연동은 set_power에만 적용되고 set_scene에는 적용되지 않음
  -- 그래서 연동이 켜져 있으면 앞 조명을 set_scene으로 켤 때 뒤 조명도 직접 켜 줌
  if comp_id == "main" and device.profile.components["background"]
    and device:get_field("bg_proact") == 1 and not is_on(device, "background") then
    power(device, "background", true)
  end
end

-- Moonlight on: switch to moonlight (turns on if off)
-- 달빛 켜기: 달빛으로 바꿈 (꺼져 있으면 달빛으로 켜짐)
local function moonlight_on(device, level)
  send_command(device, "set_power", { "on", "smooth", 500, MODE_MOON })
  if level then
    -- In moonlight, set_bright sets the moonlight brightness
    -- 달빛 모드에서는 set_bright가 달빛 밝기를 바꿈
    send_command(device, "set_bright", { level, "smooth", 300 })
  end
end

-- Moonlight off: back to the normal light (the light stays on); does nothing if the light is off
-- 달빛 끄기: 일반 조명으로 돌아감 (불은 켜진 채). 불이 꺼져 있으면 아무것도 안 함
local function moonlight_off(device)
  if not in_moonlight(device) then return end
  power(device, "main", true)
end

local function handle_on(_, device, command)
  if command.component == "moonlight" then return moonlight_on(device) end
  power(device, command.component, true)
end

local function handle_off(_, device, command)
  if command.component == "moonlight" then return moonlight_off(device) end
  power(device, command.component, false)
end

local function handle_set_level(_, device, command)
  local comp_id = command.component
  local level = clamp(math.floor(command.args.level), 0, 100)
  if comp_id == "moonlight" then
    -- Moonlight brightness: 0 turns the light off; otherwise turn on moonlight at this level
    -- 달빛 밝기: 0이면 조명 끄기, 아니면 그 밝기의 달빛으로 켜기
    if level == 0 then return power(device, "main", false) end
    if in_moonlight(device) then
      return send_command(device, "set_bright", { level, "smooth", 300 })
    end
    return moonlight_on(device, level)
  end
  if level == 0 then return power(device, comp_id, false) end
  if not is_on(device, comp_id) or (comp_id == "main" and in_moonlight(device)) then
    -- Off or in moonlight: turn on the normal light at this level
    -- 꺼져 있거나 달빛 중이면 그 밝기의 일반 조명으로 켜기
    -- (same as Matter's MoveToLevelWithOnOff)
    -- (Matter의 MoveToLevelWithOnOff와 같은 동작)
    return turn_on_with_scene(device, comp_id, level)
  end
  send_command(device, METHODS[comp_id].bright, { level, "smooth", 300 })
end

local function handle_set_ct(_, device, command)
  local comp_id = command.component
  local ct = clamp(math.floor(command.args.temperature), CT_MIN, CT_MAX)
  if not is_on(device, comp_id) or (comp_id == "main" and in_moonlight(device)) then
    -- Off or in moonlight (e.g. Circadian Lighting): save the value without turning on (like Matter ExecuteIfOff; applied with set_scene on turn-on).
    -- Nothing is sent, so no notification comes back; update the UI directly.
    -- 꺼져 있으면 켜지 않고 값만 저장 (Matter 표준 ExecuteIfOff와 같은 동작. 켤 때 set_scene으로 적용)
    -- 기기로 보내는 게 없어서 알림이 오지 않으므로 화면은 직접 바꿈
    device:set_field("pending_" .. comp_id, { kind = "ct", ct = ct })
    emit(device, comp_id, capabilities.colorTemperature.colorTemperature(ct))
    return
  end
  send_command(device, METHODS[comp_id].ct, { ct, "smooth", 300 })
end

local function set_bg_color(device, hue_pct, sat)
  local hue = to_yeelight_hue(hue_pct)
  sat = clamp(math.floor(sat), 0, 100)
  if not is_on(device, "background") then
    -- Off: save the value without turning on (applied with bg_set_scene on turn-on)
    -- 꺼져 있으면 켜지 않고 값만 저장 (켤 때 bg_set_scene으로 적용)
    device:set_field("pending_background", { kind = "hsv", hue = hue, sat = sat })
    emit(device, "background", capabilities.colorControl.hue(math.floor(hue / 359 * 100 + 0.5)))
    emit(device, "background", capabilities.colorControl.saturation(sat))
    return
  end
  send_command(device, "bg_set_hsv", { hue, sat, "smooth", 300 })
end

local function current_bg(device, attr)
  return device:get_latest_state("background", capabilities.colorControl.ID, attr) or 0
end

local function handle_set_color(_, device, command)
  local c = command.args.color
  set_bg_color(device, c.hue or current_bg(device, "hue"), c.saturation or current_bg(device, "saturation"))
end

local function handle_set_hue(_, device, command)
  set_bg_color(device, command.args.hue, current_bg(device, "saturation"))
end

local function handle_set_saturation(_, device, command)
  set_bg_color(device, current_bg(device, "hue"), command.args.saturation)
end

local function handle_refresh(_, device)
  -- Refresh also reconnects if there is no answer
  -- 새로고침도 응답이 없으면 다시 연결
  poll(device)
end

-------------------------------------------------------------------
-- 5. Device added / hub restarted
--    기기가 생기거나 허브가 재시작될 때
-------------------------------------------------------------------
local function ensure_ip(device)
  if not device:get_field("ip") then
    local ip = discovered_ips[device.device_network_id]
    if ip then device:set_field("ip", ip, { persist = true }) end
  end
end

local function device_init(_, device)
  log.info("[yeelight] init: " .. device.label)
  ensure_ip(device)
  -- Report the supported ranges (used by Circadian Lighting and Fade)
  -- 조명이 낼 수 있는 범위 알려 주기 (하루 조명·페이드 효과가 사용)
  for _, comp_id in ipairs({ "main", "background" }) do
    emit(device, comp_id, capabilities.switchLevel.levelRange({ value = { minimum = 1, maximum = 100 } }))
    emit(device, comp_id, capabilities.colorTemperature.colorTemperatureRange({ value = { minimum = CT_MIN, maximum = CT_MAX } }))
  end
  emit(device, "moonlight", capabilities.switchLevel.levelRange({ value = { minimum = 1, maximum = 100 } }))
  refresh(device)
  device.thread:call_on_schedule(POLL_INTERVAL, function() poll(device) end, "yeelight-poll")
end

local function device_added(_, device)
  ensure_ip(device)
  refresh(device)
end

local function device_removed(_, device)
  -- Mark as removed so it does not reconnect
  -- 다시 연결하지 않도록 표시
  device:set_field("removed", true)
  local timer = device:get_field("reconnect_timer")
  if timer then device.thread:cancel_timer(timer) end
  close_conn(device, "device removed")
end

driver = Driver("yeelight-lan", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_on,
      [capabilities.switch.commands.off.NAME] = handle_off,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_level,
    },
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = handle_set_ct,
    },
    [capabilities.colorControl.ID] = {
      [capabilities.colorControl.commands.setColor.NAME] = handle_set_color,
      [capabilities.colorControl.commands.setHue.NAME] = handle_set_hue,
      [capabilities.colorControl.commands.setSaturation.NAME] = handle_set_saturation,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
})

log.info("[yeelight] driver started")
driver:run()