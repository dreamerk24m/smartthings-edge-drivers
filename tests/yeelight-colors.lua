-- Run from the repository root with Lua 5.3: lua tests/yeelight-colors.lua
local function noop() end
local template
package.loaded["st.driver"] = function(_, driver_template)
  template = driver_template
  return { run = noop, get_devices = function() return {} end }
end
package.loaded.log = { info = noop, warn = noop, debug = noop, error = noop }
package.loaded["cosock.socket"] = {}
local sent = {}
package.loaded["st.json"] = {
  encode = function(request)
    sent[#sent + 1] = request
    return request.method
  end,
}

local function attribute(name)
  return setmetatable({ NAME = name }, {
    __call = function(_, value) return { name = name, value = value } end,
  })
end
local function capability(id, commands, attrs)
  local cap = { ID = id, commands = {} }
  for _, cmd in ipairs(commands) do cap.commands[cmd] = { NAME = cmd } end
  for _, attr in ipairs(attrs) do cap[attr] = attribute(attr) end
  return cap
end
local caps = {
  switch = capability("switch", { "on", "off" }, { "switch" }),
  switchLevel = capability("switchLevel", { "setLevel" }, { "level" }),
  colorTemperature = capability("colorTemperature", { "setColorTemperature" }, { "colorTemperature" }),
  colorControl = capability("colorControl", { "setColor", "setHue", "setSaturation" }, { "hue", "saturation" }),
  refresh = capability("refresh", { "refresh" }, {}),
}
caps.switch.switch.on = function() return caps.switch.switch("on") end
caps.switch.switch.off = function() return caps.switch.switch("off") end
package.loaded["st.capabilities"] = caps
dofile(arg[1] or "yeelight-lan/src/init.lua")

local socket = { send = function() return true end }
local function light(model)
  sent = {}
  local components = { main = "main", background = "background" }
  if model == "ceilb" then components.moonlight = "moonlight" end
  local fields, states, timers = { sock = socket }, {}, {}
  return {
    label = model, model = model, profile = { components = components }, timers = timers,
    get_field = function(_, key) return fields[key] end,
    set_field = function(_, key, value) fields[key] = value end,
    get_latest_state = function(_, component, _, attr) return states[component .. "." .. attr] end,
    emit_component_event = function(_, component, event) states[component .. "." .. event.name] = event.value end,
    supports_capability_by_id = function() return false end,
    thread = {
      call_with_delay = function(_, delay, fn)
        timers[delay] = fn
        return fn
      end,
    },
  }
end
local function command(device, component, cap, name, args)
  template.capability_handlers[cap][name](nil, device, { component = component, args = args or {} })
end
local function temperature(device, component, kelvin)
  command(device, component, "colorTemperature", "setColorTemperature", { temperature = kelvin })
end
local function refresh(device, props)
  command(device, "main", "refresh", "refresh")
  local request = sent[#sent]
  assert(request.method == "get_prop")
  local result = {}
  for i, name in ipairs(request.params) do result[i] = props[name] or "" end
  device:get_field("requests")[request.id].on_result(result)
end

local function assert_read_only_since(count)
  for i = count + 1, #sent do
    assert(sent[i].method == "get_prop", "unexpected command: " .. sent[i].method)
  end
end

local failed = 0
local function test(name, run)
  local ok, err = pcall(run)
  if not ok then failed = failed + 1 end
  print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or " — " .. tostring(err)))
end

test("on sent without confirmation holds main color temperature", function()
  local device = light("lamp15")
  command(device, "main", "switch", "on")
  local count = #sent
  temperature(device, "main", 3500)
  assert_read_only_since(count)
end)

test("failed power-on holds subsequent background color", function()
  local device = light("lamp15")
  device:set_field("sock", nil)
  command(device, "background", "switch", "on")
  device:set_field("sock", socket)
  command(device, "background", "colorControl", "setColor", { color = { hue = 25, saturation = 55 } })
  assert_read_only_since(0)
end)

