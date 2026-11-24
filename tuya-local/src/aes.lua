-- Minimal AES-128 (ECB, PKCS7) in pure Lua 5.3.
-- SmartThings Edge has no native crypto, so this is implemented by hand.
-- 최소 AES-128(ECB, PKCS7) 순수 Lua 5.3 구현. 스마트싱스 Edge에는 기본 암호화가 없어서 직접 구현함.

local aes = {}

-- S-box generation (so no large tables to mistype).
local sbox, inv_sbox = {}, {}
do
  local function rotl8(x, s) return ((x << s) | (x >> (8 - s))) & 0xFF end
  local p, q = 1, 1
  repeat
    -- p = p * 3 in GF(2^8)
    p = (p ~ ((p << 1) & 0xFF) ~ (((p & 0x80) ~= 0) and 0x1B or 0)) & 0xFF
    -- q = q / 3 in GF(2^8)
    q = q ~ (q << 1)
    q = q ~ (q << 2)
    q = q ~ (q << 4)
    q = q & 0xFF
    if (q & 0x80) ~= 0 then q = q ~ 0x09 end
    local x = q ~ rotl8(q, 1) ~ rotl8(q, 2) ~ rotl8(q, 3) ~ rotl8(q, 4)
    sbox[p] = (x ~ 0x63) & 0xFF
  until p == 1
  sbox[0] = 0x63
  for i = 0, 255 do inv_sbox[sbox[i]] = i end
end

local function xtime(a)
  a = a << 1
  if (a & 0x100) ~= 0 then a = a ~ 0x11B end
  return a & 0xFF
end

local function gmul(a, b)
  local r = 0
  while b > 0 do
    if (b & 1) ~= 0 then r = r ~ a end
    a = xtime(a)
    b = b >> 1
  end
  return r
end

-- Precomputed multiplication tables for (Inv)MixColumns.
local mul2, mul3, mul9, mul11, mul13, mul14 = {}, {}, {}, {}, {}, {}
for i = 0, 255 do
  mul2[i] = gmul(i, 2); mul3[i] = gmul(i, 3)
  mul9[i] = gmul(i, 9); mul11[i] = gmul(i, 11)
  mul13[i] = gmul(i, 13); mul14[i] = gmul(i, 14)
end

-- Expand a 16-byte key string into 11 round keys (each a table of 16 bytes).
local function expand_key(key)
  assert(#key == 16, "AES-128 key must be 16 bytes")
  local w = {}
  for i = 0, 15 do w[i] = key:byte(i + 1) end
  local rcon = 1
  for i = 16, 175, 4 do
    local t0, t1, t2, t3 = w[i - 4], w[i - 3], w[i - 2], w[i - 1]
    if i % 16 == 0 then
      t0, t1, t2, t3 = sbox[t1] ~ rcon, sbox[t2], sbox[t3], sbox[t0]
      rcon = xtime(rcon)
    end
    w[i] = w[i - 16] ~ t0
    w[i + 1] = w[i - 15] ~ t1
    w[i + 2] = w[i - 14] ~ t2
    w[i + 3] = w[i - 13] ~ t3
  end
  local rk = {}
  for r = 0, 10 do
    local k = {}
    for j = 0, 15 do k[j] = w[r * 16 + j] end
    rk[r] = k
  end
  return rk
end

local function add_round_key(s, k)
  for i = 0, 15 do s[i] = s[i] ~ k[i] end
end

local function encrypt_block(s, rk)
  add_round_key(s, rk[0])
  for round = 1, 10 do
    for i = 0, 15 do s[i] = sbox[s[i]] end
    -- ShiftRows (state is column-major: index = col*4 + row)
    s[1], s[5], s[9], s[13] = s[5], s[9], s[13], s[1]
    s[2], s[6], s[10], s[14] = s[10], s[14], s[2], s[6]
    s[3], s[7], s[11], s[15] = s[15], s[3], s[7], s[11]
    if round < 10 then
      for c = 0, 3 do
        local a0, a1, a2, a3 = s[c * 4], s[c * 4 + 1], s[c * 4 + 2], s[c * 4 + 3]
        s[c * 4]     = mul2[a0] ~ mul3[a1] ~ a2 ~ a3
        s[c * 4 + 1] = a0 ~ mul2[a1] ~ mul3[a2] ~ a3
        s[c * 4 + 2] = a0 ~ a1 ~ mul2[a2] ~ mul3[a3]
        s[c * 4 + 3] = mul3[a0] ~ a1 ~ a2 ~ mul2[a3]
      end
    end
    add_round_key(s, rk[round])
  end
end

local function decrypt_block(s, rk)
  add_round_key(s, rk[10])
  for round = 9, 0, -1 do
    -- InvShiftRows
    s[1], s[5], s[9], s[13] = s[13], s[1], s[5], s[9]
    s[2], s[6], s[10], s[14] = s[10], s[14], s[2], s[6]
    s[3], s[7], s[11], s[15] = s[7], s[11], s[15], s[3]
    for i = 0, 15 do s[i] = inv_sbox[s[i]] end
    add_round_key(s, rk[round])
    if round > 0 then
      for c = 0, 3 do
        local a0, a1, a2, a3 = s[c * 4], s[c * 4 + 1], s[c * 4 + 2], s[c * 4 + 3]
        s[c * 4]     = mul14[a0] ~ mul11[a1] ~ mul13[a2] ~ mul9[a3]
        s[c * 4 + 1] = mul9[a0] ~ mul14[a1] ~ mul11[a2] ~ mul13[a3]
        s[c * 4 + 2] = mul13[a0] ~ mul9[a1] ~ mul14[a2] ~ mul11[a3]
        s[c * 4 + 3] = mul11[a0] ~ mul13[a1] ~ mul9[a2] ~ mul14[a3]
      end
    end
  end
end

local function process(data, key, block_fn)
  local rk = expand_key(key)
  local out = {}
  for pos = 1, #data, 16 do
    local s = {}
    for i = 0, 15 do s[i] = data:byte(pos + i) end
    block_fn(s, rk)
    local chars = {}
    for i = 0, 15 do chars[i + 1] = string.char(s[i]) end
    out[#out + 1] = table.concat(chars)
  end
  return table.concat(out)
end

-- Raw ECB (data length must be a multiple of 16).
function aes.encrypt_ecb(data, key) return process(data, key, encrypt_block) end
function aes.decrypt_ecb(data, key) return process(data, key, decrypt_block) end

-- PKCS7 padding helpers.
function aes.pad(data)
  local n = 16 - (#data % 16)
  return data .. string.rep(string.char(n), n)
end

function aes.unpad(data)
  local n = data:byte(#data)
  if not n or n < 1 or n > 16 or n > #data then return nil, "bad padding" end
  return data:sub(1, #data - n)
end

return aes