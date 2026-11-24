-- Power strip / 멀티탭
local capabilities = require "st.capabilities"
local log = require "log"
local events = require "events"
local emit = events.emit
local emit_component = events.emit_component
local switch_event = events.switch_event
local OUTLET_PROFILE = "tuya-power-strip-outlet"
-- Outlet states go to the child devices and to the outlet components of this device.
-- The main switch is on when at least one outlet is on. Power is DP value / power_scale (W).
-- 콘센트 상태는 자식 기기와 이 기기의 outlet component에 보냄. 메인 스위치는 하나라도 켜져 있으면 on.

local function apply_power_strip(device, product, dps)
  local seen, any_on = false, false
  for i, dp in ipairs(product.outlets) do
    local value = dps[dp]
    if type(value) == "boolean" then
      seen = true
      if value then any_on = true end
      local child = device:get_child_by_parent_assigned_key(dp)
      if child then emit(child, switch_event(value)) end
      emit_component(device, "outlet" .. i, switch_event(value))
    end
  end
  if seen then emit(device, switch_event(any_on)) end
  local power = dps[product.power]
  if type(power) == "number" then
    emit(device, capabilities.powerMeter.power({ value = power / product.power_scale, unit = "W" }))
  end
  log.info(string.format("%s: any_on=%s power=%s",
      device.device_network_id, tostring(seen and any_on or nil),
      tostring(type(power) == "number" and power / product.power_scale or nil)))
end

-- Create one child device per outlet, only once. The child key is the DP number ("1".."4").
-- 콘센트마다 자식 기기를 한 번만 만듦. 자식 키는 DP 번호("1"~"4").

local function create_children(driver, device, product)
  if device:get_field("children_created") then return end
  device:set_field("children_created", true, { persist = true })
  for i, dp in ipairs(product.outlets) do
    if not device:get_child_by_parent_assigned_key(dp) then
      local ok, err = driver:try_create_device({
          type = "EDGE_CHILD",
          label = "콘센트 " .. i,
          profile = OUTLET_PROFILE,
          manufacturer = "Tuya",
          parent_device_id = device.id,
          parent_assigned_child_key = dp,
      })
      log.info(string.format("%s: create child %s -> %s %s",
          device.device_network_id, dp, tostring(ok), tostring(err)))
    end
  end
end

-- Switch commands from the parent or outlet children / 메인 및 자식 기기의 스위치 명령

local function handle_switch(device, parent, product, command, is_on, run_control)
  local targets = {}
  if parent == device then
    if command.component == "main" then
      for _, dp in ipairs(product.outlets) do targets[#targets + 1] = dp end
    else
      local index = tonumber(string.match(command.component, "^outlet(%d+)$"))
      if index and product.outlets[index] then targets[1] = product.outlets[index] end
    end
  else
    for _, dp in ipairs(product.outlets) do
      local child = parent:get_child_by_parent_assigned_key(dp)
      if child and child.id == device.id then targets[1] = dp end
    end
  end
  if #targets == 0 then
    log.warn(device.device_network_id .. ": no target for " .. tostring(command.component))
    return
  end
  log.info(string.format("%s: %s -> %s", device.device_network_id, table.concat(targets, ","), command.command))
  run_control(parent, targets, is_on, 1)
end

return {
  apply = apply_power_strip,
  create_children = create_children,
  handle_switch = handle_switch,
}
