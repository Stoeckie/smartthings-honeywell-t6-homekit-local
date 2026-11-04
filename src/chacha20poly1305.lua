-- ChaCha20-Poly1305 AEAD (RFC 8439) in pure Lua 5.3 (64-bit integers).
local M = {}

local spack, sunpack, srep, ssub, sbyte = string.pack, string.unpack, string.rep, string.sub, string.byte
local concat = table.concat
local M32 = 0xffffffff
local M26 = 0x3ffffff

---------------------------------------------------------------------------
-- ChaCha20
---------------------------------------------------------------------------

-- 20 rounds on 16 locals; returns the 16 output words (state + working state) mod 2^32.
local function rounds(s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15)
  local x0, x1, x2, x3, x4, x5, x6, x7 = s0, s1, s2, s3, s4, s5, s6, s7
  local x8, x9, x10, x11, x12, x13, x14, x15 = s8, s9, s10, s11, s12, s13, s14, s15
  for _ = 1, 10 do
    -- column rounds
    x0 = (x0 + x4) & M32; x12 = x12 ~ x0; x12 = ((x12 << 16) | (x12 >> 16)) & M32
    x8 = (x8 + x12) & M32; x4 = x4 ~ x8; x4 = ((x4 << 12) | (x4 >> 20)) & M32
    x0 = (x0 + x4) & M32; x12 = x12 ~ x0; x12 = ((x12 << 8) | (x12 >> 24)) & M32
    x8 = (x8 + x12) & M32; x4 = x4 ~ x8; x4 = ((x4 << 7) | (x4 >> 25)) & M32

    x1 = (x1 + x5) & M32; x13 = x13 ~ x1; x13 = ((x13 << 16) | (x13 >> 16)) & M32
    x9 = (x9 + x13) & M32; x5 = x5 ~ x9; x5 = ((x5 << 12) | (x5 >> 20)) & M32
    x1 = (x1 + x5) & M32; x13 = x13 ~ x1; x13 = ((x13 << 8) | (x13 >> 24)) & M32
    x9 = (x9 + x13) & M32; x5 = x5 ~ x9; x5 = ((x5 << 7) | (x5 >> 25)) & M32

    x2 = (x2 + x6) & M32; x14 = x14 ~ x2; x14 = ((x14 << 16) | (x14 >> 16)) & M32
    x10 = (x10 + x14) & M32; x6 = x6 ~ x10; x6 = ((x6 << 12) | (x6 >> 20)) & M32
    x2 = (x2 + x6) & M32; x14 = x14 ~ x2; x14 = ((x14 << 8) | (x14 >> 24)) & M32
    x10 = (x10 + x14) & M32; x6 = x6 ~ x10; x6 = ((x6 << 7) | (x6 >> 25)) & M32

    x3 = (x3 + x7) & M32; x15 = x15 ~ x3; x15 = ((x15 << 16) | (x15 >> 16)) & M32
    x11 = (x11 + x15) & M32; x7 = x7 ~ x11; x7 = ((x7 << 12) | (x7 >> 20)) & M32
    x3 = (x3 + x7) & M32; x15 = x15 ~ x3; x15 = ((x15 << 8) | (x15 >> 24)) & M32
    x11 = (x11 + x15) & M32; x7 = x7 ~ x11; x7 = ((x7 << 7) | (x7 >> 25)) & M32

    -- diagonal rounds
    x0 = (x0 + x5) & M32; x15 = x15 ~ x0; x15 = ((x15 << 16) | (x15 >> 16)) & M32
    x10 = (x10 + x15) & M32; x5 = x5 ~ x10; x5 = ((x5 << 12) | (x5 >> 20)) & M32
    x0 = (x0 + x5) & M32; x15 = x15 ~ x0; x15 = ((x15 << 8) | (x15 >> 24)) & M32
    x10 = (x10 + x15) & M32; x5 = x5 ~ x10; x5 = ((x5 << 7) | (x5 >> 25)) & M32

    x1 = (x1 + x6) & M32; x12 = x12 ~ x1; x12 = ((x12 << 16) | (x12 >> 16)) & M32
    x11 = (x11 + x12) & M32; x6 = x6 ~ x11; x6 = ((x6 << 12) | (x6 >> 20)) & M32
    x1 = (x1 + x6) & M32; x12 = x12 ~ x1; x12 = ((x12 << 8) | (x12 >> 24)) & M32
    x11 = (x11 + x12) & M32; x6 = x6 ~ x11; x6 = ((x6 << 7) | (x6 >> 25)) & M32

    x2 = (x2 + x7) & M32; x13 = x13 ~ x2; x13 = ((x13 << 16) | (x13 >> 16)) & M32
    x8 = (x8 + x13) & M32; x7 = x7 ~ x8; x7 = ((x7 << 12) | (x7 >> 20)) & M32
    x2 = (x2 + x7) & M32; x13 = x13 ~ x2; x13 = ((x13 << 8) | (x13 >> 24)) & M32
    x8 = (x8 + x13) & M32; x7 = x7 ~ x8; x7 = ((x7 << 7) | (x7 >> 25)) & M32

    x3 = (x3 + x4) & M32; x14 = x14 ~ x3; x14 = ((x14 << 16) | (x14 >> 16)) & M32
    x9 = (x9 + x14) & M32; x4 = x4 ~ x9; x4 = ((x4 << 12) | (x4 >> 20)) & M32
    x3 = (x3 + x4) & M32; x14 = x14 ~ x3; x14 = ((x14 << 8) | (x14 >> 24)) & M32
    x9 = (x9 + x14) & M32; x4 = x4 ~ x9; x4 = ((x4 << 7) | (x4 >> 25)) & M32
  end
  return (x0 + s0) & M32, (x1 + s1) & M32, (x2 + s2) & M32, (x3 + s3) & M32,
         (x4 + s4) & M32, (x5 + s5) & M32, (x6 + s6) & M32, (x7 + s7) & M32,
         (x8 + s8) & M32, (x9 + s9) & M32, (x10 + s10) & M32, (x11 + s11) & M32,
         (x12 + s12) & M32, (x13 + s13) & M32, (x14 + s14) & M32, (x15 + s15) & M32
