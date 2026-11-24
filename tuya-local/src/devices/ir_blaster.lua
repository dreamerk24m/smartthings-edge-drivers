-- Tuya IR blaster / Tuya IR 블래스터
local log = require "log"
local transport = require "transport"
local thermo_hygro = require "devices.thermo_hygro"
local json = require "st.json"

local M = {}

-- Reuse temperature and humidity measurement.
-- 기존 온습도 측정 기능 재사용.
M.apply = thermo_hygro.apply

-- Learn an IR code.
-- IR 신호 학습.
function M.learn(device, product)
  if device:get_field("polling") then
    log.warn("IR: device is busy")
    return
  end

  local p = device.preferences

  device:set_field("polling", true)

  log.info("IR: learning started")

  local ok, code, err = pcall(
    transport.learn_ir,
    p.deviceIp,
    p.deviceId,
    p.localKey,
    product.ir_send,
    product.ir_learn,
    30
  )

  device:set_field("polling", false)

  if not ok then
    log.warn("IR: learning error: " .. tostring(code))
    return
  end

  if not code then
    log.warn("IR: learning failed: " .. tostring(err))
    return
  end

  device:set_field("ir_test_code", code)

  log.info("IR: learning successful")
  log.info("IR: learned code: " .. code)
end

-- Send a learned IR code.
-- 학습한 IR 신호 전송.
function M.send(device, product, run_dps_control)
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

  run_dps_control(device, dps, 1)
end

return M