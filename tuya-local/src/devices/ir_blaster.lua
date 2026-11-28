-- Tuya IR blaster / Tuya IR 블래스터
local log = require "log"
local transport = require "transport"
local thermo_hygro = require "devices.thermo_hygro"
local json = require "st.json"
local capabilities = require "st.capabilities"

local M = {}

local THERMO_CHILD_KEY = "thermo-hygro"
local THERMO_CHILD_PROFILE = "tuya-ir-thermo-hygro"
local REMOTE_CHILD_PROFILE = "tuya-ir-remote"

-- Create the temperature and humidity child device.
-- 온습도계 자식 기기 생성.
function M.create_children(driver, device, product)
  if device:get_child_by_parent_assigned_key(THERMO_CHILD_KEY) then
    return
  end

  local ok, err = driver:try_create_device({
    type = "EDGE_CHILD",
    label = "IR Temperature & Humidity Sensor",
    profile = THERMO_CHILD_PROFILE,
    manufacturer = "Tuya",
    parent_device_id = device.id,
    parent_assigned_child_key = THERMO_CHILD_KEY,
  })

  log.info(string.format(
    "%s: create thermo child -> %s %s",
    device.device_network_id,
    tostring(ok),
    tostring(err)
  ))
end

-- Send measurements to the child device.
-- 측정값을 온습도계 자식 기기로 전달.
function M.apply(device, product, dps)
  local child = device:get_child_by_parent_assigned_key(
    THERMO_CHILD_KEY
  )

  if child then
    thermo_hygro.apply(child, product, dps)
  end
end

local LEARN_TIMEOUT = 30

-- Send an IR learning mode command on the current session.
-- 기존 TCP 연결에서 IR 학습 모드 명령 전송.
local function send_mode(session, product, mode)
  local dps = {
    [product.ir_send] = json.encode({
      control = mode
    })
  }

  local ok, err = transport.session_control(session, dps)

  if not ok then
    log.warn("IR: " .. mode .. " failed: " .. tostring(err))
    return nil, err
  end

  log.debug("IR: " .. mode .. " TX")
  return true
end

local function clear_learning_timer(session)
  local timer = session.ir_learning_timer

  if timer then
    session.ir_learning_timer = nil
    session.thread:cancel_timer(timer)
  end
end

-- Cancel learning when the TCP session closes.
-- TCP 연결 종료 시 학습 취소.
function M.cancel_learning(session)
  if session.ir_learning_timer then
    clear_learning_timer(session)
    log.warn("IR: learning cancelled, connection closed")
  end
end

-- Learn an IR code asynchronously.
-- 비동기 방식으로 IR 신호 학습.
function M.learn(device, product)
  local session = device:get_field("tuya_session")

  if not session or session.closed then
    log.warn("IR: learning skipped, not connected")
    return
  end

  if session.ir_learning_timer then
    log.warn("IR: learning already in progress")
    return
  end

  local timer

  timer = session.thread:call_with_delay(
    LEARN_TIMEOUT,

    function()
      if device:get_field("tuya_session") ~= session
        or session.closed
        or session.ir_learning_timer ~= timer then
        return
      end

      session.ir_learning_timer = nil

      log.warn("IR: learning timeout")
      send_mode(session, product, "study_exit")
    end,

    "tuya-ir-learning"
  )

  if not timer then
    log.warn("IR: failed to schedule learning timeout")
    return
  end

  session.ir_learning_timer = timer

  log.info("IR: learning started")

  if not send_mode(session, product, "study_exit") then
    clear_learning_timer(session)
    return
  end

  if not send_mode(session, product, "study") then
    clear_learning_timer(session)
    return
  end

  log.info("IR: waiting for remote signal")
end

