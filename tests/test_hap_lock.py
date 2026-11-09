"""hap_client: one request at a time per session (the lock), released on errors; TLV decode errors do not raise.
(Same file in the T6 and VELUX repos: hap_client.lua and tlv8.lua are shared.)"""
from run_lua import runtime

LOCK = rb'''
local hap = require "hap_client"
hap.json = require "st.json"
local sent = {}
local s = hap.session({ send = function(_, d) sent[#sent + 1] = d; return #d end }, {})
local pending = {}
s.wait_response = function()          -- async mode: a reader task hands responses out in order
  while #pending == 0 do coroutine.yield() end
  return table.remove(pending, 1)
end
hap.sleep = function() coroutine.yield() end
local r1, r2
local co1 = coroutine.create(function() r1 = s:request("PUT", "/mode") end)
local co2 = coroutine.create(function() r2 = s:request("PUT", "/setpoint") end)
assert(coroutine.resume(co1))
assert(coroutine.resume(co2))
assert(#sent == 1, "second request sent while the first waits for its response")
pending[1] = { status = 204, body = "first" }
assert(coroutine.resume(co2))         -- still waiting for the lock: must not take the first response
assert(#sent == 1 and #pending == 1)
assert(coroutine.resume(co1))
assert(r1 and r1.body == "first")
assert(coroutine.resume(co2))
assert(#sent == 2 and sent[2]:find("/setpoint", 1, true))
pending[1] = { status = 204, body = "second" }
assert(coroutine.resume(co2))
assert(r2 and r2.body == "second")
assert(not s.busy)

-- an error inside a request releases the lock and is raised again
s.wait_response = function() error("boom") end
local ok, err = pcall(s.request, s, "GET", "/x")
assert(not ok and tostring(err):find("boom"))
assert(not s.busy, "lock not released after an error")
return true
'''


def test_requests_serialized_and_lock_released():
    lua = runtime()
    assert lua.execute(LOCK) is True


TLV = rb'''
local tlv = require "tlv8"
assert(tlv.get(nil, 6) == nil)
local hap = require "hap_client"
hap.json = require "st.json"
-- the accessory answers pair-verify with a truncated TLV: an error result, not a Lua error
local reply = "HTTP/1.1 200 OK\r\nContent-Type: application/pairing+tlv8\r\nContent-Length: 1\r\n\r\n\6"
local sock = { send = function(_, d) return #d end,
  receive = function(_, n) if #reply == 0 then return nil, "closed" end
    local d = reply:sub(1, n); reply = reply:sub(n + 1); return d end }
local s = hap.session(sock, {})
local ok, err = s:pair_verify({ accessory_id = "x", accessory_pub = string.rep("\0", 32) })
assert(not ok and tostring(err):find("bad TLV"), tostring(err))
return true
'''


def test_bad_tlv_is_an_error_result():
    lua = runtime()
    assert lua.execute(TLV) is True
