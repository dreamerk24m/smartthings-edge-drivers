-- Run from the repository root with Lua 5.3: lua tests/tuya-local.lua
package.path = "tuya-local/src/?.lua;" .. package.path

local function noop() end

package.loaded.log = { info = noop, warn = noop, debug = noop }
package.loaded["st.capabilities"] = {}
package.loaded.events = {}
package.loaded["st.json"] = {}

local power_strip = require "devices.power_strip"

local function test_missing_outlet()
  local children = {}
  local failed_once = false
  local attempts = {}
  local device = {
    get_field = function(_, key) return key == "children_created" and failed_once end,
    set_field = noop,
    get_child_by_parent_assigned_key = function(_, key) return children[key] end,
  }
  local driver = {
    try_create_device = function(_, request)
      local key = request.parent_assigned_child_key
      attempts[#attempts + 1] = key
      if key == "2" and not failed_once then
        failed_once = true
        return nil, "creation failed"
      end
      assert(not children[key], "requested an existing outlet")
      children[key] = true
      return true
    end,
  }

  local product = { outlets = { "1", "2", "3", "4" } }
  power_strip.create_children(driver, device, product)
  power_strip.create_children(driver, device, product)
  assert(table.concat(attempts) == "12342", "only the missing outlet should be retried")
end

local wire, readable = "", 0
local tcp = { settimeout = noop, connect = function() return true end, close = noop }
function tcp:receive(count)
  local length = math.min(readable, count)
  local bytes = wire:sub(1, length)
  wire = wire:sub(length + 1)
  readable = readable - length
  if length < count then return nil, "timeout", bytes end
  return bytes
end
package.loaded.cosock = { socket = { tcp = function() return tcp end } }

local tuya = require "tuya"
local transport = require "transport"

local function test_fragmented_receive()
  local receive
  local device = {
    device_network_id = "test",
    preferences = { deviceIp = "192.0.2.1", localKey = string.rep("a", 16) },
    thread = {
      register_socket = function(_, _, handler) receive = handler end,
      unregister_socket = noop,
      cancel_timer = noop,
      call_on_schedule = function() return {} end,
    },
  }

  local packets = {}
  local session = assert(transport.open_session(device, function(_, cmd, retcode, plain)
    assert(cmd == tuya.CMD_STATUS and retcode == 0)
    packets[#packets + 1] = plain
  end))
  local key = device.preferences.localKey
  local first = '{"dps":{"1":true}}'
  local second = '{"dps":{"1":false}}'
  local aes = require "aes"
  local function frame(payload)
    local encrypted = aes.encrypt_ecb(aes.pad(payload), key)
    local body = string.pack(">I4", 0) .. encrypted
    local head = string.pack(">I4I4I4I4", 0x55aa, 1, tuya.CMD_STATUS, #body + 8) .. body
    local crc = 0xffffffff
    for i = 1, #head do
      crc = crc ~ head:byte(i)
      for _ = 1, 8 do
        crc = (crc >> 1) ~ (crc & 1 == 1 and 0xedb88320 or 0)
      end
    end
    return head .. string.pack(">I4I4", crc ~ 0xffffffff, 0xaa55)
  end

  wire = frame(first) .. frame(second)
  readable = 5
  receive()
  assert(#packets == 0)
  readable = tuya.HEADER_LEN - 5 + 2
  receive()
  assert(#packets == 0)
  readable = #wire
  receive()
  assert(#packets == 2 and packets[1] == first and packets[2] == second)
  assert(not session.closed)
end

local failed = false
for name, run in pairs({
  ["retry only the missing outlet, including devices with the old flag"] = test_missing_outlet,
  ["read fragmented and consecutive status packets in order"] = test_fragmented_receive,
}) do
  local ok, err = pcall(run)
  print((ok and "PASS " or "FAIL ") .. name)
  if not ok then
    print(err)
    failed = true
  end
end
assert(not failed)
