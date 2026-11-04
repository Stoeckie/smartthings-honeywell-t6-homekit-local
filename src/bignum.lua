-- bignum.lua: arbitrary-precision unsigned integers in pure Lua 5.3.
--
-- Representation: table { n = limb_count, [1..n] = limbs }, little-endian,
-- 28-bit limbs, normalized (no leading zero limbs; zero has n == 0).
-- 28-bit limbs keep a limb product under 2^56, so a column sum of up to
-- ~220 products plus a carry stays below 2^64 (Lua's wrap-around integer
-- arithmetic with logical >> is used as unsigned arithmetic there).
--
-- modpow uses Montgomery multiplication (product-scanning / FIPS form)
-- with a sliding window, which is where all the performance effort went.

local BITS = 28
local MASK = (1 << BITS) - 1
local BASE = 1 << BITS

local M = {}

local function new(n) return { n = n or 0 } end

local function trim(a)
  local n = a.n
  while n > 0 and a[n] == 0 do a[n] = nil; n = n - 1 end
  a.n = n
  return a
end

local function copy(a)
  local r = new(a.n)
  for i = 1, a.n do r[i] = a[i] end
  return r
end

local function bitlen_int(v)  -- bit length of a non-negative Lua integer
  local b = 0
  while v > 0 do v = v >> 1; b = b + 1 end
  return b
end

------------------------------------------------------------------------
-- Conversion
------------------------------------------------------------------------

function M.from_int(v)
  assert(math.type(v) == "integer" and v >= 0, "from_int: non-negative integer expected")
  local r = new(0)
  while v > 0 do
    r.n = r.n + 1
    r[r.n] = v & MASK
    v = v >> BITS
  end
  return r
end

-- Big-endian byte string -> bignum.
function M.from_bytes(s)
  local r = new(0)
  local acc, accbits = 0, 0
  for i = #s, 1, -1 do
    acc = acc | (s:byte(i) << accbits)
    accbits = accbits + 8
    if accbits >= BITS then
      r.n = r.n + 1
      r[r.n] = acc & MASK
      acc = acc >> BITS
      accbits = accbits - BITS
    end
  end
  if acc > 0 then r.n = r.n + 1; r[r.n] = acc end
  return trim(r)
end

-- bignum -> big-endian byte string, minimal length ("" for zero), or
-- left-padded with zero bytes to pad_len.
function M.to_bytes(a, pad_len)
  local bytes, nb = {}, 0  -- little-endian list of byte values
  local acc, accbits = 0, 0
  for i = 1, a.n do
    acc = acc | (a[i] << accbits)
    accbits = accbits + BITS
    while accbits >= 8 do
      nb = nb + 1; bytes[nb] = acc & 0xFF
      acc = acc >> 8; accbits = accbits - 8
    end
  end
  while acc > 0 do nb = nb + 1; bytes[nb] = acc & 0xFF; acc = acc >> 8 end
  while nb > 0 and bytes[nb] == 0 do nb = nb - 1 end
  local out = {}
  local pad = (pad_len or 0) - nb
  for i = 1, pad do out[i] = "\0" end
  if pad < 0 then pad = 0 end
  for i = 1, nb do out[pad + i] = string.char(bytes[nb + 1 - i]) end
  return table.concat(out)
end

function M.bitlen(a)
  if a.n == 0 then return 0 end
  return (a.n - 1) * BITS + bitlen_int(a[a.n])
end

function M.is_zero(a) return a.n == 0 end

------------------------------------------------------------------------
-- Comparison, addition, subtraction
------------------------------------------------------------------------

local function cmp(a, b)
  if a.n ~= b.n then return a.n < b.n and -1 or 1 end
  for i = a.n, 1, -1 do
    local x, y = a[i], b[i]
    if x ~= y then return x < y and -1 or 1 end
  end
  return 0
end
M.cmp = cmp

