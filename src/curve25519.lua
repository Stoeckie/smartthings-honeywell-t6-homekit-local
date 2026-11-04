-- Curve25519 in pure Lua 5.3: X25519 (RFC 7748) and Ed25519 (RFC 8032).
-- Field elements are ten signed limbs of alternating 26/25 bits (ref10 layout),
-- stored in 1-based tables; all intermediate products fit in 64-bit integers
-- as long as inputs to mul/sq are at most the sum of three reduced elements.
local sha512 = require("sha512").sha512

local M = {}

---------------------------------------------------------------------------
-- Field arithmetic mod 2^255-19
---------------------------------------------------------------------------
local function fe0() return { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } end
local function fe1() return { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 } end

local function fe_add(f, g)
  return { f[1] + g[1], f[2] + g[2], f[3] + g[3], f[4] + g[4], f[5] + g[5],
           f[6] + g[6], f[7] + g[7], f[8] + g[8], f[9] + g[9], f[10] + g[10] }
end

local function fe_sub(f, g)
  return { f[1] - g[1], f[2] - g[2], f[3] - g[3], f[4] - g[4], f[5] - g[5],
           f[6] - g[6], f[7] - g[7], f[8] - g[8], f[9] - g[9], f[10] - g[10] }
end

local function fe_neg(f)
  return { -f[1], -f[2], -f[3], -f[4], -f[5], -f[6], -f[7], -f[8], -f[9], -f[10] }
end

