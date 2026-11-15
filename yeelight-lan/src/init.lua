-- Yeelight LAN 드라이버 (Light Bar: 앞 조명 + 뒤 조명)
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local socket = require "cosock.socket"
local json = require "st.json"
local log = require "log"

local YEELIGHT_PORT = 55443
local SSDP_ADDR = "239.255.255.250"
local SSDP_PORT = 1982

-- 지원하는 모델 → 사용할 프로필
local SUPPORTED_MODELS = {
  lamp15 = { profile = "yeelight-lightbar", label = "Yeelight Light Bar" },
}

-- 새로고침 때 읽어 올 값들
local PROPS = { "power", "main_power", "bright", "ct", "bg_power", "bg_bright", "bg_ct", "bg_hue", "bg_sat", "bg_lmode", "bg_proact" }

-- 구성 요소별 명령 이름 (앞 조명 / 뒤 조명)
local METHODS = {
  main = { power = "set_power", bright = "set_bright", ct = "set_ct_abx", scene = "set_scene" },
  background = { power = "bg_set_power", bright = "bg_set_bright", ct = "bg_set_ct_abx", scene = "bg_set_scene" },
}

-- 구성 요소별 전원 상태 이름
local POWER_PROP = { main = "main_power", background = "bg_power" }

local CT_MIN, CT_MAX = 2700, 6500

local POLL_INTERVAL = 300    -- 확인용 폴링 간격 (초)
local POLL_TIMEOUT = 5       -- 폴링 응답을 기다리는 시간 (초). 넘으면 연결이 조용히 끊긴 것으로 봄
local RETRY_FIRST = 30       -- 다시 연결에 실패했을 때 첫 대기 시간 (초)
local RETRY_MAX = 60         -- 대기 시간 최대 (초). 실패할 때마다 두 배로 늘어남
local REDISCOVER_EVERY = 3   -- 연결이 이 횟수만큼 연달아 실패하면 IP가 바뀌었는지 검색

-- 검색 중에 찾은 기기의 IP를 잠깐 기억해 두는 곳 (기기 id → IP)
local discovered_ips = {}

