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

-- Learn an IR code over a persistent TCP connection.
-- TCP 연결을 유지하면서 IR 코드를 학습함.
local function learn_ir(ip, dev_id, key, send_dp, learn_dp, timeout)
  local tcp = socket.tcp()
  tcp:settimeout(TIMEOUT)

  local ok, err = tcp:connect(ip, PORT)
  if not ok then
    tcp:close()
    return nil, "connect failed: " .. tostring(err)
  end

  local function send_mode(mode)
    seq = seq + 1

    local dps = {
      [send_dp] = json.encode({ control = mode })
    }

    local packet = tuya.build_control(
      dev_id, key, seq, tostring(os.time()), dps
    )

    local sent, serr = tcp:send(packet)

    if not sent then
      return nil, "send failed: " .. tostring(serr)
    end

    return true
  end

  local function receive_code()
    -- Reset the previous learning session.
    local sent, serr = send_mode("study_exit")
    if not sent then return nil, serr end

    -- Start learning.
    sent, serr = send_mode("study")
    if not sent then return nil, serr end

    log.info("IR: waiting for remote signal")

    local deadline = os.time() + timeout

    while os.time() < deadline do
      tcp:settimeout(math.max(1, deadline - os.time()))

      local packet, perr = read_packet(tcp)
      if not packet then
        return nil, perr
      end

      local cmd, retcode, plain = tuya.parse(packet, key)

      if not cmd then
        return nil, "IR parse failed: " .. tostring(retcode)
      end

      log.info(string.format(
        "IR reply: cmd=%d retcode=%d size=%d",
        cmd, retcode, #plain
      ))

      if retcode ~= 0 then
        return nil, "IR device error: " .. tostring(retcode)
      end

      if cmd == 0x08 and plain ~= "" then
        local decoded = json.decode(plain)

        if type(decoded) == "table"
            and type(decoded.dps) == "table" then

          local code = decoded.dps[learn_dp]

          if type(code) == "string" and #code > 0 then
            log.info("IR: code received")
            return code
          end
        end
      end
    end

    return nil, "IR learning timeout"
  end

  local success, code, receive_err = pcall(receive_code)

  -- Exit learning mode even after a failure.
  -- 학습에 실패해도 학습 모드를 종료함.
  local cleanup_ok, cleanup_result, cleanup_err = pcall(function()
    tcp:settimeout(TIMEOUT)
    return send_mode("study_exit")
  end)

  if not cleanup_ok or not cleanup_result then
    log.warn("IR: study_exit failed: " ..
      tostring(cleanup_ok and cleanup_err or cleanup_result))
  end

  tcp:close()

  if not success then
    return nil, tostring(code)
  end

  return code, receive_err
end

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

local function session_receive(session)
  if session.closed then return end

  local tcp = session.tcp
  tcp:settimeout(RECEIVE_TIMEOUT)

  -- Read complete packets while preserving partial data.
  -- 부분 수신 데이터를 보존하면서 완전한 패킷을 읽음.
  for _ = 1, MAX_PACKETS do
    local target = tuya.HEADER_LEN

    if #session.buffer >= tuya.HEADER_LEN then
      local size, err = tuya.packet_size(session.buffer)

      if not size then
        close_session(session, "bad header: " .. tostring(err))
        return
      end

      if size < tuya.HEADER_LEN + 12
        or size > MAX_PACKET_SIZE then
        close_session(session, "invalid packet size")
        return
      end

      target = size
    end

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

    if #session.buffer >= tuya.HEADER_LEN then
      local size, err = tuya.packet_size(session.buffer)

      if not size then
        close_session(session, "bad header: " .. tostring(err))
        return
      end

      if size < tuya.HEADER_LEN + 12
        or size > MAX_PACKET_SIZE then
        close_session(session, "invalid packet size")
        return
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
  query_status = query_status,
  send_control = send_control,
  learn_ir = learn_ir,

  open_session = open_session,
  close_session = close_session,
  session_query = session_query,
  session_control = session_control,
}