-- Carry chain (ref10). `//` is floor division, i.e. an arithmetic shift.
local function fe_carry(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
  local c
  c = (h0 + 0x2000000) // 0x4000000; h1 = h1 + c; h0 = h0 - (c << 26)
  c = (h4 + 0x2000000) // 0x4000000; h5 = h5 + c; h4 = h4 - (c << 26)
  c = (h1 + 0x1000000) // 0x2000000; h2 = h2 + c; h1 = h1 - (c << 25)
  c = (h5 + 0x1000000) // 0x2000000; h6 = h6 + c; h5 = h5 - (c << 25)
  c = (h2 + 0x2000000) // 0x4000000; h3 = h3 + c; h2 = h2 - (c << 26)
  c = (h6 + 0x2000000) // 0x4000000; h7 = h7 + c; h6 = h6 - (c << 26)
  c = (h3 + 0x1000000) // 0x2000000; h4 = h4 + c; h3 = h3 - (c << 25)
  c = (h7 + 0x1000000) // 0x2000000; h8 = h8 + c; h7 = h7 - (c << 25)
  c = (h4 + 0x2000000) // 0x4000000; h5 = h5 + c; h4 = h4 - (c << 26)
  c = (h8 + 0x2000000) // 0x4000000; h9 = h9 + c; h8 = h8 - (c << 26)
  c = (h9 + 0x1000000) // 0x2000000; h0 = h0 + c * 19; h9 = h9 - (c << 25)
  c = (h0 + 0x2000000) // 0x4000000; h1 = h1 + c; h0 = h0 - (c << 26)
  return { h0, h1, h2, h3, h4, h5, h6, h7, h8, h9 }
end

local function fe_mul(f, g)
  local f0, f1, f2, f3, f4, f5, f6, f7, f8, f9 = f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10]
  local g0, g1, g2, g3, g4, g5, g6, g7, g8, g9 = g[1], g[2], g[3], g[4], g[5], g[6], g[7], g[8], g[9], g[10]
  local g1_19, g2_19, g3_19, g4_19, g5_19 = 19 * g1, 19 * g2, 19 * g3, 19 * g4, 19 * g5
  local g6_19, g7_19, g8_19, g9_19 = 19 * g6, 19 * g7, 19 * g8, 19 * g9
  local f1_2, f3_2, f5_2, f7_2, f9_2 = 2 * f1, 2 * f3, 2 * f5, 2 * f7, 2 * f9
  local h0 = f0*g0 + f1_2*g9_19 + f2*g8_19 + f3_2*g7_19 + f4*g6_19 + f5_2*g5_19 + f6*g4_19 + f7_2*g3_19 + f8*g2_19 + f9_2*g1_19
  local h1 = f0*g1 + f1*g0 + f2*g9_19 + f3*g8_19 + f4*g7_19 + f5*g6_19 + f6*g5_19 + f7*g4_19 + f8*g3_19 + f9*g2_19
  local h2 = f0*g2 + f1_2*g1 + f2*g0 + f3_2*g9_19 + f4*g8_19 + f5_2*g7_19 + f6*g6_19 + f7_2*g5_19 + f8*g4_19 + f9_2*g3_19
  local h3 = f0*g3 + f1*g2 + f2*g1 + f3*g0 + f4*g9_19 + f5*g8_19 + f6*g7_19 + f7*g6_19 + f8*g5_19 + f9*g4_19
  local h4 = f0*g4 + f1_2*g3 + f2*g2 + f3_2*g1 + f4*g0 + f5_2*g9_19 + f6*g8_19 + f7_2*g7_19 + f8*g6_19 + f9_2*g5_19
  local h5 = f0*g5 + f1*g4 + f2*g3 + f3*g2 + f4*g1 + f5*g0 + f6*g9_19 + f7*g8_19 + f8*g7_19 + f9*g6_19
  local h6 = f0*g6 + f1_2*g5 + f2*g4 + f3_2*g3 + f4*g2 + f5_2*g1 + f6*g0 + f7_2*g9_19 + f8*g8_19 + f9_2*g7_19
  local h7 = f0*g7 + f1*g6 + f2*g5 + f3*g4 + f4*g3 + f5*g2 + f6*g1 + f7*g0 + f8*g9_19 + f9*g8_19
  local h8 = f0*g8 + f1_2*g7 + f2*g6 + f3_2*g5 + f4*g4 + f5_2*g3 + f6*g2 + f7_2*g1 + f8*g0 + f9_2*g9_19
  local h9 = f0*g9 + f1*g8 + f2*g7 + f3*g6 + f4*g5 + f5*g4 + f6*g3 + f7*g2 + f8*g1 + f9*g0
  return fe_carry(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
end

local function fe_sq(f)
  local f0, f1, f2, f3, f4, f5, f6, f7, f8, f9 = f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10]
  local f0_2, f1_2, f2_2, f3_2, f4_2 = 2 * f0, 2 * f1, 2 * f2, 2 * f3, 2 * f4
  local f5_2, f6_2, f7_2, f8_2, f9_2 = 2 * f5, 2 * f6, 2 * f7, 2 * f8, 2 * f9
  local f5_19, f6_19, f7_19, f8_19, f9_19 = 19 * f5, 19 * f6, 19 * f7, 19 * f8, 19 * f9
  local f5_38, f7_38, f9_38 = 38 * f5, 38 * f7, 38 * f9
  local h0 = f0*f0 + f1_2*f9_38 + f2_2*f8_19 + f3_2*f7_38 + f4_2*f6_19 + f5_2*f5_19
  local h1 = f0_2*f1 + f2_2*f9_19 + f3_2*f8_19 + f4_2*f7_19 + f5_2*f6_19
  local h2 = f0_2*f2 + f1_2*f1 + f3_2*f9_38 + f4_2*f8_19 + f5_2*f7_38 + f6*f6_19
  local h3 = f0_2*f3 + f1_2*f2 + f4_2*f9_19 + f5_2*f8_19 + f6_2*f7_19
  local h4 = f0_2*f4 + f1_2*f3_2 + f2*f2 + f5_2*f9_38 + f6_2*f8_19 + f7_2*f7_19
  local h5 = f0_2*f5 + f1_2*f4 + f2_2*f3 + f6_2*f9_19 + f7_2*f8_19
  local h6 = f0_2*f6 + f1_2*f5_2 + f2_2*f4 + f3_2*f3 + f7_2*f9_38 + f8*f8_19
  local h7 = f0_2*f7 + f1_2*f6 + f2_2*f5 + f3_2*f4 + f8_2*f9_19
  local h8 = f0_2*f8 + f1_2*f7_2 + f2_2*f6 + f3_2*f5_2 + f4*f4 + f9_2*f9_19
  local h9 = f0_2*f9 + f1_2*f8 + f2_2*f7 + f3_2*f6 + f4_2*f5
  return fe_carry(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
end

-- f^(2^n)
local function fe_sqn(f, n)
  for _ = 1, n do f = fe_sq(f) end
  return f
end

-- Shared prefix of the inversion / sqrt addition chains: returns z^(2^250-1), z^11.
local function pow250(z)
  local t0 = fe_sq(z)                      -- z^2
  local t1 = fe_mul(z, fe_sqn(t0, 2))      -- z^9
  t0 = fe_mul(t0, t1)                      -- z^11
  t1 = fe_mul(t1, fe_sq(t0))               -- z^31 = 2^5-1
  t1 = fe_mul(fe_sqn(t1, 5), t1)           -- 2^10-1
  local t2 = fe_mul(fe_sqn(t1, 10), t1)    -- 2^20-1
  t2 = fe_mul(fe_sqn(t2, 20), t2)          -- 2^40-1
  t1 = fe_mul(fe_sqn(t2, 10), t1)          -- 2^50-1
  t2 = fe_mul(fe_sqn(t1, 50), t1)          -- 2^100-1
  t2 = fe_mul(fe_sqn(t2, 100), t2)         -- 2^200-1
  t1 = fe_mul(fe_sqn(t2, 50), t1)          -- 2^250-1
  return t1, t0
end

local function fe_invert(z)                -- z^(p-2) = z^(2^255-21)
  local t1, t0 = pow250(z)
  return fe_mul(fe_sqn(t1, 5), t0)
end

local function fe_pow22523(z)              -- z^((p-5)/8) = z^(2^252-3)
  local t1 = pow250(z)
  return fe_mul(fe_sqn(t1, 2), z)
end

local function load3(s, i) return (string.unpack("<I3", s, i)) end
local function load4(s, i) return (string.unpack("<I4", s, i)) end

local function fe_frombytes(s)
  local h0 = load4(s, 1)
  local h1 = load3(s, 5) << 6
  local h2 = load3(s, 8) << 5
  local h3 = load3(s, 11) << 3
  local h4 = load3(s, 14) << 2
  local h5 = load4(s, 17)
  local h6 = load3(s, 21) << 7
  local h7 = load3(s, 24) << 5
  local h8 = load3(s, 27) << 4
  local h9 = (load3(s, 30) & 0x7fffff) << 2
  return fe_carry(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
end

-- Fully reduced little-endian encoding (ref10 fe_tobytes).
local function fe_tobytes(f)
  local h0, h1, h2, h3, h4, h5, h6, h7, h8, h9 = f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10]
  local q = (19 * h9 + 0x1000000) // 0x2000000
  q = (h0 + q) // 0x4000000; q = (h1 + q) // 0x2000000
  q = (h2 + q) // 0x4000000; q = (h3 + q) // 0x2000000
  q = (h4 + q) // 0x4000000; q = (h5 + q) // 0x2000000
  q = (h6 + q) // 0x4000000; q = (h7 + q) // 0x2000000
  q = (h8 + q) // 0x4000000; q = (h9 + q) // 0x2000000
  h0 = h0 + 19 * q
  local c
  c = h0 // 0x4000000; h1 = h1 + c; h0 = h0 - (c << 26)
  c = h1 // 0x2000000; h2 = h2 + c; h1 = h1 - (c << 25)
  c = h2 // 0x4000000; h3 = h3 + c; h2 = h2 - (c << 26)
  c = h3 // 0x2000000; h4 = h4 + c; h3 = h3 - (c << 25)
  c = h4 // 0x4000000; h5 = h5 + c; h4 = h4 - (c << 26)
  c = h5 // 0x2000000; h6 = h6 + c; h5 = h5 - (c << 25)
  c = h6 // 0x4000000; h7 = h7 + c; h6 = h6 - (c << 26)
  c = h7 // 0x2000000; h8 = h8 + c; h7 = h7 - (c << 25)
  c = h8 // 0x4000000; h9 = h9 + c; h8 = h8 - (c << 26)
  c = h9 // 0x2000000; h9 = h9 - (c << 25)
  -- pack 26/25-bit limbs into 255 bits
  local limbs = { h0, h1, h2, h3, h4, h5, h6, h7, h8, h9 }
  local out, acc, nbits = {}, 0, 0
  for i = 1, 10 do
    acc = acc | (limbs[i] << nbits)
    nbits = nbits + ((i % 2 == 1) and 26 or 25)
    while nbits >= 8 do
      out[#out + 1] = string.char(acc & 0xff)
      acc = acc >> 8
      nbits = nbits - 8
    end
  end
  out[#out + 1] = string.char(acc & 0xff)
  return table.concat(out)
end

local ZERO32 = string.rep("\0", 32)
local function fe_iszero(f) return fe_tobytes(f) == ZERO32 end
local function fe_isnegative(f) return fe_tobytes(f):byte(1) & 1 == 1 end

local function fe_fromhex(h)
  return fe_frombytes((h:gsub("%x%x", function(b) return string.char(tonumber(b, 16)) end)))
end

local D = fe_fromhex("a3785913ca4deb75abd841414d0a700098e879777940c78c73fe6f2bee6c0352")
local D2 = fe_add(D, D)
local SQRTM1 = fe_fromhex("b0a00e4a271beec478e42fad0618432fa7d7fb3d99004d2b0bdfc14f8024832b")
local A24 = { 121665, 0, 0, 0, 0, 0, 0, 0, 0, 0 }

---------------------------------------------------------------------------
-- X25519 (Montgomery ladder, RFC 7748 section 5)
---------------------------------------------------------------------------
function M.x25519(k, u)
  assert(#k == 32 and #u == 32, "x25519: need 32-byte scalar and point")
  local e = { k:byte(1, 32) }
  e[1] = e[1] & 248
  e[32] = (e[32] & 127) | 64
  local x1 = fe_frombytes(u)
  local x2, z2, x3, z3 = fe1(), fe0(), x1, fe1()
  local swap = 0
  for t = 254, 0, -1 do
    local bit = (e[(t >> 3) + 1] >> (t & 7)) & 1
    if swap ~ bit == 1 then
      x2, x3 = x3, x2
      z2, z3 = z3, z2
    end
    swap = bit
    local a, b = fe_add(x2, z2), fe_sub(x2, z2)
    local aa, bb = fe_sq(a), fe_sq(b)
    local e1 = fe_sub(aa, bb)
    local c, d = fe_add(x3, z3), fe_sub(x3, z3)
    local da, cb = fe_mul(d, a), fe_mul(c, b)
    x3 = fe_sq(fe_add(da, cb))
    z3 = fe_mul(x1, fe_sq(fe_sub(da, cb)))
    x2 = fe_mul(aa, bb)
    z2 = fe_mul(e1, fe_add(aa, fe_mul(A24, e1)))
  end
  if swap == 1 then
    x2, x3 = x3, x2
    z2, z3 = z3, z2
  end
  return fe_tobytes(fe_mul(x2, fe_invert(z2)))
end

function M.x25519_base(k)
  return M.x25519(k, "\9" .. string.rep("\0", 31))
end

---------------------------------------------------------------------------
-- Ed25519 group: extended coordinates (X, Y, Z, T) with x = X/Z, y = Y/Z, xy = T/Z
---------------------------------------------------------------------------
local function ge_zero() return { X = fe0(), Y = fe1(), Z = fe1(), T = fe0() } end

-- Precomputed form for addition: (Y+X, Y-X, Z, 2dT)
local function ge_precomp(p)
  return { fe_add(p.Y, p.X), fe_sub(p.Y, p.X), p.Z, fe_mul(D2, p.T) }
end

local function ge_precomp_neg(q)
  return { q[2], q[1], q[3], fe_neg(q[4]) }
end

-- Unified addition p + q (q in precomputed form); RFC 8032 section 5.1.4.
local function ge_add(p, q)
  local A = fe_mul(fe_sub(p.Y, p.X), q[2])
  local B = fe_mul(fe_add(p.Y, p.X), q[1])
  local C = fe_mul(p.T, q[4])
  local Dd = fe_mul(p.Z, q[3])
  Dd = fe_add(Dd, Dd)
  local E, F, G, H = fe_sub(B, A), fe_sub(Dd, C), fe_add(Dd, C), fe_add(B, A)
  return { X = fe_mul(E, F), Y = fe_mul(G, H), Z = fe_mul(F, G), T = fe_mul(E, H) }
end

-- Doubling; T is only computed when needed (saves one mul).
local function ge_dbl(p, want_t)
  local A = fe_sq(p.X)
  local B = fe_sq(p.Y)
  local C = fe_sq(p.Z)
  C = fe_add(C, C)
  local H = fe_add(A, B)
  local E = fe_sub(H, fe_sq(fe_add(p.X, p.Y)))
  local G = fe_sub(A, B)
  local F = fe_add(C, G)
  return { X = fe_mul(E, F), Y = fe_mul(G, H), Z = fe_mul(F, G), T = want_t and fe_mul(E, H) or nil }
end

local function ge_tobytes(p)
  local zi = fe_invert(p.Z)
  local x, y = fe_mul(p.X, zi), fe_mul(p.Y, zi)
  local s = fe_tobytes(y)
  if fe_isnegative(x) then
    s = s:sub(1, 31) .. string.char(s:byte(32) | 0x80)
  end
  return s
end

-- Decode a compressed point (RFC 8032 section 5.1.3); returns nil if invalid.
local function ge_frombytes(s)
  if #s ~= 32 then return nil end
  local sign = s:byte(32) >> 7
  local Y = fe_frombytes(s)
  local ybytes = s:sub(1, 31) .. string.char(s:byte(32) & 0x7f)
  if fe_tobytes(Y) ~= ybytes then return nil end   -- y >= p is not canonical
  local Z = fe1()
  local u = fe_sq(Y)
  local v = fe_mul(u, D)
  u = fe_sub(u, Z)                                 -- y^2 - 1
  v = fe_add(v, Z)                                 -- d*y^2 + 1
  local v3 = fe_mul(fe_sq(v), v)
  local X = fe_mul(fe_mul(fe_sq(v3), v), u)        -- u*v^7
  X = fe_mul(fe_mul(fe_pow22523(X), v3), u)        -- u*v^3*(u*v^7)^((p-5)/8)
  local vxx = fe_mul(fe_sq(X), v)
  if not fe_iszero(fe_sub(vxx, u)) then
    if not fe_iszero(fe_add(vxx, u)) then return nil end
    X = fe_mul(X, SQRTM1)
  end
  if fe_iszero(X) then
    if sign == 1 then return nil end
  elseif (fe_isnegative(X) and 1 or 0) ~= sign then
    X = fe_neg(X)
  end
  return { X = X, Y = Y, Z = Z, T = fe_mul(X, Y) }
end

-- Table of 1P..8P in precomputed form, for signed 4-bit windows.
local function ge_table(p)
  local t = { ge_precomp(p) }
  local acc = p
  for i = 2, 8 do
    acc = ge_add(acc, t[1])  -- i*P
    t[i] = ge_precomp(acc)
  end
  return t
end

-- Signed radix-16 digits (-8..7) of a little-endian 32-byte scalar, LSB first.
local function sc_digits(s)
  local e = {}
  for i = 1, 32 do
    local b = s:byte(i)
    e[2 * i - 1] = b & 15
    e[2 * i] = b >> 4
  end
  local carry = 0
  for i = 1, 63 do
    e[i] = e[i] + carry
    carry = (e[i] + 8) >> 4
    e[i] = e[i] - (carry << 4)
  end
  e[64] = e[64] + carry
  return e
end

-- sum_i digits[i] * points[i] (interleaved double-and-add, 4-bit windows).
local function ge_multi_mul(tables, digits)
  local h = ge_zero()
  for i = 64, 1, -1 do
    if i < 64 then
      h = ge_dbl(h); h = ge_dbl(h); h = ge_dbl(h); h = ge_dbl(h, true)
    end
    for j = 1, #tables do
      local d = digits[j][i]
      if d > 0 then
        h = ge_add(h, tables[j][d])
      elseif d < 0 then
        h = ge_add(h, ge_precomp_neg(tables[j][-d]))
      end
    end
  end
  return h
end

local B = ge_frombytes("\88" .. string.rep("\102", 31))   -- y = 4/5
local B_TABLE = ge_table(B)

local function ge_scalarmult_base(s)
  return ge_multi_mul({ B_TABLE }, { sc_digits(s) })
end

---------------------------------------------------------------------------
-- Scalars mod L = 2^252 + 27742317777372353535851937790883648493
-- Little-endian arrays of 21-bit limbs; 2^252 is exactly 12 limbs.
---------------------------------------------------------------------------
local LC = { 1430509, 1626855, 1442968, 997804, 1960495, 683900 }   -- L - 2^252
local LL = { 1430509, 1626855, 1442968, 997804, 1960495, 683900, 0, 0, 0, 0, 0, 0, 1 }

-- Normalize to >= 13 limbs in [0, 2^21); the top limb is signed (carries the sign).
local function sc_norm(a)
  for i = #a + 1, 13 do a[i] = 0 end
  local c = 0
  for i = 1, #a do
    local v = a[i] + c
    c = v // 0x200000
    a[i] = v - (c << 21)
  end
  if c ~= 0 then a[#a + 1] = c end
  while #a > 1 and a[#a] == 0 do a[#a] = nil end
  return a
end

local function sc_mul(a, b)
  local r = {}
  for i = 1, #a + #b - 1 do r[i] = 0 end
  for i = 1, #a do
    local ai = a[i]
    if ai ~= 0 then
      for j = 1, #b do r[i + j - 1] = r[i + j - 1] + ai * b[j] end
    end
  end
  return sc_norm(r)
end

local function sc_addsub(a, b, sign)
  local r = {}
  for i = 1, math.max(#a, #b) do r[i] = (a[i] or 0) + sign * (b[i] or 0) end
  return sc_norm(r)
end

local function sc_isneg(a) return a[#a] < 0 end

-- Reduce a normalized a with |a| < 2^525 to [0, L).
local function sc_reduce(a)
  for _ = 1, 4 do
    if #a <= 12 then break end
    -- a = lo + hi*2^252 == lo - hi*(L - 2^252)  (mod L); three rounds leave |hi| <= 1
    local lo, hi = {}, {}
    for i = 1, 12 do lo[i] = a[i] end
    for i = 13, #a do hi[i - 12] = a[i] end
    a = sc_addsub(lo, sc_mul(hi, LC), -1)
  end
  if sc_isneg(a) then
    a = sc_addsub(a, LL, 1)
  else
    local d = sc_addsub(a, LL, -1)
    if not sc_isneg(d) then a = d end
  end
  return a
end

local function sc_frombytes(s)
  local r, acc, nbits = {}, 0, 0
  for i = 1, #s do
    acc = acc | (s:byte(i) << nbits)
    nbits = nbits + 8
    if nbits >= 21 then
      r[#r + 1] = acc & 0x1fffff
      acc = acc >> 21
      nbits = nbits - 21
    end
  end
  r[#r + 1] = acc
  return sc_norm(r)
end

local function sc_tobytes(a)
  local out, acc, nbits = {}, 0, 0
  for i = 1, 13 do
    acc = acc | ((a[i] or 0) << nbits)
    nbits = nbits + 21
    while nbits >= 8 and #out < 32 do
      out[#out + 1] = string.char(acc & 0xff)
      acc = acc >> 8
      nbits = nbits - 8
    end
  end
  return table.concat(out)
end

local function sc_reduce_bytes(s)         -- 64-byte hash -> 32-byte scalar mod L
  return sc_tobytes(sc_reduce(sc_frombytes(s)))
end

local function sc_muladd_bytes(a, b, c)   -- (a*b + c) mod L, 32-byte inputs/output
  local r = sc_addsub(sc_mul(sc_frombytes(a), sc_frombytes(b)), sc_frombytes(c), 1)
  return sc_tobytes(sc_reduce(r))
end

local function sc_is_canonical(s)         -- s < L ?
  return sc_isneg(sc_addsub(sc_frombytes(s), LL, -1))
end

---------------------------------------------------------------------------
-- Ed25519 (RFC 8032 section 5.1)
---------------------------------------------------------------------------
local function expand_seed(seed)
  local h = sha512(seed)
  local a = { h:byte(1, 32) }
  a[1] = a[1] & 248
  a[32] = (a[32] & 63) | 64
  local bytes = {}
  for i = 1, 32 do bytes[i] = string.char(a[i]) end
  return table.concat(bytes), h:sub(33, 64)
end

function M.ed25519_keypair(seed)
  assert(#seed == 32, "ed25519: seed must be 32 bytes")
  local a = expand_seed(seed)
  return ge_tobytes(ge_scalarmult_base(a))
end

function M.ed25519_sign(msg, seed, pub)
  assert(#seed == 32, "ed25519: seed must be 32 bytes")
  pub = pub or M.ed25519_keypair(seed)
  local a, prefix = expand_seed(seed)
  local r = sc_reduce_bytes(sha512(prefix .. msg))
  local R = ge_tobytes(ge_scalarmult_base(r))
  local k = sc_reduce_bytes(sha512(R .. pub .. msg))
  return R .. sc_muladd_bytes(k, a, r)
end

function M.ed25519_verify(msg, sig, pub)
  if #sig ~= 64 or #pub ~= 32 then return false end
  local R, S = sig:sub(1, 32), sig:sub(33, 64)
  if not sc_is_canonical(S) then return false end
  local A = ge_frombytes(pub)
  if not A then return false end
  local k = sc_reduce_bytes(sha512(R .. pub .. msg))
  -- R' = S*B - k*A
  local negA = { X = fe_neg(A.X), Y = A.Y, Z = A.Z, T = fe_neg(A.T) }
  local tA = ge_table(negA)
  local Rp = ge_multi_mul({ B_TABLE, tA }, { sc_digits(S), sc_digits(k) })
  return ge_tobytes(Rp) == R
end

-- exposed for tests
M._fe = { frombytes = fe_frombytes, tobytes = fe_tobytes, mul = fe_mul, sq = fe_sq,
          invert = fe_invert, add = fe_add, sub = fe_sub }
M._sc = { reduce = sc_reduce_bytes, muladd = sc_muladd_bytes }

return M
