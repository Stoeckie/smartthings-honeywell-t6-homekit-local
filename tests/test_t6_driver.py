"""Run the T6 Edge driver (init.lua) with a mocked SmartThings runtime against a HAP-python Thermostat
accessory: manual address, pairing via the HomeKit code preference, session setup, initial state."""
import asyncio
import os
import socket
import tempfile
import threading
import time

import pytest
from pyhap.accessory import Accessory
from pyhap.accessory_driver import AccessoryDriver
from pyhap.const import CATEGORY_THERMOSTAT

from run_lua import runtime, SRC as _SRC

SRC = str(_SRC)
TEST_DIR = os.path.dirname(os.path.abspath(__file__))
PIN = b"031-45-154"  # HomeKit example code


class Thermo(Accessory):
    category = CATEGORY_THERMOSTAT

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        svc = self.add_preload_service("Thermostat")
        self.cur_state = svc.configure_char("CurrentHeatingCoolingState", value=1)
        self.tgt_state = svc.configure_char("TargetHeatingCoolingState", value=1,
                                            valid_values={"Off": 0, "Heat": 1, "Auto": 3})
        self.cur_temp = svc.configure_char("CurrentTemperature", value=20.4)
        self.tgt_temp = svc.configure_char("TargetTemperature", value=19.5,
                                           properties={"minValue": 5, "maxValue": 30, "minStep": 0.5})
        svc.configure_char("TemperatureDisplayUnits", value=0)


@pytest.fixture(scope="module")
def accessory():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    tmp = tempfile.mkdtemp()
    loop = asyncio.new_event_loop()
    holder = {}

    def run():
        asyncio.set_event_loop(loop)
        drv = AccessoryDriver(port=port, persist_file=os.path.join(tmp, "acc.state"), pincode=PIN,
                              loop=loop, address="127.0.0.1", listen_address="127.0.0.1",
                              advertised_address="127.0.0.1")
        th = Thermo(drv, "Lyric-TEST")
        drv.add_accessory(th)
        holder["drv"], holder["thermo"], holder["port"] = drv, th, port
        drv.start()

    t = threading.Thread(target=run, daemon=True)
    t.start()
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            break
        except OSError:
            time.sleep(0.1)
    yield holder
    loop.call_soon_threadsafe(loop.stop)


HARNESS = rb'''
EVENTS = {}
local function capmock(path)
  return setmetatable({}, {
    __index = function(t, k) local v = capmock(path .. "." .. k); rawset(t, k, v); return v end,
    __call = function(_, arg) return { path = path, arg = arg } end })
end
local caps = capmock("cap")
caps.thermostatHeatingSetpoint.ID = "thermostatHeatingSetpoint"
caps.thermostatMode.ID = "thermostatMode"
caps.refresh.ID = "refresh"
package.loaded["st.capabilities"] = caps
package.loaded["st.driver"] = function(name, tmpl) DRIVER = tmpl; return { run = function() end } end
package.loaded["log"] = { info = function(m) print("I " .. m) end, warn = function(m) print("W " .. m) end,
                          error = function(m) print("E " .. m) end, debug = function() end }
STOP_AFTER_SLEEP = false
local socketlib = { gettime = function() return py_time() end,
  sleep = function(s) if SLEEP_HOOK then SLEEP_HOOK() end
    if s > 1 and STOP_AFTER_SLEEP then error("STOP") end end,
  tcp = function() return py_tcp() end }
package.loaded["cosock"] = { socket = socketlib, spawn = function(fn, name)
  local ok, err = pcall(fn); if not ok and not tostring(err):find("STOP") then print("task " .. tostring(name) .. " error: " .. tostring(err)) end end }
package.loaded["st.json"] = require "st.json"

DEVICES = {}
local function new_device(info)
  local d = { id = info.id or ("dev" .. (#DEVICES + 1)), fields = {}, preferences = info.preferences or {},
              device_network_id = info.device_network_id, parent_device_id = info.parent_device_id,
              parent_assigned_child_key = info.parent_assigned_child_key, label = info.label,
              profile = info.profile, events = {}, state = "online" }
  function d:get_field(k) local v = self.fields[k]; if v == nil then return end; return v end -- like the hub: nothing, not nil
  function d:set_field(k, v) self.fields[k] = v end
  function d:emit_event(e) self.events[#self.events + 1] = e end
  function d:online() self.state = "online" end
  function d:offline() self.state = "offline" end
  function d:supports_capability() return true end
  function d:get_parent_device() for _, p in ipairs(DEVICES) do if p.id == self.parent_device_id then return p end end end
  d.thread = { call_on_schedule = function() end, call_with_delay = function() end }
  DEVICES[#DEVICES + 1] = d
  return d
end
DRIVER_OBJ = { get_devices = function() return DEVICES end,
  try_create_device = function(self, info) local d = new_device(info); CREATED = (CREATED or 0) + 1 end }
NEW_DEVICE = new_device
'''


