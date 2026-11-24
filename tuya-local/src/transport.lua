-- Tuya TCP transport / Tuya TCP 통신
local json = require "st.json"
local log = require "log"
local cosock = require "cosock"
local tuya = require "tuya"
local socket = cosock.socket
local TIMEOUT = 5             -- seconds for connect and each receive / 연결·수신 대기(초)
local PORT = 6668             -- Tuya local TCP port / Tuya 로컬 TCP 포트
local MAX_PACKETS = 5         -- packets to read while waiting for the status reply / 상태 응답을 기다리며 읽을 최대 패킷 수
local MAX_PACKET_SIZE = 4096  -- sanity limit / 비정상 패킷 방지
local seq = 0
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

return {
  query_status = query_status,
  send_control = send_control,
}
