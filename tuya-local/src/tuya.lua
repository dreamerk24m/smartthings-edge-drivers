-- Tuya local protocol 3.3: build a status query packet and parse the reply.
-- Tuya 로컬 프로토콜 3.3: 상태 조회 패킷 만들기, 응답 풀기.
--
-- Packet layout (all big-endian):
--   prefix(4) 0x000055AA | seq(4) | cmd(4) | length(4) | payload | crc32(4) | suffix(4) 0x0000AA55
--   length = len(payload) + 8. Replies carry a 4-byte return code at the start of the payload.

local aes = require "aes"

local tuya = {}

local CMD_DP_QUERY = 0x0A
local PREFIX = "\x00\x00\x55\xAA"
local SUFFIX = "\x00\x00\xAA\x55"
local HEADER_LEN = 16
local CMD_CONTROL = 0x07
local PROTOCOL_33_HEADER = "3.3" .. string.rep("\0", 12)

tuya.CMD_DP_QUERY = CMD_DP_QUERY
tuya.HEADER_LEN = HEADER_LEN
tuya.CMD_CONTROL = CMD_CONTROL

-- CRC32 (same polynomial as zlib).
local crc_table = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if (c & 1) ~= 0 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
  end
  crc_table[i] = c
end

local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = crc_table[(c ~ s:byte(i)) & 0xFF] ~ (c >> 8)
  end
  return (c ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

tuya.crc32 = crc32

-- Build a DP_QUERY (status request) packet.
-- `t` is a timestamp string (seconds); passed in so it can be fixed in tests.
function tuya.build_status_query(dev_id, local_key, seq, t)
  local json = string.format('{"gwId":"%s","devId":"%s","uid":"%s","t":"%s"}', dev_id, dev_id, dev_id, t)
  local payload = aes.encrypt_ecb(aes.pad(json), local_key)
  local head = PREFIX .. string.pack(">I4I4I4", seq, CMD_DP_QUERY, #payload + 8) .. payload
  return head .. string.pack(">I4", crc32(head)) .. SUFFIX
end

-- Build a CONTROL (set datapoints) packet. `dps` is a table such as { ["1"] = true }.
-- In protocol 3.3 the encrypted payload of a control command is prefixed with a version header.
-- DP를 바꾸는 제어 패킷을 만듦. 3.3에서는 암호화한 데이터 앞에 버전 헤더가 붙음.
function tuya.build_control(dev_id, local_key, seq, t, dps)
  local parts = {}
  for k, v in pairs(dps) do
    parts[#parts + 1] = string.format('"%s":%s', k, tostring(v))
  end
  table.sort(parts)
  local json = string.format('{"devId":"%s","uid":"%s","t":"%s","dps":{%s}}',
    dev_id, dev_id, t, table.concat(parts, ","))
  local payload = PROTOCOL_33_HEADER .. aes.encrypt_ecb(aes.pad(json), local_key)
  local head = PREFIX .. string.pack(">I4I4I4", seq, CMD_CONTROL, #payload + 8) .. payload
  return head .. string.pack(">I4", crc32(head)) .. SUFFIX
end

-- Total size of the first packet in `buf`, or nil if the header is not complete yet.
function tuya.packet_size(buf)
  if #buf < HEADER_LEN then return nil end
  if buf:sub(1, 4) ~= PREFIX then return nil, "bad prefix" end
  local length = string.unpack(">I4", buf, 13)
  return HEADER_LEN + length
end

-- Parse one complete packet. Returns cmd, retcode, decrypted-json-string  (or nil, error).
function tuya.parse(packet, local_key)
  local size, err = tuya.packet_size(packet)
  if not size then return nil, err or "incomplete header" end
  if #packet < size then return nil, "incomplete packet" end
  if packet:sub(size - 3, size) ~= SUFFIX then return nil, "bad suffix" end

  local crc_got = string.unpack(">I4", packet, size - 7)
  if crc32(packet:sub(1, size - 8)) ~= crc_got then return nil, "bad crc" end

  local cmd = string.unpack(">I4", packet, 9)
  local retcode = string.unpack(">I4", packet, 17)
  local enc = packet:sub(21, size - 8)
  if #enc == 0 then return cmd, retcode, "" end
  if #enc % 16 ~= 0 then return nil, "bad payload length" end

  local plain, perr = aes.unpad(aes.decrypt_ecb(enc, local_key))
  if not plain then return nil, perr end
  return cmd, retcode, plain
end

return tuya