class PySock:
    def __init__(self):
        self.s = None

    def settimeout(self, t):
        self._t = t
        if self.s:
            self.s.settimeout(3 if t is None else min(t, 5))

    def connect(self, ip, port):
        self.s = socket.create_connection((ip.decode(), int(port)), timeout=5)
        return 1

    def send(self, data):
        self.s.sendall(data)
        return len(data)

    def receive(self, n):
        try:
            d = self.s.recv(int(n))
        except socket.timeout:
            self.timeouts = getattr(self, "timeouts", 0) + 1
            if self.timeouts > 3:  # the reader loop now waits on idle timeouts: end the test session
                raise RuntimeError("STOP idle")
            return None, b"timeout"
        self.timeouts = 0
        if not d:
            return None, b"closed"
        return d

    def close(self):
        if self.s:
            self.s.close()



def test_driver_end_to_end(accessory):
    PORT = accessory["port"]
    lua = runtime()
    lua.execute(f'package.path = "{SRC}/?.lua;{TEST_DIR}/?.lua;" .. package.path'.encode())
    g = lua.globals()
    g.py_time = time.time
    g.py_tcp = PySock
    lua.execute(HARNESS)
    lua.execute(b'dofile("' + SRC.encode() + b'/init.lua")')
    hap = lua.execute(b'return require "hap_client"')
    hap.random_bytes = lambda n: os.urandom(int(n))
    lua.execute(b'STOP_AFTER_SLEEP = true')

    dev = lua.eval(b"NEW_DEVICE")(lua.table_from({
        b"id": b"t6", b"device_network_id": b"t6-hap-manual", b"label": b"Honeywell T6",
        b"preferences": lua.table_from({b"homekitCode": b"", b"ipAddress": b"127.0.0.1",
                                        b"hapPort": PORT})}))
    drv = lua.eval(b"DRIVER")
    # the T6 shows its code only after pairing has started: the user types it while the hub waits
    g.TYPED_CODE = PIN.replace(b"-", b"")
    lua.execute(b"""
      SLEEP_HOOK = function()
        local d = DEVICES[1]
        if d.preferences.homekitCode == "" then
          d.preferences.homekitCode = TYPED_CODE
          DRIVER.lifecycle_handlers.infoChanged(DRIVER_OBJ, d, "infoChanged",
            { old_st_store = { preferences = { homekitCode = "" } } })
        end
      end""")
    t0 = time.time()
    drv[b"lifecycle_handlers"][b"added"](lua.eval(b"DRIVER_OBJ"), dev)  # pairs, then runs the session
    print(f"pair+session {time.time() - t0:.1f}s")
    assert dev[b"fields"][b"hap_pairing"] is not None, "not paired"
    evs = [(e[b"path"], e[b"arg"]) for e in dev[b"events"].values()]
    paths = [p for p, _ in evs]
    assert any(p.endswith(b"temperatureMeasurement.temperature") for p in paths), paths
    assert any(p.endswith(b"thermostatHeatingSetpoint.heatingSetpoint") for p in paths), paths
    assert any(p.endswith(b"thermostatMode.thermostatMode.heat") for p in paths), paths
    assert any(p.endswith(b"thermostatOperatingState.thermostatOperatingState.heating") for p in paths), paths
    temp = [a for p, a in evs if p.endswith(b"temperatureMeasurement.temperature")][0]
    assert temp[b"value"] == 20.4
    assert temp[b"unit"] == b"C"  # the app converts to °F only when the unit is given
    rng = [a for p, a in evs if p.endswith(b"heatingSetpointRange")]
    assert rng and rng[0][b"unit"] == b"C", rng
