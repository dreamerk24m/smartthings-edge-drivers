-- Tuya TCP transport / Tuya TCP 통신
local log = require "log"
local cosock = require "cosock"
local tuya = require "tuya"
local socket = cosock.socket
local TIMEOUT = 5             -- connect and send timeout / 연결·전송 대기(초)
local PORT = 6668             -- Tuya local TCP port / Tuya 로컬 TCP 포트
local MAX_PACKETS = 5         -- maximum receive loop iterations / 수신 루프 최대 반복 횟수
local MAX_PACKET_SIZE = 4096  -- sanity limit / 비정상 패킷 방지
local seq = 0
---------------------------------------------------------------------------
-- Persistent TCP session / 지속 TCP 연결
---------------------------------------------------------------------------

local HEARTBEAT_INTERVAL = 10
local RECEIVE_TIMEOUT = 0.2

local function close_session(session, reason)
  if session.closed then return end
  session.closed = true

  if session.heartbeat_timer then
    session.thread:cancel_timer(session.heartbeat_timer)
    session.heartbeat_timer = nil
  end

  session.thread:unregister_socket(session.tcp)
  session.tcp:close()
  session.buffer = ""

  log.info(session.dni .. ": TCP disconnected" ..
      (reason and (": " .. reason) or ""))

  if session.on_close then
    session.on_close(session, reason)
  end
end

local function session_send(session, packet)
  if session.closed then
    return nil, "session closed"
  end

  session.tcp:settimeout(TIMEOUT)
  local sent, err = session.tcp:send(packet)

  if not sent then
    close_session(session, "send failed: " .. tostring(err))
    return nil, err
  end

  return true
end

local function session_query(session)
  seq = seq + 1

  return session_send(session, tuya.build_status_query(
      session.dev_id,
      session.key,
      seq,
      tostring(os.time())
  ))
end

local function session_control(session, dps)
  seq = seq + 1

  return session_send(session, tuya.build_control(
      session.dev_id,
      session.key,
      seq,
      tostring(os.time()),
      dps
  ))
end

local function session_heartbeat(session)
  if session.closed then return end

  -- Check the previous heartbeat response.
  -- 이전 하트비트 응답을 확인함.
  if session.heartbeat_pending then
    close_session(session, "heartbeat timeout")
    return
  end

  seq = seq + 1
  session.heartbeat_pending = true

  local ok = session_send(session, tuya.build_heartbeat(
      session.dev_id,
      session.key,
      seq
  ))

  if ok then
    log.debug(session.dni .. ": heartbeat TX")
  end
end

local function read_packet_size(session)
  local size, err = tuya.packet_size(session.buffer)
  if not size then
    close_session(session, "bad header: " .. tostring(err))
    return nil
  end
  if size < tuya.HEADER_LEN + 12 or size > MAX_PACKET_SIZE then
    close_session(session, "invalid packet size")
    return nil
  end
  return size
end

local function session_receive(session)
  if session.closed then return end

  local tcp = session.tcp
  tcp:settimeout(RECEIVE_TIMEOUT)

  -- Read complete packets while preserving partial data.
  -- 부분 수신 데이터를 보존하면서 완전한 패킷을 읽음.
  for _ = 1, MAX_PACKETS do
    local size
    if #session.buffer >= tuya.HEADER_LEN then
      size = read_packet_size(session)
      if not size then return end
    end

    local target = size or tuya.HEADER_LEN
    local needed = target - #session.buffer

    if needed > 0 then
      local data, err, partial = tcp:receive(needed)
      session.buffer = session.buffer .. (data or partial or "")

      if err and err ~= "timeout" then
        close_session(session, "receive failed: " .. tostring(err))
        return
      end

      if #session.buffer < target then
        return
      end
    end

    if not size then
      size = read_packet_size(session)
      if not size then return end
    end

    if #session.buffer >= size then
      local packet = session.buffer:sub(1, size)
      session.buffer = session.buffer:sub(size + 1)

      local cmd, retcode, plain =
      tuya.parse(packet, session.key)

      if not cmd then
        log.warn(session.dni ..
            ": packet parse failed: " .. tostring(retcode))

      elseif cmd == tuya.CMD_HEARTBEAT then
        if retcode == 0 then
          session.heartbeat_pending = false
          log.debug(session.dni .. ": heartbeat ACK")
        else
          close_session(session, "heartbeat rejected")
          return
        end

      elseif session.on_packet then
        session.on_packet(session, cmd, retcode, plain)

        if session.closed then return end
      end
    end
  end
end

local function open_session(device, on_packet, on_close)
  local p = device.preferences
  local tcp, err = socket.tcp()

  if not tcp then
    return nil, err
  end

  tcp:settimeout(TIMEOUT)

  local ok, connect_err = tcp:connect(p.deviceIp, PORT)

  if not ok then
    tcp:close()
    return nil, "connect failed: " .. tostring(connect_err)
  end

  local session = {
    tcp = tcp,
    thread = device.thread,
    dni = device.device_network_id,
    dev_id = p.deviceId,
    key = p.localKey,
    buffer = "",
    closed = false,
    heartbeat_pending = false,
    on_packet = on_packet,
    on_close = on_close
  }

  device.thread:register_socket(
    tcp,
    function()
      session_receive(session)
    end,
    "tuya-tcp"
  )

  session.heartbeat_timer = device.thread:call_on_schedule(
    HEARTBEAT_INTERVAL,
    function()
      session_heartbeat(session)
    end,
    "tuya-heartbeat"
  )

  log.info(session.dni .. ": TCP connected")

  return session
end

return {

  open_session = open_session,
  close_session = close_session,
  session_query = session_query,
  session_control = session_control,
}
