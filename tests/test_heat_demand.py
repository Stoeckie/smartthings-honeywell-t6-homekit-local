"""Heat demand: setRoom per room from a rule -> setpoint = temperature rounded up to 0.5 + 0.5 per room,
back to idleSetpoint when no room asks for heat. Runs init.lua with a fake HAP session."""
import os
from run_lua import runtime, SRC as _SRC
import test_t6_driver as base

SRC = str(_SRC)
TEST_DIR = os.path.dirname(os.path.abspath(__file__))

SETUP = rb'''
WRITES = {}
DEV = NEW_DEVICE({ id = "t6", device_network_id = "t6-hap-x", label = "T6",
  preferences = { idleSetpoint = 19, stepPerRoom = 0.5 } })
DEV.thread.call_with_delay = function(_, s, fn) fn() end
local conns = DRIVER._t6.conns
conns["t6"] = { alive = true, responses = {}, model = { aid = 1,
  values = { tgt_state = 1, cur_temp = 19.3, tgt_temp = 19.5 },
  chars = { tgt_temp = 14 }, meta = { tgt_temp = { min = 5, max = 30, step = 0.5 } },
  index = { ["1.14"] = "tgt_temp" } },
  session = { put = function(self, list) WRITES[#WRITES + 1] = list[1].value; return true end } }
function ROOM(name, demand)
  DRIVER.capability_handlers[DRIVER_ID].setRoom(DRIVER_OBJ, DEV, { args = { room = name, demand = demand } })
  return conns["t6"].model.values.tgt_temp
end
function SET(field, v) conns["t6"].model.values[field] = v end
'''

def setup():
    lua = runtime()
    lua.execute(f'package.path = "{SRC}/?.lua;{TEST_DIR}/?.lua;" .. package.path'.encode())
    g = lua.globals()
    g.py_time = __import__("time").time
    lua.execute(base.HARNESS)
    lua.execute(b'dofile("' + SRC.encode() + b'/init.lua")')
    lua.execute(b'for k, v in pairs(DRIVER.capability_handlers) do if v.setRoom then DRIVER_ID = k end end')
    lua.execute(SETUP)
    return lua, g

def test_rooms_add_and_remove():
    lua, g = setup()
    room = g.ROOM
    assert room(b"Keuken", b"on") == 20.0          # 19.3 -> 19.5 + 0.5
    assert room(b"Keuken", b"on") == 20.0          # repeat: no change
    assert room(b"Noi", b"on") == 20.5             # 2 rooms
    assert room(b"DJ", b"on") == 21.0              # 3 rooms
    assert room(b"DJ", b"off") == 20.5
    g.SET(b"cur_temp", 20.2)                       # kitchen warms up: follow the temperature
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    assert lua.eval(b'DRIVER._t6.conns["t6"].model.values.tgt_temp') == 21.5   # 20.5 + 2 x 0.5
    assert room(b"Keuken", b"off") == 21.0
    assert room(b"Noi", b"off") == 19                # nobody asks: idle setpoint
    g.SET(b"tgt_temp", 21)                           # manual change while no room asks: left alone
    g.SET(b"cur_temp", 19.0)
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    assert lua.eval(b'DRIVER._t6.conns["t6"].model.values.tgt_temp') == 21
    events = [e[b"path"] for e in g.DEV[b"events"].values()]
    assert any(p.endswith(b"heatDemand.rooms") for p in events), events

def test_thermostat_off_untouched():
    lua, g = setup()
    g.SET(b"tgt_state", 0)
    assert g.ROOM(b"Keuken", b"on") == 19.5
    assert len(g.WRITES) == 0

def test_inactive_without_rule():
    """Users without a heat demand rule: the driver never changes the setpoint."""
    lua, g = setup()
    g.SET(b"tgt_temp", 22)
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    assert len(g.WRITES) == 0
    assert lua.eval(b'DRIVER._t6.conns["t6"].model.values.tgt_temp') == 22
