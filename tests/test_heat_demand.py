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

def test_active_from_stored_rooms():
    """After a driver update the rule sends nothing until a room changes: stored rooms keep it active."""
    lua, g = setup()
    lua.execute(b'DEV.fields.heat_rooms = { Keuken = true }; DEV.fields.demand_last_n = 1')
    g.SET(b"cur_temp", 20.5)
    g.SET(b"tgt_temp", 20.0)
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    assert lua.eval(b'DRIVER._t6.conns["t6"].model.values.tgt_temp') == 21.0

def test_temperature_flicker_does_not_flip_setpoint():
    lua, g = setup()
    g.SET(b"cur_temp", 21.0)
    assert g.ROOM(b"Keuken", b"on") == 21.5
    g.SET(b"cur_temp", 20.5)                       # T6 flips down half a degree
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    assert lua.eval(b'DRIVER._t6.conns["t6"].model.values.tgt_temp') == 21.5
    g.SET(b"cur_temp", 21.5)                       # and up again: follow upwards
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    assert lua.eval(b'DRIVER._t6.conns["t6"].model.values.tgt_temp') == 22.0

def test_failed_write_is_retried_after_reconnect():
    """'No room asks' while the T6 closes its session: the write fails; after the reconnect the driver
    must still go back to the idle setpoint (before, the boiler kept heating on the old setpoint)."""
    lua, g = setup()
    assert g.ROOM(b"Noi", b"on") == 20.0
    lua.execute(b'''
      local c = DRIVER._t6.conns["t6"]
      FAILPUT = c.session.put
      c.session.put = function(self, list) return nil, "closed" end''')
    assert g.ROOM(b"Noi", b"off") == 20.0          # write failed: still 20
    lua.execute(b'DRIVER._t6.conns["t6"].session.put = FAILPUT')
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')   # what the reconnect does
    assert lua.eval(b'DRIVER._t6.conns["t6"].model.values.tgt_temp') == 19


# Fahrenheit locations ------------------------------------------------------------------------------
SETPOINT = rb'''
function SETPOINT_CMD(v)
  for _, fn in pairs(DRIVER.capability_handlers["thermostatHeatingSetpoint"]) do
    fn(DRIVER_OBJ, DEV, { args = { setpoint = v } })
  end
  return DRIVER._t6.conns["t6"].model.values.tgt_temp
end
'''

def test_setpoint_command_celsius_and_fahrenheit():
    """A location set to Fahrenheit sends the setpoint in °F: 68 must become 20 °C, not 68 (clamped to 30)."""
    lua, g = setup()
    lua.execute(SETPOINT)
    assert g.SETPOINT_CMD(21.3) == 21.5            # °C, rounded to the 0.5 step
    assert g.SETPOINT_CMD(68) == 20.0              # 68 °F
    assert g.SETPOINT_CMD(70) == 21.0              # 21.1 °C -> 21.0
    assert g.SETPOINT_CMD(40) == 30                # 40 is still °C (clamped to the device maximum)
    assert list(g.WRITES.values()) == [21.5, 20.0, 21.0, 30]
    sp = [e[b"arg"] for e in g.DEV[b"events"].values() if e[b"path"].endswith(b"heatingSetpoint")]
    assert all(a[b"unit"] == b"C" for a in sp), sp

def test_idle_setpoint_in_fahrenheit():
    """idleSetpoint is °C; a value above 40 (a US user typing 66) is read as °F: 66 °F = 18.9 -> 19.0 °C."""
    lua, g = setup()
    lua.execute(b'DEV.preferences.idleSetpoint = 66')
    assert g.ROOM(b"Keuken", b"on") == 20.0
    assert g.ROOM(b"Keuken", b"off") == 19.0

def test_to_celsius():
    lua, g = setup()
    m = lua.eval(b'require "t6_model"')
    assert m.to_celsius(20) == 20
    assert m.to_celsius(40) == 40
    assert abs(m.to_celsius(68) - 20) < 1e-9
    assert m.to_celsius(b"abc") is None


def test_lowered_by_hand_pauses_the_rooms():
    # DS 15-11: lower the T6 while rooms ask -> those rooms are ignored instead of the setpoint going back up
    lua, g = setup()
    lua.execute(SETPOINT)
    room = g.ROOM
    assert room(b"Noi", b"on") == 20.0
    assert room(b"Liselot", b"on") == 20.5
    g.SETPOINT_CMD(18)
    sp = lambda: lua.eval(b'DRIVER._t6.conns["t6"].model.values.tgt_temp')
    assert sp() == 18
    g.SET(b"cur_temp", 19.0)
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    assert sp() == 18                              # not back up, and not replaced by the idle setpoint
    summ = [e[b"arg"] for e in g.DEV[b"events"].values() if e[b"path"].endswith(b"heatDemand.summary")]
    assert summ[-1] == b"none; paused: Liselot, Noi", summ
    assert room(b"DJ", b"on") == 19.5              # a room that asks later counts: 19.0 + 0.5
    assert room(b"Noi", b"off") == 19.5 and room(b"Noi", b"on") == 20.0   # asked again: counts again
    # raised by hand: heat is wanted, the remaining pause ends
    g.SETPOINT_CMD(22)
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    summ = [e[b"arg"] for e in g.DEV[b"events"].values() if e[b"path"].endswith(b"heatDemand.summary")]
    assert summ[-1] == b"DJ, Liselot, Noi", summ