local function add(a, b)
  if a.n < b.n then a, b = b, a end
  local r = new(a.n)
  local carry = 0
  for i = 1, b.n do
    local s = a[i] + b[i] + carry
    r[i] = s & MASK; carry = s >> BITS
  end
  for i = b.n + 1, a.n do
    local s = a[i] + carry
    r[i] = s & MASK; carry = s >> BITS
  end
  if carry > 0 then r.n = r.n + 1; r[r.n] = carry end
  return r
end
M.add = add

-- a - b; errors if a < b.
local function sub(a, b)
  assert(cmp(a, b) >= 0, "sub: negative result")
  local r = new(a.n)
  local borrow = 0
  for i = 1, b.n do
    local s = a[i] - b[i] - borrow
    if s < 0 then s = s + BASE; borrow = 1 else borrow = 0 end
    r[i] = s
  end
  for i = b.n + 1, a.n do
    local s = a[i] - borrow
    if s < 0 then s = s + BASE; borrow = 1 else borrow = 0 end
    r[i] = s
  end
  return trim(r)
end
M.sub = sub

------------------------------------------------------------------------
-- Multiplication (schoolbook, row by row with per-row carry propagation;
-- safe for any operand size)
------------------------------------------------------------------------

local function mul(a, b)
  local na, nb = a.n, b.n
  if na == 0 or nb == 0 then return new(0) end
  local r = new(na + nb)
  for i = 1, na + nb do r[i] = 0 end
  for i = 1, na do
    local ai = a[i]
    if ai ~= 0 then
      local carry = 0
      local k = i
      for j = 1, nb do
        local t = r[k] + ai * b[j] + carry
        r[k] = t & MASK; carry = t >> BITS
        k = k + 1
      end
      r[k] = carry
    end
  end
  return trim(r)
end
M.mul = mul

------------------------------------------------------------------------
-- Division (Knuth algorithm D)
------------------------------------------------------------------------

-- Shift left by 0..27 bits into an array of a.n + 1 limbs (not trimmed).
local function shl_small(a, shift)
  local r = new(a.n + 1)
  local carry = 0
  for i = 1, a.n do
    local v = (a[i] << shift) | carry
    r[i] = v & MASK; carry = v >> BITS
  end
  r[a.n + 1] = carry
  return r
end

local function divmod_small(a, d)
  local q = new(a.n)
  local rem = 0
  for i = a.n, 1, -1 do
    local cur = (rem << BITS) | a[i]
    q[i] = cur // d; rem = cur % d
  end
  return trim(q), M.from_int(rem)
end

local function divmod(a, b)
  assert(b.n > 0, "division by zero")
  if cmp(a, b) < 0 then return new(0), copy(a) end
  if b.n == 1 then return divmod_small(a, b[1]) end

  local shift = BITS - bitlen_int(b[b.n])
  local u = shl_small(a, shift)   -- a.n + 1 limbs
  local v = shl_small(b, shift)   -- top limb v[nb] has bit 27 set
  local nb = b.n
  local vtop, vnext = v[nb], v[nb - 1]
  local q = new(a.n - nb + 1)

  for j = a.n - nb + 1, 1, -1 do
    local num = (u[j + nb] << BITS) | u[j + nb - 1]
    local qhat, rhat = num // vtop, num % vtop
    if qhat > MASK then qhat = MASK; rhat = num - qhat * vtop end
    while rhat <= MASK and qhat * vnext > ((rhat << BITS) | u[j + nb - 2]) do
      qhat = qhat - 1; rhat = rhat + vtop
    end
    -- u[j .. j+nb] -= qhat * v
    local carry, borrow = 0, 0
    for i = 1, nb do
      local p = qhat * v[i] + carry
      carry = p >> BITS
      local t = u[j + i - 1] - (p & MASK) - borrow
      if t < 0 then t = t + BASE; borrow = 1 else borrow = 0 end
      u[j + i - 1] = t
    end
    local t = u[j + nb] - carry - borrow
    if t < 0 then  -- qhat was one too large: add v back
      u[j + nb] = t + BASE
      qhat = qhat - 1
      carry = 0
      for i = 1, nb do
        local s = u[j + i - 1] + v[i] + carry
        u[j + i - 1] = s & MASK; carry = s >> BITS
      end
      u[j + nb] = (u[j + nb] + carry) & MASK
    else
      u[j + nb] = t
    end
    q[j] = qhat
  end

  -- remainder is u[1..nb] >> shift
  local r = new(nb)
  for i = 1, nb do
    local hi = (i < nb) and u[i + 1] or 0
    r[i] = ((u[i] >> shift) | (hi << (BITS - shift))) & MASK
  end
  return trim(q), trim(r)
