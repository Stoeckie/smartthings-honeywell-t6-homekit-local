-- srp.lua: SRP-6a client (RFC 5054, SHA-512, 3072-bit group) with the
-- HomeKit pair-setup conventions, matching aiohomekit/crypto/srp.py:
--   k  = H(N | PAD(g))
--   x  = H(s | H(I ":" P))
--   u  = H(PAD(A) | PAD(B))
--   S  = (B - k*g^x)^(a + u*x) mod N
--   K  = H(PAD(S))
--   M1 = H(H(N) xor H(g) | H(I) | s | PAD(A) | PAD(B) | K)   (g hashed as 1 byte)
--   M2 = H(PAD(A) | M1 | K)
-- PAD() left-pads to the length of N (384 bytes).

local bn = require("bignum")
local sha = require("sha512")
local H = sha.sha512

local M = {}

local N_HEX = table.concat({
  "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E08",
  "8A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B",
  "302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9",
  "A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6",
  "49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8",
  "FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D",
  "670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C",
  "180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718",
  "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D",
  "04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7D",
  "B3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D226",
  "1AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C",
  "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFC",
  "E0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
})

local N = bn.from_hex(N_HEX)
local N_LEN = 384
local N_BYTES = bn.to_bytes(N)
local g = bn.from_int(5)
local g_byte = "\5"

local function xor_str(a, b)
  local t = {}
  for i = 1, #a do t[i] = string.char(a:byte(i) ~ b:byte(i)) end
  return table.concat(t)
end

local function pad(s) return string.rep("\0", N_LEN - #s) .. s end

local k = bn.from_bytes(H(N_BYTES .. pad(g_byte)))
local H_GROUP = xor_str(H(N_BYTES), H(g_byte))

M.N, M.g, M.k = N, g, k

------------------------------------------------------------------------
-- Randomness: caller should install a secure RNG via set_rng(fn),
-- fn(n) -> n random bytes. Fallback is math.random (NOT secure).
------------------------------------------------------------------------
local rng = function(n)
  local t = {}
  for i = 1, n do t[i] = string.char(math.random(0, 255)) end
  return table.concat(t)
end

function M.set_rng(fn) rng = fn end

------------------------------------------------------------------------
-- Client
------------------------------------------------------------------------
local Client = {}
Client.__index = Client

-- srp.new(username, password, salt_bytes, B_bytes, [a_bytes])
function M.new(username, password, salt_bytes, B_bytes, a_bytes)
  local self = setmetatable({}, Client)
  self.I, self.P = username, password
  self.s = salt_bytes
  self.B_b = pad(B_bytes)
  self.B = bn.from_bytes(B_bytes)
  assert(not bn.is_zero(bn.mod(self.B, N)), "srp: invalid server public key (B mod N == 0)")

  self.a = bn.from_bytes(a_bytes or rng(32))
  self.A = bn.modpow(g, self.a, N)
  self.A_b = bn.to_bytes(self.A, N_LEN)
  return self
end

function Client:public_key() return self.A_b end

-- Compute S, K lazily (one 3072-bit modpow with a ~768-bit exponent).
function Client:_compute()
  if self.K then return end
  local x = bn.from_bytes(H(self.s .. H(self.I .. ":" .. self.P)))
  local u = bn.from_bytes(H(self.A_b .. self.B_b))
  assert(not bn.is_zero(u), "srp: u == 0")

  -- base = (B - k*g^x) mod N
  local kv = bn.mod(bn.mul(k, bn.modpow(g, x, N)), N)
  local base = bn.mod(self.B, N)
  if bn.cmp(base, kv) < 0 then base = bn.add(base, N) end
  base = bn.sub(base, kv)

  local exp = bn.add(self.a, bn.mul(u, x))
  local S = bn.modpow(base, exp, N)
  self.S_b = bn.to_bytes(S, N_LEN)
  self.K = H(self.S_b)
end

function Client:session_key()
  self:_compute()
  return self.K
end

function Client:proof()
  if not self.M1 then
    self:_compute()
    self.M1 = H(H_GROUP .. H(self.I) .. self.s .. self.A_b .. self.B_b .. self.K)
  end
  return self.M1
end

function Client:verify_server_proof(M2_bytes)
  local expected = H(self.A_b .. self:proof() .. self.K)
  return expected == M2_bytes
end

return M
