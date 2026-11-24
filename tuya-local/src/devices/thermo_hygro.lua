-- Shared temperature and humidity measurements / 공통 온습도 측정
local capabilities = require "st.capabilities"
local log = require "log"
local emit = require("events").emit

local function apply_thermo_hygro(device, product, dps, apply_extra)
  local temp, hum = dps[product.temperature], dps[product.humidity]
  if type(temp) == "number" then
    emit(device, capabilities.temperatureMeasurement.temperature({
          value = temp / 10,
          unit = "C"
    }))
  end
  if type(hum) == "number" then
    emit(device, capabilities.relativeHumidityMeasurement.humidity(hum))
  end
  if apply_extra then
    apply_extra(device, product, dps)
  end
  log.info(string.format("%s: temperature=%s humidity=%s",
      device.device_network_id,
      tostring(type(temp) == "number" and temp / 10 or nil),
      tostring(hum)))
end

return { apply = apply_thermo_hygro }