test("unconfirmed ceiling on remains safe after mode-settling timeout", function()
  local device = light("ceilb")
  command(device, "main", "switch", "on")
  temperature(device, "main", 3600)
  local count = #sent
  if device.timers[1.5] then device.timers[1.5]() end
  assert_read_only_since(count)
end)

test("refresh preserves latest queued color and updates brightness", function()
  local device = light("lamp15")
  temperature(device, "main", 3200)
  temperature(device, "main", 3600)
  command(device, "background", "colorControl", "setColor", { color = { hue = 20, saturation = 55 } })
  refresh(device, { power = "off", main_power = "off", bg_power = "off", ct = "2700",
    bg_hue = "300", bg_sat = "1", bright = "45" })
  assert_read_only_since(0)
  assert(device:get_latest_state("main", nil, "colorTemperature") == 3600, "refresh overwrote queued CT")
  assert(device:get_latest_state("background", nil, "hue") == 20, "refresh overwrote queued hue")
  assert(device:get_latest_state("background", nil, "saturation") == 55, "refresh overwrote queued saturation")
  assert(device:get_latest_state("main", nil, "level") == 45)
end)

test("positive brightness uses the reservation after a failed turn-on", function()
  local device = light("lamp15")
  temperature(device, "main", 3200)
  device:set_field("sock", nil)
  command(device, "main", "switch", "on")
  device:set_field("sock", socket)
  command(device, "main", "switchLevel", "setLevel", { level = 35 })
  local last = sent[#sent]
  assert(last and last.method == "set_scene" and last.params[2] == 3200 and last.params[3] == 35,
    "brightness did not turn on with the reserved CT")
end)

test("an older scene response preserves a newer reservation", function()
  local device = light("lamp15")
  temperature(device, "main", 3200)
  command(device, "main", "switch", "on")
  local scene = sent[#sent]
  assert(scene.method == "set_scene")
  temperature(device, "main", 4500)
  local request = device:get_field("requests")[scene.id]
  if request.on_result then request.on_result({ "ok" }) end
  command(device, "main", "switch", "on")
  local last = sent[#sent]
  assert(last.method == "set_scene" and last.params[2] == 4500, "newer CT lost after old response")
end)

test("confirmed on accepts a direct color-temperature command", function()
  local device = light("lamp15")
  refresh(device, { power = "on", main_power = "on", bg_power = "off" })
  temperature(device, "main", 4100)
  local last = sent[#sent]
  assert(last.method == "set_ct_abx" and last.params[1] == 4100)
end)

test("queued background HSV is sent once power verification confirms on", function()
  local device = light("lamp15")
  command(device, "background", "switch", "on")
  command(device, "background", "colorControl", "setColor", { color = { hue = 30, saturation = 75 } })
  device.timers[0.5]()
  local read = sent[#sent]
  assert(read.method == "get_prop")
  device:get_field("requests")[read.id].on_result({ "on", "off", "on" })
  local write = sent[#sent]
  assert(write.method == "bg_set_hsv" and write.params[1] == 108 and write.params[2] == 75)
end)

test("ceiling mode verification keeps CT reserved in moonlight", function()
  local device = light("ceilb")
  temperature(device, "main", 3400)
  command(device, "main", "switch", "on")
  local count = #sent
  device.timers[1.5]()
  local read = sent[#sent]
  assert(read.method == "get_prop")
  device:get_field("requests")[read.id].on_result({ "on", "on", "1" })
  assert_read_only_since(count)
end)

test("a ceiling off command supersedes the previous on timeout", function()
  local device = light("ceilb")
  temperature(device, "main", 3400)
  command(device, "main", "switch", "on")
  local previous_timeout = assert(device.timers[1.5])
  command(device, "main", "switch", "off")
  local count = #sent
  previous_timeout()
  assert(#sent == count, "stale on timeout sent a command after off")
end)

assert(failed == 0, failed .. " regression test(s) failed")