-------------------------------------------------------------------
-- 1. 기기 검색 (SSDP)
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
  log.info("[yeelight] 검색 시작")
  local udp = socket.udp()
  udp:setsockname("*", 0)
  udp:settimeout(2)
  local request = SSDP_REQUEST

  local known = {}
  for _, device in ipairs(driver:get_devices()) do
    known[device.device_network_id] = true
  end

  local tries = 0
  while should_continue() and tries < 5 do
    tries = tries + 1
    udp:sendto(request, SSDP_ADDR, SSDP_PORT)
    while true do
      local data, sender_ip = udp:receivefrom()
      if not data then break end
      local info = parse_ssdp(data)
      local model = info["model"]
      local ip = ssdp_ip(info, sender_ip)
      log.info(string.format("[yeelight] 응답: id=%s model=%s ip=%s",
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
  log.info("[yeelight] 검색 끝")
end

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
-- 2. 상태 반영 (기기 값 → 스마트싱스 화면)
-------------------------------------------------------------------
local function emit(device, comp_id, event)
  local comp = device.profile.components[comp_id]
  if comp then device:emit_component_event(comp, event) end
end

local function switch_event(value)
  if value == "on" then return capabilities.switch.switch.on() end
  return capabilities.switch.switch.off()
end

-- 기기가 알려 준 값(props 알림, get_prop 결과)을 화면에 반영
-- 화면 상태는 이 함수로만 바뀜 (명령을 보낸 쪽에서는 직접 바꾸지 않음)
local function apply_props(device, props)
  for key, value in pairs(props) do
    if value ~= nil and value ~= "" then
      local num = tonumber(value)
      if key == "main_power" or key == "power" then
        device:set_field(key, value) -- 앞 조명 켜짐/꺼짐은 반복문이 끝난 뒤에 한 번에 계산
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
        -- Yeelight 0~359 → 스마트싱스 0~100
        emit(device, "background", capabilities.colorControl.hue(math.floor(num / 359 * 100 + 0.5)))
      elseif key == "bg_sat" and num then
        emit(device, "background", capabilities.colorControl.saturation(num))
      elseif key == "bg_lmode" and num then
        device:set_field("bg_lmode", num) -- 뒤 조명 모드 (2 = 색온도, 3 = 색)
      elseif key == "bg_proact" and num then
        device:set_field("bg_proact", num) -- 기기의 앞뒤 연동 설정 (1 = 연동, Yeelight 앱에서만 바꿀 수 있음)
      end
    end
  end
  -- 앞 조명: 전체 전원(power)과 앞 조명 전원(main_power)이 둘 다 on일 때만 켜짐
  -- (끌 때 기기가 main_power를 "on"으로 잘못 보내서 power도 같이 봐야 함)
  if props.power or props.main_power then
    local main_on = device:get_field("power") == "on" and device:get_field("main_power") == "on"
    emit(device, "main", switch_event(main_on and "on" or "off"))
  end
end

-------------------------------------------------------------------
-- 3. 연결 유지 (기기마다 TCP 연결 하나를 열어 두고 계속 사용)
-------------------------------------------------------------------
local driver -- 아래에서 만든 드라이버 (연결 등록에 필요)
local next_id = 0
local get_conn, refresh -- 아래에서 정의 (서로 부르기 때문에 미리 이름만 선언)

-- 기기에서 받은 한 줄 처리
local function handle_line(device, line)
  local ok, decoded = pcall(json.decode, line)
  if not ok or type(decoded) ~= "table" then
    log.warn("[yeelight] 알 수 없는 응답: " .. line)
    return
  end

  if decoded.method == "props" and decoded.params then
    -- 기기가 먼저 알려 준 변경 사항 (스마트싱스, 리모컨, Yeelight 앱 등 모두 여기로 들어옴)
    log.info("[yeelight] 알림: " .. line)
    apply_props(device, decoded.params)
    return
  end

  if decoded.id then
    -- 보낸 명령에 대한 응답
    local requests = device:get_field("requests") or {}
    local req = requests[decoded.id]
    requests[decoded.id] = nil
    if decoded.error then
      log.warn(string.format("[yeelight] 오류 (%s): %s",
        req and req.method or "?", tostring(decoded.error.message)))
    else
      log.debug("[yeelight] 응답: " .. line)
      if req and req.on_result then req.on_result(decoded.result) end
    end
  end
end

local function close_conn(device, reason)
  local sock = device:get_field("sock")
  if sock then
    log.warn("[yeelight] 연결 끊김: " .. tostring(reason))
    driver:unregister_channel_handler(sock)
    sock:close()
    device:set_field("sock", nil)
  end
  device:set_field("requests", {})
end

-- delay초 뒤에 다시 연결 시도 (이미 예약돼 있으면 그대로 둠)
-- delay를 주지 않으면 실패할 때마다 30초 → 60초 → 120초 … 최대 5분으로 늘림
local function schedule_reconnect(device, delay)
  if device:get_field("removed") or device:get_field("reconnect_timer") then return end
  if delay then
    device:set_field("retry_delay", RETRY_FIRST)
  else
    delay = device:get_field("retry_delay") or RETRY_FIRST
    device:set_field("retry_delay", math.min(delay * 2, RETRY_MAX))
  end
  log.info(string.format("[yeelight] %d초 뒤 다시 연결", delay))
  local timer = device.thread:call_with_delay(delay, function()
    device:set_field("reconnect_timer", nil)
    if device:get_field("sock") then return end -- 그 사이 명령으로 이미 연결됨
    if get_conn(device) then refresh(device) end -- 끊긴 동안 바뀐 상태 맞추기
  end)
  device:set_field("reconnect_timer", timer)
end

-- 연결이 없으면 새로 열고, 기기가 보내는 줄을 받을 수 있게 등록
function get_conn(device)
  local sock = device:get_field("sock")
  if sock then return sock end

  local ip = device:get_field("ip")
  if not ip then
    log.warn("[yeelight] IP를 모름: " .. device.label)
    return nil
  end

  sock = socket.tcp()
  sock:settimeout(3)
  local ok, err = sock:connect(ip, YEELIGHT_PORT)
  if not ok then
    log.error("[yeelight] 연결 실패 " .. ip .. ": " .. tostring(err))
    sock:close()
    device:offline()

    -- 여러 번 연달아 실패하면 IP가 바뀌었는지 검색
    local fails = (device:get_field("fail_count") or 0) + 1
    device:set_field("fail_count", fails)
    if fails % REDISCOVER_EVERY == 0 then
      local new_ip = find_ip(device)
      if new_ip and new_ip ~= ip then
        log.info(string.format("[yeelight] IP 바뀜: %s → %s", ip, new_ip))
        device:set_field("ip", new_ip, { persist = true })
        schedule_reconnect(device, 1)
        return nil
      end
      log.info("[yeelight] 검색으로도 못 찾음 (IP 그대로: " .. ip .. ")")
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
      schedule_reconnect(device, 5) -- 기기가 연결을 끊으면 5초 뒤 바로 다시 연결
    end
  end, "yeelight-" .. device.device_network_id)

  log.info("[yeelight] 연결됨: " .. ip)
  device:set_field("retry_delay", nil)
  device:set_field("fail_count", 0)
  device:online()
  return sock
end

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
    log.debug("[yeelight] 보냄: " .. payload)
    local ok, err = sock:send(payload .. "\r\n")
    if ok then return true end

    -- 열어 둔 연결이 이미 끊겨 있었으면 한 번만 새로 연결해서 다시 보냄
    requests[next_id] = nil
    close_conn(device, err)
    if attempt == 2 then return false end
  end
end

-------------------------------------------------------------------
-- 4. 새로고침과 버튼 동작
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

-- 확인용 폴링: 상태를 맞추고, 응답이 없으면 연결이 조용히 끊긴 것으로 보고 다시 연결
local function poll(device)
  local answered = false
  if not refresh(device, function() answered = true end) then return end
  device.thread:call_with_delay(POLL_TIMEOUT, function()
    if not answered and device:get_field("sock") then
      close_conn(device, "폴링 응답 없음")
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

local function to_yeelight_hue(hue_pct)
  return clamp(math.floor(hue_pct / 100 * 359 + 0.5), 0, 359) -- 스마트싱스 0~100 → Yeelight 0~359
end

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

local turn_on_with_scene -- 아래에서 정의 (power와 서로 부르기 때문에 이름만 먼저 선언)

-- 화면의 켜짐/꺼짐은 기기가 보내는 props 알림으로 바뀜
local function power(device, comp_id, on)
  if on and device:get_field("pending_" .. comp_id) then
    -- 꺼져 있는 동안 색온도나 색을 바꿨으면 그 값으로 바로 켜기 (예전 색이 잠깐 보이지 않게)
    return turn_on_with_scene(device, comp_id)
  end
  send_command(device, METHODS[comp_id].power, { on and "on" or "off", "smooth", 500 })
end

-- set_scene으로 켜기 (저장해 둔 값은 여기서 사용하고 지움)
function turn_on_with_scene(device, comp_id, level)
  local params = scene_params(device, comp_id, level)
  device:set_field("pending_" .. comp_id, nil)
  send_command(device, METHODS[comp_id].scene, params)
  -- 기기의 앞뒤 연동은 set_power에만 적용되고 set_scene에는 적용되지 않음
  -- 그래서 연동이 켜져 있으면 앞 조명을 set_scene으로 켤 때 뒤 조명도 직접 켜 줌
  if comp_id == "main" and device:get_field("bg_proact") == 1 and not is_on(device, "background") then
    power(device, "background", true)
  end
end

local function handle_on(_, device, command)
  power(device, command.component, true)
end

local function handle_off(_, device, command)
  power(device, command.component, false)
end

local function handle_set_level(_, device, command)
  local comp_id = command.component
  local level = clamp(math.floor(command.args.level), 0, 100)
  if level == 0 then return power(device, comp_id, false) end
  if not is_on(device, comp_id) then
    -- 꺼져 있으면 그 밝기로 바로 켜기 (Matter의 MoveToLevelWithOnOff와 같은 동작)
    return turn_on_with_scene(device, comp_id, level)
  end
  send_command(device, METHODS[comp_id].bright, { level, "smooth", 300 })
end

local function handle_set_ct(_, device, command)
  local comp_id = command.component
  local ct = clamp(math.floor(command.args.temperature), CT_MIN, CT_MAX)
  if not is_on(device, comp_id) then
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
  poll(device) -- 새로고침도 응답이 없으면 다시 연결
end

-------------------------------------------------------------------
-- 5. 기기가 생기거나 허브가 재시작될 때
-------------------------------------------------------------------
local function ensure_ip(device)
  if not device:get_field("ip") then
    local ip = discovered_ips[device.device_network_id]
    if ip then device:set_field("ip", ip, { persist = true }) end
  end
end

local function device_init(_, device)
  log.info("[yeelight] 기기 준비: " .. device.label)
  ensure_ip(device)
  -- 조명이 낼 수 있는 범위 알려 주기 (하루 조명·페이드 효과가 사용)
  for _, comp_id in ipairs({ "main", "background" }) do
    emit(device, comp_id, capabilities.switchLevel.levelRange({ value = { minimum = 1, maximum = 100 } }))
    emit(device, comp_id, capabilities.colorTemperature.colorTemperatureRange({ value = { minimum = CT_MIN, maximum = CT_MAX } }))
  end
  refresh(device)
  device.thread:call_on_schedule(POLL_INTERVAL, function() poll(device) end, "yeelight-poll")
end

local function device_added(_, device)
  ensure_ip(device)
  refresh(device)
end

local function device_removed(_, device)
  device:set_field("removed", true) -- 다시 연결하지 않도록 표시
  local timer = device:get_field("reconnect_timer")
  if timer then device.thread:cancel_timer(timer) end
  close_conn(device, "기기 삭제")
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

log.info("[yeelight] 드라이버 시작")
driver:run()