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
local PROPS = { "main_power", "bright", "ct", "bg_power", "bg_bright", "bg_ct", "bg_hue", "bg_sat" }

-- 구성 요소별 명령 이름 (앞 조명 / 뒤 조명)
local METHODS = {
  main = { power = "set_power", bright = "set_bright", ct = "set_ct_abx" },
  background = { power = "bg_set_power", bright = "bg_set_bright", ct = "bg_set_ct_abx" },
}

local CT_MIN, CT_MAX = 2700, 6500

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

local function discovery_handler(driver, _, should_continue)
  log.info("[yeelight] 검색 시작")
  local udp = socket.udp()
  udp:setsockname("*", 0)
  udp:settimeout(2)

  local request = table.concat({
    "M-SEARCH * HTTP/1.1",
    "HOST: 239.255.255.250:1982",
    'MAN: "ssdp:discover"',
    "ST: wifi_bulb",
    "", "",
  }, "\r\n")

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
      local ip = (info["location"] or ""):match("yeelight://([%d%.]+):") or sender_ip
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

-- 기기가 알려 준 값(props, get_prop 결과)을 화면에 반영
local function apply_props(device, props)
  for key, value in pairs(props) do
    if value ~= nil and value ~= "" then
      local num = tonumber(value)
      if key == "main_power" then
        emit(device, "main", switch_event(value))
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
      end
    end
  end
end

-------------------------------------------------------------------
-- 3. 명령 보내기 (TCP로 JSON 한 줄 보내고 답 받기)
-------------------------------------------------------------------
local function send_command(device, method, params)
  local ip = device:get_field("ip")
  if not ip then
    log.warn("[yeelight] IP를 모름: " .. device.label)
    return nil
  end

  local tcp = socket.tcp()
  tcp:settimeout(3)
  local ok, err = tcp:connect(ip, YEELIGHT_PORT)
  if not ok then
    log.error("[yeelight] 연결 실패 " .. ip .. ": " .. tostring(err))
    tcp:close()
    device:offline()
    return nil
  end

  local msg_id = math.random(1, 100000)
  local payload = json.encode({ id = msg_id, method = method, params = params })
  log.debug("[yeelight] 보냄: " .. payload)
  tcp:send(payload .. "\r\n")

  local result
  for _ = 1, 5 do
    local line, rerr = tcp:receive("*l")
    if not line then
      log.warn("[yeelight] 응답 없음: " .. tostring(rerr))
      break
    end
    log.debug("[yeelight] 받음: " .. line)
    local decoded = json.decode(line)
    if decoded then
      if decoded.method == "props" and decoded.params then
        apply_props(device, decoded.params) -- 기기가 먼저 알려 준 변경 사항 반영
      elseif decoded.id == msg_id then
        result = decoded
        if decoded.error then
          log.warn("[yeelight] 오류: " .. tostring(decoded.error.message))
        end
        break
      end
    end
  end
  tcp:close()
  device:online()
  return result
end

-------------------------------------------------------------------
-- 4. 새로고침과 버튼 동작
-------------------------------------------------------------------
local function refresh(device)
  local res = send_command(device, "get_prop", PROPS)
  if res and res.result then
    local props = {}
    for i, name in ipairs(PROPS) do props[name] = res.result[i] end
    apply_props(device, props)
  end
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function is_on(device, comp_id)
  return device:get_latest_state(comp_id, capabilities.switch.ID, capabilities.switch.switch.NAME) == "on"
end

local function power(device, comp_id, on)
  local value = on and "on" or "off"
  local res = send_command(device, METHODS[comp_id].power, { value, "smooth", 500 })
  if res and res.result then emit(device, comp_id, switch_event(value)) end
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
  if not is_on(device, comp_id) then power(device, comp_id, true) end
  send_command(device, METHODS[comp_id].bright, { level, "smooth", 300 })
end

local function handle_set_ct(_, device, command)
  local comp_id = command.component
  local ct = clamp(math.floor(command.args.temperature), CT_MIN, CT_MAX)
  if not is_on(device, comp_id) then power(device, comp_id, true) end
  send_command(device, METHODS[comp_id].ct, { ct, "smooth", 300 })
end

local function set_bg_color(device, hue_pct, sat)
  -- 스마트싱스 0~100 → Yeelight 0~359
  local hue = clamp(math.floor(hue_pct / 100 * 359 + 0.5), 0, 359)
  sat = clamp(math.floor(sat), 0, 100)
  if not is_on(device, "background") then power(device, "background", true) end
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
  refresh(device)
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
  refresh(device)
  device.thread:call_on_schedule(60, function() refresh(device) end, "yeelight-poll")
end

local function device_added(_, device)
  ensure_ip(device)
  refresh(device)
end

local driver = Driver("yeelight-lan", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
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