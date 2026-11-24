-- Tuya Local (LAN) driver for SmartThings Edge
-- Polls a Tuya Wi-Fi thermo-hygrometer (protocol 3.3) over TCP and shows temperature / humidity.
-- Tuya 와이파이 온습도계(프로토콜 3.3)를 TCP로 주기적으로 조회해서 온도와 습도를 표시함.

local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local json = require "st.json"
local log = require "log"
local cosock = require "cosock"
local tuya = require "tuya"

local socket = cosock.socket

local PROFILE = "tuya-thermo-hygro"

local POLL_INTERVAL = 60      -- seconds between polls / 조회 간격(초)
local TIMEOUT = 5             -- seconds for connect and each receive / 연결·수신 대기(초)
local PORT = 6668             -- Tuya local TCP port / Tuya 로컬 TCP 포트
local MAX_PACKETS = 5         -- packets to read while waiting for the status reply / 상태 응답을 기다리며 읽을 최대 패킷 수
local MAX_PACKET_SIZE = 4096  -- sanity limit / 비정상 패킷 방지

-- Datapoint numbers of this device (thermo-hygrometer without IR).
-- 이 기기(IR 없는 온습도계)의 DP 번호.
local DP_TEMPERATURE = "1"    -- value is temperature x 10 / 온도 x 10
local DP_HUMIDITY = "2"       -- percent / 습도(%)

local seq = 0

---------------------------------------------------------------------------
-- Settings check / 설정 확인
---------------------------------------------------------------------------

-- True when IP, device ID and key are filled in (not the placeholder defaults).
-- IP, 기기 ID, 키가 기본값이 아닌 실제 값으로 채워졌는지 확인.
local function is_configured(p)
  local ip, id, key = p.deviceIp or "", p.deviceId or "", p.localKey or ""
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

---------------------------------------------------------------------------
-- Polling / 주기 조회
---------------------------------------------------------------------------

local function poll(device)
  if device:get_field("polling") then return end
  local p = device.preferences
  if not is_configured(p) then return end

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

  local temp, hum = dps[DP_TEMPERATURE], dps[DP_HUMIDITY]
  if type(temp) == "number" then
    device:emit_event(capabilities.temperatureMeasurement.temperature({ value = temp / 10, unit = "C" }))
  end
  if type(hum) == "number" then
    device:emit_event(capabilities.relativeHumidityMeasurement.humidity(hum))
  end
  log.info(string.format("%s: temperature=%s humidity=%s",
    device.device_network_id, tostring(type(temp) == "number" and temp / 10 or nil), tostring(hum)))
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
local function start_polling(device)
  stop_polling(device)
  if not is_configured(device.preferences) then
    log.info(device.device_network_id .. ": settings not complete yet, not polling")
    return
  end
  local timer = device.thread:call_on_schedule(POLL_INTERVAL, function() poll(device) end, "tuya-poll")
  device:set_field("poll_timer", timer)
  device.thread:call_with_delay(0, function() poll(device) end)
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
  start_polling(device)
end

-- Never log the local key itself, only its length.
-- Local Key는 로그에 남기지 않고 글자 수만 남김.
local function info_changed(_, device, _, _)
  local p = device.preferences
  log.info(string.format("%s: settings changed ip=%s id=%s key_len=%d",
    device.device_network_id, tostring(p.deviceIp), tostring(p.deviceId), #(p.localKey or "")))
  start_polling(device)
end

local function device_removed(_, device)
  log.info(device.device_network_id .. ": removed")
  stop_polling(device)
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