-- Process a learned code received through DP push.
-- DP Push를 통해 수신한 학습 코드 처리.
function M.handle_push(device, product, dps, session)
  if not session.ir_learning_timer then
    return
  end

  local code = dps[product.ir_learn]

  if type(code) ~= "string" or #code == 0 then
    return
  end

  clear_learning_timer(session)

  device:set_field("ir_test_code", code)

  log.info("IR: learning successful")
  log.info("IR: learned code: " .. code)

  send_mode(session, product, "study_exit")
end

-- Send a learned IR code.
-- 학습한 IR 신호 전송.
function M.send(device, product, run_dps_control)
  local session = device:get_field("tuya_session")

  if session and session.ir_learning_timer then
    log.warn("IR: send skipped, learning in progress")
    return
  end
  local code = device:get_field("ir_test_code")

  if type(code) ~= "string" or #code == 0 then
    log.warn("IR: no learned code")
    return
  end

  local dps = {
    [product.ir_send] = json.encode({
      control = "send_ir",
      type = 0,
      head = "",
      key1 = "1" .. code
    })
  }

  log.info("IR: sending learned code")

  run_dps_control(device, dps)
end

-- Create a remote child device.
-- 리모컨 자식 기기 생성.
function M.create_remote(driver, device)
  local index = device:get_field("ir_remote_index") or 0
  local child_key

  repeat
    index = index + 1
    child_key = "remote-" .. tostring(index)
  until not device:get_child_by_parent_assigned_key(child_key)

  device:set_field("ir_remote_index", index, {
    persist = true
  })

  local ok, err = driver:try_create_device({
    type = "EDGE_CHILD",
    label = "IR Remote " .. tostring(index),
    profile = REMOTE_CHILD_PROFILE,
    manufacturer = "Tuya",
    parent_device_id = device.id,
    parent_assigned_child_key = child_key,
  })

  log.info(string.format(
    "%s: create remote %s -> %s %s",
    device.device_network_id,
    child_key,
    tostring(ok),
    tostring(err)
  ))
end

-- Initialize supported keypad keys.
-- 지원하는 키패드 버튼 초기화.
-- Initialize remote capabilities.
-- 리모컨 Capability 초기화.
function M.init_remote(device)
  -- Power / 전원
  device:emit_event(
    capabilities.switch.switch.on()
  )

  -- Volume / 볼륨
  device:emit_event(
    capabilities.audioVolume.volume(20)
  )

  -- Mute / 음소거
  device:emit_event(
    capabilities.audioMute.mute.unmuted()
  )

  -- Channel / 채널
  device:emit_event(
    capabilities.tvChannel.tvChannel("1")
  )

  -- Keypad / 키패드
  device:emit_event(
    capabilities.keypadInput.supportedKeyCodes({
      "UP", "DOWN", "LEFT", "RIGHT", "SELECT",
      "BACK", "EXIT", "MENU", "SETTINGS", "HOME"
    })
  )

  -- Playback / 재생 제어
  device:emit_event(
    capabilities.mediaPlayback.supportedPlaybackCommands({
      "play", "pause", "stop", "fastForward", "rewind"
    })
  )

  device:emit_event(
    capabilities.mediaPlayback.playbackStatus.paused()
  )

  -- Track control / 트랙 제어
  device:emit_event(
    capabilities.mediaTrackControl.supportedTrackControlCommands({
      "previousTrack", "nextTrack"
    })
  )

  -- Input source / 외부 입력
  device:emit_event(
    capabilities.mediaInputSource.supportedInputSources({
      "HDMI1", "HDMI2", "HDMI3", "HDMI4",
      "digitalTv", "USB", "bluetooth", "optical"
    })
  )

  device:emit_event(
    capabilities.mediaInputSource.inputSource("HDMI1")
  )
end

-- Log keypad commands for UI testing.
-- UI 테스트를 위해 키패드 명령을 로그에 기록.
function M.handle_keypad(device, command)
  log.info(string.format(
    "IR: %s keypad key = %s",
    device.label,
    tostring(command.args.keyCode)
  ))
end

return M