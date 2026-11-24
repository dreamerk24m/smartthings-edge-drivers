-- Shared SmartThings events / 공통 SmartThings 이벤트
local capabilities = require "st.capabilities"
local log = require "log"
-- Emit an event without letting an error (e.g. profile not switched yet) stop the driver.
-- 프로필이 아직 안 바뀐 경우 등의 오류로 드라이버가 멈추지 않게 이벤트를 보냄.

local function emit(device, event)
  local ok, err = pcall(device.emit_event, device, event)
  if not ok then log.warn(device.device_network_id .. ": could not emit event: " .. tostring(err)) end
end

-- Emit an event to one component of a device (e.g. "outlet1").
-- 기기의 특정 component(예: "outlet1")에 이벤트를 보냄.

local function emit_component(device, component_id, event)
  local component = device.profile.components[component_id]
  if not component then
    log.warn(device.device_network_id .. ": no component " .. component_id)
    return
  end
  local ok, err = pcall(device.emit_component_event, device, component, event)
  if not ok then log.warn(device.device_network_id .. ": could not emit event to " .. component_id .. ": " .. tostring(err)) end
end

local function switch_event(is_on)
  if is_on then return capabilities.switch.switch.on() end
  return capabilities.switch.switch.off()
end

return {
  emit = emit,
  emit_component = emit_component,
  switch_event = switch_event,
}
