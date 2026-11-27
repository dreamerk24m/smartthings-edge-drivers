-- Shared temperature and humidity measurements / 공통 온습도 측정
local capabilities = require "st.capabilities"
local log = require "log"
local emit = require("events").emit

local function apply_thermo_hygro(device, product, dps, apply_extra)
  local temp, hum = dps[product.temperature], dps[product.humidity]
  local values = {}

  -- Force state changes for temperature and humidity reporting.
  -- 온습도 보고 시 상태 변화를 강제로 지정함.
  local metadata = { state_change = true }

  if type(temp) == "number" then
    emit(device, capabilities.temperatureMeasurement.temperature({
      value = temp / 10,
      unit = "C"
    }, metadata))
    values[#values + 1] = "temperature=" .. tostring(temp / 10)
  end

  if type(hum) == "number" then
    emit(device, capabilities.relativeHumidityMeasurement.humidity(
      hum, metadata
    ))
    values[#values + 1] = "humidity=" .. tostring(hum)
  end

  if apply_extra then
    apply_extra(device, product, dps)
  end

  if #values > 0 then
    log.info(device.device_network_id .. ": " ..
      table.concat(values, " "))
  end
end

return { apply = apply_thermo_hygro }