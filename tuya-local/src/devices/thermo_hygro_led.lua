-- LED thermo-hygrometer / LED 온습도계
local capabilities = require "st.capabilities"
local log = require "log"
local ledTime = capabilities["travellaugh21607.ledTime"]
local thermo_hygro = require "devices.thermo_hygro"
local events = require "events"
local emit_component = events.emit_component
local switch_event = events.switch_event
-- Convert hour and minute to HH:MM
-- 시와 분을 HH:MM 형식으로 변환

local function format_time(hour, minute)
  if type(hour) ~= "number"
    or type(minute) ~= "number" then
    return nil
  end
  if hour < 0 or hour > 23
    or minute < 0 or minute > 59
    or hour % 1 ~= 0 or minute % 1 ~= 0 then
    return nil
  end
  return string.format("%02d:%02d", hour, minute)
end

-- Convert HH:MM to hour and minute
-- HH:MM 형식을 시와 분으로 변환

local function parse_time(value)
  if type(value) ~= "string" then return nil end
  local hour, minute = value:match("^(%d%d):(%d%d)$")
  hour = tonumber(hour)
  minute = tonumber(minute)
  if not hour or not minute then return nil end
  if hour > 23 or minute > 59 then return nil end
  return hour, minute
end

local function apply_led(device, product, dps)

  -- LED display state / LED 디스플레이 상태
  if product.display then
    local display = dps[product.display]
    if type(display) == "boolean" then
      emit_component(device, "display", switch_event(display))
      log.info(string.format("%s: display=%s",
          device.device_network_id, tostring(display)))
    end
  end

  -- LED schedule state / LED 시간 설정 상태
  if product.schedule then
    local schedule = dps[product.schedule]
    if type(schedule) == "boolean" then
      emit_component(device, "ledSchedule",
        switch_event(schedule))
    end
    local on_time = format_time(
      dps[product.hour_on],
      dps[product.minute_on]
    )
    local off_time = format_time(
      dps[product.hour_off],
      dps[product.minute_off]
    )
    if on_time then
      emit_component(device, "ledOnTime",
        ledTime.time(on_time))
    end
    if off_time then
      emit_component(device, "ledOffTime",
        ledTime.time(off_time))
    end
    log.info(string.format(
        "%s: schedule=%s on_time=%s off_time=%s",
        device.device_network_id,
        tostring(schedule),
        tostring(on_time),
        tostring(off_time)
    ))
  end
end

local function apply(device, product, dps)
  thermo_hygro.apply(device, product, dps, apply_led)
end

local function handle_switch(device, parent, product, command, is_on, run_control)
  if parent == device then
    local dp
    if command.component == "display" then
      dp = product.display
    elseif command.component == "ledSchedule" then
      dp = product.schedule
    end
    if dp then
      log.info(string.format("%s: %s -> %s",
          device.device_network_id,
          command.component,
          command.command))
      run_control(parent, { dp }, is_on, 1)
    end
  end
end

-- Set LED schedule time / LED 자동 켜기·끄기 시간 변경

local function handle_led_time(device, product, command, run_dps_control)
  if not product or not product.schedule then
    return
  end
  local value = (command.named_args or {}).time
    or (command.args or {}).time
    or (command.args or {})[1]
  local hour, minute = parse_time(value)
  if hour == nil or minute == nil then
    log.warn(device.device_network_id ..
      ": invalid LED time (use HH:MM)")
    return
  end
  local dps = {}
  if command.component == "ledOnTime" then
    dps[product.hour_on] = hour
    dps[product.minute_on] = minute
  elseif command.component == "ledOffTime" then
    dps[product.hour_off] = hour
    dps[product.minute_off] = minute
  else
    return
  end
  log.info(string.format("%s: %s -> %s",
      device.device_network_id,
      command.component,
      value))
  run_dps_control(device, dps, 1)
end

-- Device-side compensation / 기기 자체 온습도 보정

local function info_changed(device, product, p, old, run_dps_control)
  local dps = {}

  -- Temperature compensation / 온도 보정
  if product.temp_offset
    and type(p.tempOffset) == "number"
    and old.tempOffset ~= nil
    and old.tempOffset ~= p.tempOffset then
    local value = math.floor(p.tempOffset * 10 + 0.5)
    dps[product.temp_offset] = value
    log.info(string.format("%s: temperature offset=%s",
        device.device_network_id, tostring(p.tempOffset)))
  end

  -- Humidity compensation / 습도 보정
  if product.hum_offset
    and type(p.humOffset) == "number"
    and old.humOffset ~= nil
    and old.humOffset ~= p.humOffset then
    dps[product.hum_offset] = p.humOffset
    log.info(string.format("%s: humidity offset=%s",
        device.device_network_id, tostring(p.humOffset)))
  end
  if next(dps) then
    run_dps_control(device, dps, 1)
  end
end

return {
  apply = apply,
  handle_switch = handle_switch,
  handle_led_time = handle_led_time,
  info_changed = info_changed,
}
