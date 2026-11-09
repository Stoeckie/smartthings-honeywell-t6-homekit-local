"""2026-11-09 audit fixes in init.lua: one poll timer per device, no zombie session after a restart during
connect, a Lua error in session setup or pairing does not leave the connection stuck, pair_fails persists."""
import os
import time

from run_lua import runtime, SRC as _SRC
import test_t6_driver as base

SRC = str(_SRC)
TEST_DIR = os.path.dirname(os.path.abspath(__file__))

SETUP = rb'''
PERSISTED = {}
LOGS = {}
local log = package.loaded["log"]
log.error = function(m) LOGS[#LOGS + 1] = m; print("E " .. m) end
DEV = NEW_DEVICE({ id = "t6", device_network_id = "t6-hap-x", label = "T6",
  preferences = { ipAddress = "127.0.0.1", hapPort = 1 } })
function DEV:set_field(k, v, opts) self.fields[k] = v; if opts and opts.persist then PERSISTED[k] = v end end
TIMERS, CANCELLED, DELAYS = 0, {}, 0
DEV.thread = {
  call_on_schedule = function() TIMERS = TIMERS + 1; return "timer" .. TIMERS end,
  cancel_timer = function(_, t) CANCELLED[#CANCELLED + 1] = t end,
  call_with_delay = function() DELAYS = DELAYS + 1 end }
SOCKS = {}
-- fake TCP socket; CONNECT_HOOK runs during connect, SEND_ERROR makes send raise a Lua error
function py_tcp()
  local s = { sent = 0, closed = false }
  function s:settimeout() end
  function s:connect() if CONNECT_HOOK then local h = CONNECT_HOOK; CONNECT_HOOK = nil; h() end return 1 end
  function s:send(d) if SEND_ERROR then error("boom in send") end self.sent = self.sent + 1; return #d end
  function s:receive() return nil, "closed" end
  function s:close() self.closed = true end
  SOCKS[#SOCKS + 1] = s
  return s
end
PAIRING = { controller_id = "C", controller_seed = string.rep("00", 32), controller_pub = string.rep("00", 32),
  accessory_id = "A", accessory_pub = string.rep("00", 32) }
'''


def setup():
    lua = runtime()
    lua.execute(f'package.path = "{SRC}/?.lua;{TEST_DIR}/?.lua;" .. package.path'.encode())
    g = lua.globals()
    g.py_time = time.time
    lua.execute(base.HARNESS)
    lua.execute(b'dofile("' + SRC.encode() + b'/init.lua")')
    lua.execute(SETUP)
    lua.execute(b'STOP_AFTER_SLEEP = true')  # end each session task at its first reconnect wait
    return lua


def test_one_poll_timer():
    lua = setup()
    lua.execute(b'DEV.fields.hap_pairing = PAIRING')
    lua.execute(b'DRIVER.lifecycle_handlers.init(DRIVER_OBJ, DEV); DRIVER.lifecycle_handlers.added(DRIVER_OBJ, DEV)')
    assert lua.eval(b'TIMERS') == 2
    assert lua.eval(b'#CANCELLED') == 1 and lua.eval(b'CANCELLED[1]') == b"timer1"
    assert lua.eval(b'DEV.fields.poll_timer') == b"timer2"


def test_no_zombie_session_when_restarted_during_connect():
    lua = setup()
    lua.execute(b'''
      DEV.fields.hap_pairing = PAIRING
      CONNECT_HOOK = function() FIRST_C = DRIVER._t6.conns["t6"]; DRIVER.lifecycle_handlers.infoChanged(DRIVER_OBJ, DEV,
        "infoChanged", { old_st_store = { preferences = { ipAddress = "127.0.0.2", hapPort = 1 } } }) end
      DRIVER.lifecycle_handlers.init(DRIVER_OBJ, DEV)''')
    # socket 1 belongs to the replaced session: closed right after connect, nothing sent on it
    assert lua.eval(b'SOCKS[1].closed') is True
    assert lua.eval(b'SOCKS[1].sent') == 0
    assert lua.eval(b'FIRST_C.stopped') is True and lua.eval(b'not FIRST_C.alive') is True
    assert lua.eval(b'DRIVER._t6.conns["t6"] ~= FIRST_C') is True
    assert lua.eval(b'SOCKS[2].sent') > 0  # the new session did its work


def test_lua_error_in_setup_closes_connection():
    lua = setup()
    lua.execute(b'DEV.fields.hap_pairing = PAIRING; SEND_ERROR = true')
    lua.execute(b'DRIVER.lifecycle_handlers.init(DRIVER_OBJ, DEV)')
    c = lua.eval(b'DRIVER._t6.conns["t6"]')
    assert not c[b"alive"] and c[b"sock"] is None
    assert lua.eval(b'SOCKS[1].closed') is True
    assert any(b"session error" in m for m in lua.eval(b'LOGS').values())
    assert lua.eval(b'DEV.state') == b"offline"  # the normal reconnect path ran


def test_lua_error_in_pairing_resets_pairing_flag():
    lua = setup()
    lua.execute(b'SEND_ERROR = true; DRIVER.lifecycle_handlers.init(DRIVER_OBJ, DEV)')
    assert lua.eval(b'DRIVER._t6.conns["t6"].pairing') is False
    assert lua.eval(b'SOCKS[1].closed') is True
    assert lua.eval(b'DELAYS') == 1  # retry scheduled


def test_pair_fails_persisted_across_restart():
    lua = setup()
    lua.execute(b'SEND_ERROR = true; DRIVER.lifecycle_handlers.init(DRIVER_OBJ, DEV)')
    assert lua.eval(b'PERSISTED.pair_fails') == 1
    # a "restart": a fresh driver with the persisted field at 4 -> the 5th failure stops automatic retries
    lua2 = setup()
    lua2.execute(b'DEV.fields.pair_fails = 4; SEND_ERROR = true; DRIVER.lifecycle_handlers.init(DRIVER_OBJ, DEV)')
    assert lua2.eval(b'PERSISTED.pair_fails') == 5
    assert lua2.eval(b'DELAYS') == 0