end
M.divmod = divmod

function M.div(a, b) return (divmod(a, b)) end
function M.mod(a, b) local _, r = divmod(a, b); return r end

------------------------------------------------------------------------
-- Montgomery arithmetic (odd modulus only)
------------------------------------------------------------------------
-- Montgomery values are plain arrays of exactly n limbs (zero padded),
-- kept in [0, 2N). n is chosen so that R = 2^(28n) > 4N, hence the result
-- of a Montgomery product of two such values is again below 2N without a
-- conditional subtraction; only the final conversion reduces fully.

local function mont_ctx(mod)
  local ctx = mod._mont
  if ctx then return ctx end
  assert(mod.n > 0 and mod[1] & 1 == 1, "modpow: modulus must be odd")
  -- n limbs with R = 2^(28n) > 4N: add a zero limb if the top limb is > 26 bits
  local n = mod.n
  if bitlen_int(mod[n]) > BITS - 2 then n = n + 1 end
  local N = {}
  for i = 1, n do N[i] = mod[i] or 0 end

  -- n0inv = -N^-1 mod 2^28 by Newton iteration (odd n0 is its own inverse mod 8)
  local n0 = N[1]
  local inv = n0
  for _ = 1, 4 do inv = (inv * (2 - n0 * inv)) & MASK end
  local n0inv = (-inv) & MASK

  -- R^2 mod N, as an n-limb array
  local rr = new(2 * n + 1)
  for i = 1, 2 * n do rr[i] = 0 end
  rr[2 * n + 1] = 1
  local R2 = M.mod(rr, mod)
  for i = R2.n + 1, n do R2[i] = 0 end

  local one = {}
  one[1] = 1
  for i = 2, n do one[i] = 0 end

  local m = {}  -- scratch for the per-column Montgomery quotient digits

  -- r = a*b/R mod N (r may alias a or b). Product scanning, both halves.
  local function mul(a, b, r)
    local s = 0
    for k = 1, n do
      local kk = k + 1
      for i = 1, k do s = s + a[i] * b[kk - i] end
      for i = 1, k - 1 do s = s + m[i] * N[kk - i] end
      local mk = (s * n0inv) & MASK
      m[k] = mk
      s = (s + mk * N[1]) >> BITS
    end
    for k = n + 1, 2 * n - 1 do
      local kk = k + 1
      local lo = k - n + 1
      for i = lo, n do s = s + a[i] * b[kk - i] end
      for i = lo, n do s = s + m[i] * N[kk - i] end
      r[k - n] = s & MASK
      s = s >> BITS
    end
    r[n] = s
    return r
  end

  -- r = a*a/R mod N (r may alias a). Cross products counted once and doubled.
  local function sqr(a, r)
    local s = 0
    for k = 1, n do
      local kk = k + 1
      local c = 0
      for i = 1, k >> 1 do c = c + a[i] * a[kk - i] end
      s = s + (c << 1)
      if k & 1 == 1 then local h = a[kk >> 1]; s = s + h * h end
      for i = 1, k - 1 do s = s + m[i] * N[kk - i] end
      local mk = (s * n0inv) & MASK
      m[k] = mk
      s = (s + mk * N[1]) >> BITS
    end
    for k = n + 1, 2 * n - 1 do
      local kk = k + 1
      local lo = k - n + 1
      local c = 0
      for i = lo, k >> 1 do c = c + a[i] * a[kk - i] end
      s = s + (c << 1)
      if k & 1 == 1 then local h = a[kk >> 1]; s = s + h * h end
      for i = lo, n do s = s + m[i] * N[kk - i] end
      r[k - n] = s & MASK
      s = s >> BITS
    end
    r[n] = s
    return r
  end

  -- bignum (< N) -> Montgomery array
  local function to_mont(x)
    local a = {}
    for i = 1, n do a[i] = x[i] or 0 end
    return mul(a, R2, a)
  end

  -- Montgomery array -> fully reduced bignum
  local function from_mont(a)
    local r = new(n)
    mul(a, one, r)
    trim(r)
    if cmp(r, mod) >= 0 then r = sub(r, mod) end
    return r
  end

  ctx = { n = n, mul = mul, sqr = sqr, to_mont = to_mont, from_mont = from_mont, one = one }
  mod._mont = ctx
  return ctx