def test_pause_ends_after_pause_minutes():
    lua, g = setup()
    lua.execute(SETPOINT)
    room = g.ROOM
    assert room(b"Keuken", b"on") == 20.0
    g.SETPOINT_CMD(18)
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    sp = lambda: lua.eval(b'DRIVER._t6.conns["t6"].model.values.tgt_temp')
    assert sp() == 18
    lua.execute(b'local p = DEV:get_field("heat_paused"); p.Keuken = 1; DEV:set_field("heat_paused", p)')
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    assert sp() == 20.0


def test_lowered_on_the_thermostat_during_a_drop_pauses_the_rooms():
    # DS 17-11: the T6 closes its session when it is operated; after the reconnect the driver read 19.5 and
    # wrote the heat demand setpoint back 2 s later. The change during the drop now counts as a change by hand.
    lua, g = setup()
    room = g.ROOM
    assert room(b"Keuken", b"on") == 20.0
    sp = lambda: lua.eval(b'DRIVER._t6.conns["t6"].model.values.tgt_temp')
    g.SET(b"tgt_temp", 18.5)                         # what the fresh model holds after the reconnect
    lua.execute(b'DRIVER._t6.setpoint_after_reconnect(DEV, 20.0, 18.5)')
    lua.execute(b'DRIVER._t6.apply_demand(DEV)')
    assert sp() == 18.5
    summ = [e[b"arg"] for e in g.DEV[b"events"].values() if e[b"path"].endswith(b"heatDemand.summary")]
    assert summ[-1] == b"none; paused: Keuken", summ
    lua.execute(b'DRIVER._t6.setpoint_after_reconnect(DEV, 18.5, 18.5)')   # nothing changed: no effect
    lua.execute(b'DRIVER._t6.setpoint_after_reconnect(DEV, nil, 18.5)')    # first connect: no effect
    assert sp() == 18.5


# a fake HomeKit session, so session_once runs as on the hub: connect, read the thermostat, then the drop
SESSION = rb'''
local hap = require "hap_client"
C = DRIVER._t6.conns["t6"]
TGT, CUR = 19.5, 19.3
FAKE = {}
function FAKE.pair_verify() return true end
function FAKE.accessories() return { { aid = 1, services = { { type = "4A", characteristics = {
  { type = "F", iid = 10, value = 0 }, { type = "33", iid = 11, value = 1 },
  { type = "11", iid = 12, value = CUR },
  { type = "35", iid = 14, value = TGT, minValue = 5, maxValue = 30, minStep = 0.5 } } } } } } end
function FAKE.subscribe() return true end
function FAKE.read_message() return nil, "closed" end
function FAKE.put(self, list) WRITES[#WRITES + 1] = list[1].value; TGT = list[1].value; return {} end
hap.session = function() return FAKE end
-- one session: connect, read the thermostat (tgt = what it shows now), run until it closes
function UP(tgt, cur)
  if tgt then TGT = tgt end
  if cur then CUR = cur end
  local reason = DRIVER._t6.session_once(DEV, C, { settimeout = function() end, close = function() end }, {})
  C.alive = false
  return reason
end
-- the next heat demand write reaches the thermostat, but the session closes before the answer
function UNANSWERED()
  local put = FAKE.put
  FAKE.put = function(self, list)
    FAKE.put = put
    TGT = list[1].value
    C.alive = false
    return nil, "connection closed"
  end
end
function SUMMARY()
  local last
  for _, e in ipairs(DEV.events) do if e.path:find("heatDemand.summary", 1, true) then last = e.arg end end
  return last
end
'''


def session_setup():
    lua, g = setup()
    lua.execute(SESSION)
    assert g.UP(19.5, 19.3) == b"session closed: closed"
    lua.execute(b"C.alive = true")                   # connected again, nothing changed meanwhile
    return lua, g


def test_own_write_applied_before_a_drop_is_not_a_change_by_hand():
    # Fewer rooms ask, so the driver lowers the setpoint. The T6 applies it and closes the session before it
    # answers. After the reconnect the lower setpoint must not pause the room that still asks.
    lua, g = session_setup()
    room = g.ROOM
    assert room(b"Keuken", b"on") == 20.0
    assert room(b"Noi", b"on") == 20.5
    g.UNANSWERED()
    assert room(b"Noi", b"off") == 20.5              # no answer: the driver still believes 20.5
    assert lua.eval(b"C.own_sp") == 20.0 and lua.eval(b"TGT") == 20.0
    assert g.UP() == b"session closed: closed"       # reconnect: the thermostat shows 20.0
    assert g.SUMMARY() == b"Keuken"
    assert lua.eval(b"C.own_sp") is None
    assert lua.eval(b"C.model.values.tgt_temp") == 20.0
    assert lua.eval(b'DEV:get_field("demand_last_n")') == 1


