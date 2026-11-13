-- Yeelight LAN 드라이버 (뼈대: 검색, 켜기/끄기, 새로고침)
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

-- 검색 중에 찾은 기기의 IP를 잠깐 기억해 두는 곳 (기기 id → IP)
local discovered_ips = {}

-------------------------------------------------------------------
-- 1. 기기 검색 (SSDP: 네트워크에 "Yeelight 있어?"라고 묻기)
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

  -- 이미 만든 기기는 다시 만들지 않기
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
      if not data then break end -- 2초 동안 응답이 없으면 다음 시도
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
-- 2. 명령 보내기 (TCP로 JSON 한 줄 보내고 답 받기)
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

  -- 기기가 상태 알림(props)을 먼저 보낼 수도 있어서, 내 id의 답을 찾을 때까지 몇 줄 읽기
  local result
  for _ = 1, 5 do
    local line, rerr = tcp:receive("*l")
    if not line then
      log.warn("[yeelight] 응답 없음: " .. tostring(rerr))
      break
    end
    log.debug("[yeelight] 받음: " .. line)
    local decoded = json.decode(line)
    if decoded and decoded.id == msg_id then
      result = decoded
      break
    end
  end
  tcp:close()
  device:online()
  return result
end

-------------------------------------------------------------------
-- 3. 상태 읽기와 버튼 동작
-------------------------------------------------------------------
local function refresh(device)
  local res = send_command(device, "get_prop", { "power" })
  if res and res.result then
    if res.result[1] == "on" then
      device:emit_event(capabilities.switch.switch.on())
    else
      device:emit_event(capabilities.switch.switch.off())
    end
  end
end

local function handle_on(_, device)
  local res = send_command(device, "set_power", { "on", "smooth", 500 })
  if res and res.result then device:emit_event(capabilities.switch.switch.on()) end
end

local function handle_off(_, device)
  local res = send_command(device, "set_power", { "off", "smooth", 500 })
  if res and res.result then device:emit_event(capabilities.switch.switch.off()) end
end

local function handle_refresh(_, device)
  refresh(device)
end

-------------------------------------------------------------------
-- 4. 기기가 생기거나 허브가 재시작될 때
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
  -- 앱이나 리모컨으로 바꾼 상태를 따라가려고 60초마다 확인
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
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
})

log.info("[yeelight] 드라이버 시작")
driver:run()