end

local W16 = "<" .. srep("I4", 16)
local W12 = "<" .. srep("I4", 12)

-- Initial state words from key/nonce (constants, 8 key words, counter, 3 nonce words).
local function init_state(key, nonce)
  assert(#key == 32, "key must be 32 bytes")
  assert(#nonce == 12, "nonce must be 12 bytes")
  local k = { sunpack("<I4I4I4I4I4I4I4I4", key) }
  local n1, n2, n3 = sunpack("<I4I4I4", nonce)
  return 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
         k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8], n1, n2, n3
end

-- One 64-byte keystream block.
function M.chacha20_block(key, nonce, counter)
  local c0, c1, c2, c3, k0, k1, k2, k3, k4, k5, k6, k7, n1, n2, n3 = init_state(key, nonce)
  return spack(W16, rounds(c0, c1, c2, c3, k0, k1, k2, k3, k4, k5, k6, k7, counter & M32, n1, n2, n3))
end

-- XOR data with the ChaCha20 keystream starting at block `counter`.
function M.chacha20(key, nonce, counter, data)
  local c0, c1, c2, c3, k0, k1, k2, k3, k4, k5, k6, k7, n1, n2, n3 = init_state(key, nonce)
  local out, n = {}, 0
  local len = #data
  local pos = 1
  while len - pos + 1 >= 64 do
    local y0, y1, y2, y3, y4, y5, y6, y7, y8, y9, y10, y11, y12, y13, y14, y15 =
      rounds(c0, c1, c2, c3, k0, k1, k2, k3, k4, k5, k6, k7, counter & M32, n1, n2, n3)
    local p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15 = sunpack(W16, data, pos)
    n = n + 1
    out[n] = spack(W16, y0 ~ p0, y1 ~ p1, y2 ~ p2, y3 ~ p3, y4 ~ p4, y5 ~ p5, y6 ~ p6, y7 ~ p7,
                        y8 ~ p8, y9 ~ p9, y10 ~ p10, y11 ~ p11, y12 ~ p12, y13 ~ p13, y14 ~ p14, y15 ~ p15)
    pos = pos + 64
    counter = counter + 1
  end
  if pos <= len then
    local ks = spack(W16, rounds(c0, c1, c2, c3, k0, k1, k2, k3, k4, k5, k6, k7, counter & M32, n1, n2, n3))
    local tail = {}
    for i = pos, len do
      tail[#tail + 1] = string.char(sbyte(data, i) ~ sbyte(ks, i - pos + 1))
    end
    n = n + 1
    out[n] = concat(tail)
  end
  return concat(out)
end

---------------------------------------------------------------------------
-- Poly1305 (5 x 26-bit limbs, donna style)
---------------------------------------------------------------------------

function M.poly1305(key, msg)
  assert(#key == 32, "poly1305 key must be 32 bytes")
  local t0, t1, s0, s1 = sunpack("<I8I8I8I8", key)
  -- clamp r
  t0 = t0 & 0x0ffffffc0fffffff
  t1 = t1 & 0x0ffffffc0ffffffc
  local r0 = t0 & M26
  local r1 = (t0 >> 26) & M26
  local r2 = ((t0 >> 52) | (t1 << 12)) & M26
  local r3 = (t1 >> 14) & M26
  local r4 = (t1 >> 40) & M26
  local q1, q2, q3, q4 = r1 * 5, r2 * 5, r3 * 5, r4 * 5

  local h0, h1, h2, h3, h4 = 0, 0, 0, 0, 0
  local len = #msg
  local pos = 1
  local m0, m1, hibit

  local function absorb()
    h0 = h0 + (m0 & M26)
    h1 = h1 + ((m0 >> 26) & M26)
    h2 = h2 + (((m0 >> 52) | (m1 << 12)) & M26)
    h3 = h3 + ((m1 >> 14) & M26)
    h4 = h4 + ((m1 >> 40) | hibit)
    local d0 = h0 * r0 + h1 * q4 + h2 * q3 + h3 * q2 + h4 * q1
    local d1 = h0 * r1 + h1 * r0 + h2 * q4 + h3 * q3 + h4 * q2
    local d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * q4 + h4 * q3
    local d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * q4
    local d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0
    local c = d0 >> 26; h0 = d0 & M26
    d1 = d1 + c; c = d1 >> 26; h1 = d1 & M26
    d2 = d2 + c; c = d2 >> 26; h2 = d2 & M26
    d3 = d3 + c; c = d3 >> 26; h3 = d3 & M26
    d4 = d4 + c; c = d4 >> 26; h4 = d4 & M26
    h0 = h0 + c * 5; c = h0 >> 26; h0 = h0 & M26
    h1 = h1 + c
  end

  hibit = 1 << 24
  while len - pos + 1 >= 16 do
    m0, m1 = sunpack("<I8I8", msg, pos)
    absorb()
    pos = pos + 16
  end
  if pos <= len then
    local block = ssub(msg, pos) .. "\1" .. srep("\0", 15 - (len - pos))
    m0, m1 = sunpack("<I8I8", block)
    hibit = 0
    absorb()
  end

  -- full carry
  local c
  c = h1 >> 26; h1 = h1 & M26; h2 = h2 + c
  c = h2 >> 26; h2 = h2 & M26; h3 = h3 + c
  c = h3 >> 26; h3 = h3 & M26; h4 = h4 + c
  c = h4 >> 26; h4 = h4 & M26; h0 = h0 + c * 5
  c = h0 >> 26; h0 = h0 & M26; h1 = h1 + c

  -- g = h + 5 - 2^130; select g if no borrow
  local g0 = h0 + 5; c = g0 >> 26; g0 = g0 & M26
  local g1 = h1 + c; c = g1 >> 26; g1 = g1 & M26
  local g2 = h2 + c; c = g2 >> 26; g2 = g2 & M26
  local g3 = h3 + c; c = g3 >> 26; g3 = g3 & M26
  local g4 = h4 + c - (1 << 26)
  if g4 >= 0 then h0, h1, h2, h3, h4 = g0, g1, g2, g3, g4 & M26 end

  -- h mod 2^128 + s mod 2^128
  local lo = (h0 | (h1 << 26) | (h2 << 52))
  local hi = ((h2 >> 12) | (h3 << 14) | (h4 << 40))
  local sum = lo + s0
  if math.ult(sum, lo) then hi = hi + 1 end
  return spack("<i8i8", sum, hi + s1)
end

---------------------------------------------------------------------------
-- AEAD
---------------------------------------------------------------------------

local function pad16(n) return (16 - n % 16) % 16 end

local function tag(key, nonce, aad, ct)
  local otk = ssub(M.chacha20_block(key, nonce, 0), 1, 32)
  local mac_data = aad .. srep("\0", pad16(#aad)) .. ct .. srep("\0", pad16(#ct)) .. spack("<I8I8", #aad, #ct)
  return M.poly1305(otk, mac_data)
end

function M.encrypt(key, nonce, plaintext, aad)
  aad = aad or ""
  local ct = M.chacha20(key, nonce, 1, plaintext)
  return ct .. tag(key, nonce, aad, ct)
end

function M.decrypt(key, nonce, ciphertext, aad)
  aad = aad or ""
  if #ciphertext < 16 then return nil, "auth failed" end
  local ct = ssub(ciphertext, 1, -17)
  local expect = tag(key, nonce, aad, ct)
  local got = ssub(ciphertext, -16)
  -- constant-time compare
  local diff = 0
  for i = 1, 16 do diff = diff | (sbyte(expect, i) ~ sbyte(got, i)) end
  if diff ~= 0 then return nil, "auth failed" end
  return M.chacha20(key, nonce, 1, ct)
end

return M
