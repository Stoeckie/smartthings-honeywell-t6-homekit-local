-- Random bytes for HomeKit keys. The SmartThings hub gives drivers no secure random source, and os.time,
-- os.clock and math.random together hold far too little entropy for a key (a few dozen bits at most).
-- So: /dev/urandom when the sandbox allows it, plus timing jitter of the CPU (the low bits of how long a
-- SHA-512 takes vary from run to run, like jitterentropy), collected into a pool that is kept across driver
-- restarts (rng.save / rng.seed) so it only grows. Output comes from a hash of the pool and the pool moves on
-- after every call (an output cannot be recomputed from a later pool).
local sha = require "sha512"

local M = {}

local gettime = os.clock
do
  local ok, s = pcall(require, "socket")
  if ok and type(s) == "table" and type(s.gettime) == "function" then gettime = s.gettime end
end

local pool = sha.sha512(tostring(os.time()) .. tostring({}) .. tostring(collectgarbage("count")))

local function urandom(n)
  if type(io) ~= "table" or type(io.open) ~= "function" then return nil end
  local ok, f = pcall(io.open, "/dev/urandom", "rb")
  if not ok or not f then return nil end
  local ok2, b = pcall(f.read, f, n)
  pcall(f.close, f)
  if ok2 and type(b) == "string" and #b == n then return b end
  return nil
end
M.urandom = urandom

-- timing jitter: many short timed hash runs; every sample adds a little unpredictability
local function jitter(samples)
  local t, x = {}, pool
  for i = 1, samples do
    local a, c = gettime(), os.clock()
    x = sha.sha512(x .. i)
    local b = gettime()
    t[i] = string.format("%.9f/%.9f/%.6f", b - a, os.clock() - c, b)
  end
  return table.concat(t, ";") .. x
end

M.save = nil   -- function(pool_bytes): set by the driver to keep the pool across restarts

--- Mix earlier kept pool bytes or any other unpredictable data (e.g. arrival times of packets) into the pool.
function M.seed(s)
  if s ~= nil and s ~= "" then pool = sha.sha512(pool .. tostring(s) .. string.format("%.6f", gettime())) end
end

function M.bytes(n)
  local u = urandom(64)
  pool = sha.sha512(pool .. (u or "") .. jitter(u and 16 or 256) .. tostring(os.time()) .. tostring({}))
  local out, ctr, have = {}, 0, 0
  while have < n do
    ctr = ctr + 1
    out[#out + 1] = sha.sha512("out" .. pool .. ctr):sub(1, 32)
    have = have + 32
  end
  pool = sha.sha512("next" .. pool)
  if M.save then pcall(M.save, pool) end
  return table.concat(out):sub(1, n)
end

return M