end

local function getbit(e, i)
  return (e[(i // BITS) + 1] >> (i % BITS)) & 1
end

-- Slow but general fallback for even moduli.
local function modpow_generic(base, exp, mod)
  local result = M.from_int(1)
  local b = M.mod(base, mod)
  for i = 0, M.bitlen(exp) - 1 do
    if getbit(exp, i) == 1 then result = M.mod(mul(result, b), mod) end
    b = M.mod(mul(b, b), mod)
  end
  return result
end

-- Optional: M.yield_hook = function() ... end is called every 32 window steps of modpow
-- so a cooperative scheduler (cosock on the SmartThings hub) can run other tasks meanwhile.
M.yield_hook = nil

-- base^exp mod mod, sliding-window Montgomery exponentiation.
function M.modpow(base, exp, mod)
  assert(mod.n > 0, "modpow: division by zero")
  if mod.n == 1 and mod[1] == 1 then return new(0) end
  if exp.n == 0 then return M.from_int(1) end
  if mod[1] & 1 == 0 then return modpow_generic(base, exp, mod) end

  local ctx = mont_ctx(mod)
  local msqr, mmul = ctx.sqr, ctx.mul
  local bits = M.bitlen(exp)
  local w = (bits > 1536) and 5 or (bits > 256) and 4 or 3

  -- odd powers g[1], g[3], ..., g[2^w - 1] in Montgomery form
  local x = ctx.to_mont(M.mod(base, mod))
  local g = { [1] = x }
  local x2 = msqr(x, {})
  for i = 3, (1 << w) - 1, 2 do
    g[i] = mmul(g[i - 2], x2, {})
  end

  local acc, started = {}, false
  local i = bits - 1
  local hook, steps = M.yield_hook, 0
  while i >= 0 do
    steps = steps + 1
    if hook and steps % 32 == 0 then hook() end
    if getbit(exp, i) == 0 then
      if started then msqr(acc, acc) end
      i = i - 1
    else
      local l = i - w + 1
      if l < 0 then l = 0 end
      while getbit(exp, l) == 0 do l = l + 1 end
      local val = 0
      for j = i, l, -1 do val = (val << 1) | getbit(exp, j) end
      if started then
        for _ = 1, i - l + 1 do msqr(acc, acc) end
        mmul(acc, g[val], acc)
      else
        for j = 1, ctx.n do acc[j] = g[val][j] end
        started = true
      end
      i = l - 1
    end
  end
  return ctx.from_mont(acc)
end

------------------------------------------------------------------------
-- Convenience
------------------------------------------------------------------------

function M.copy(a) return copy(a) end
function M.eq(a, b) return cmp(a, b) == 0 end

function M.to_hex(a)
  local s = M.to_bytes(a)
  if s == "" then return "0" end
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end):gsub("^0", ""))
end

function M.from_hex(h)
  if #h % 2 == 1 then h = "0" .. h end
  return M.from_bytes((h:gsub("..", function(x) return string.char(tonumber(x, 16)) end)))
end

return M