def test_lowered_by_hand_during_a_drop_with_the_real_session_code():
    lua, g = session_setup()
    assert g.ROOM(b"Keuken", b"on") == 20.0
    lua.execute(b"C.alive = false")
    writes = len(g.WRITES)
    g.UP(18.5)                                       # lowered on the thermostat while disconnected
    assert g.SUMMARY() == b"none; paused: Keuken"
    assert len(g.WRITES) == writes and lua.eval(b"TGT") == 18.5   # not written back
    g.UP(22.0)                                       # raised on the thermostat during the next drop
    assert g.SUMMARY() == b"Keuken"
    assert lua.eval(b"TGT") == 22.0                  # higher than the heat demand asks: left alone


def test_unanswered_write_followed_by_a_change_by_hand():
    # the unanswered write is only excused when the thermostat shows exactly that setpoint afterwards
    lua, g = session_setup()
    room = g.ROOM
    assert room(b"Keuken", b"on") == 20.0
    assert room(b"Noi", b"on") == 20.5
    g.UNANSWERED()
    room(b"Noi", b"off")
    g.UP(17.0)                                       # and then lowered by hand to 17 during the drop
    assert g.SUMMARY() == b"none; paused: Keuken"
    assert lua.eval(b"TGT") == 17.0


def test_refused_write_leaves_nothing_pending():
    lua, g = session_setup()
    lua.execute(b'FAKE.put = function() return nil, "HTTP 400" end')
    assert g.ROOM(b"Keuken", b"on") == 19.5          # refused, the session stays up
    assert lua.eval(b"C.own_sp") is None


def test_poll_sees_a_setpoint_change_that_came_without_an_event():
    lua, g = session_setup()
    assert g.ROOM(b"Keuken", b"on") == 20.0
    lua.execute(b"FAKE.get = function() return { { aid = 1, iid = 14, value = 18.0 } } end")
    lua.execute(b"DRIVER._t6.poll(DEV)")
    assert g.SUMMARY() == b"none; paused: Keuken"
    lua.execute(b"DRIVER._t6.apply_demand(DEV)")
    assert lua.eval(b"C.model.values.tgt_temp") == 18.0


def test_setpoint_command_compares_with_the_setpoint_at_the_answer():
    # a heat demand write finished while the setpoint command waited for its turn: 22 -> 21 is lower, not higher
    lua, g = session_setup()
    lua.execute(SETPOINT)
    assert g.ROOM(b"Keuken", b"on") == 20.0
    lua.execute(b'''
      local put = FAKE.put
      FAKE.put = function(self, list) FAKE.put = put; C.model.values.tgt_temp = 22.0; return put(self, list) end''')
    assert g.SETPOINT_CMD(21) == 21
    assert g.SUMMARY() == b"none; paused: Keuken"


def test_keepalive_asks_when_nothing_came_in():
    # 17-11: the T6 drops its session without telling when it changes access point; the hub then hears nothing
    # until it sends something. A quiet minute is enough to ask; a session that just spoke is left alone.
    lua, g = session_setup()
    lua.execute(b"GETS = 0; FAKE.get = function() GETS = GETS + 1; return { { aid = 1, iid = 12, value = 19.3 } } end")
    idle = lua.eval(b"DRIVER._t6.IDLE_POLL")
    assert idle <= 120
    lua.execute(b"C.last_rx = py_time()")
    lua.execute(b"DRIVER._t6.poll(DEV, true)")
    assert lua.eval(b"GETS") == 0                    # something came in just now
    lua.execute(b"C.last_rx = py_time() - DRIVER._t6.IDLE_POLL - 1")
    lua.execute(b"DRIVER._t6.poll(DEV, true)")
    assert lua.eval(b"GETS") == 1
    lua.execute(b"DRIVER._t6.poll(DEV)")             # refresh from the app: always
    assert lua.eval(b"GETS") == 2


def test_poll_also_looks_at_the_heat_demand():
    # a pause that ran out is noticed at the next poll, not only when the thermostat happens to send something
    lua, g = session_setup()
    lua.execute(SETPOINT)
    assert g.ROOM(b"Keuken", b"on") == 20.0
    g.SETPOINT_CMD(18)                               # lowered by hand: the kitchen is paused
    assert g.SUMMARY() == b"none; paused: Keuken"
    lua.execute(b'local p = DEV:get_field("heat_paused"); p.Keuken = 1; DEV:set_field("heat_paused", p)')
    lua.execute(b"FAKE.get = function() return { { aid = 1, iid = 12, value = 19.3 } } end")
    lua.execute(b"DRIVER._t6.poll(DEV)")
    assert g.SUMMARY() == b"Keuken"
    assert lua.eval(b"C.model.values.tgt_temp") == 20.0
