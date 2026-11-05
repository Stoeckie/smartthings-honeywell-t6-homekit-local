# Honeywell T6 (HomeKit local): SmartThings Edge driver

Local control of the **Honeywell (Resideo) Lyric T6 / T6R** thermostat in SmartThings. The hub talks to the thermostat directly over **HomeKit** on your own network: no Resideo cloud, no Honeywell account, no Apple device, no bridge computer.

Why: the cloud integration (Honeywell Home / Resideo) runs on Resideo's older Lyric platform and can lose its login while the app keeps working. Over HomeKit the hub does not depend on that.

The complete HomeKit controller (pair setup with SRP-6a, Ed25519, X25519, ChaCha20-Poly1305, TLV8, encrypted sessions and events) is written in pure Lua and runs on the hub. It is the same controller as in [VELUX ACTIVE (HomeKit local)](https://github.com/Stoeckie/smartthings-velux-active-local).

Forum topic: https://community.smartthings.com/t/311952

## What you get

* **Temperature** (the thermostat's own sensor)
* **Heating setpoint**: read and set, rounded to the thermostat's step (0.5 °C)
* **Mode**: off / heat / auto (whatever the thermostat reports as supported)
* **Operating state**: heating or idle, i.e. whether the thermostat itself is calling for heat. Useful in routines ("only raise the setpoint when the thermostat is not heating yet").
* Live updates: the thermostat pushes every change, plus a safety poll every 5 minutes
* **Connection** status (Connected or Offline) and **Last drop**, for offline notifications in routines
* Automatic reconnect
* **Heat demand per room** (optional): a rule tells the thermostat which rooms ask for heat; the setpoint follows the number of rooms (see below)

## Requirements

* SmartThings hub with Edge (v2, v3/Aeotec, Station)
* Honeywell Lyric T6 or T6R with Wi-Fi, on the same network as the hub
* HomeKit active on the thermostat (advanced menu, RESET, HomeKit). The T6 shows a **new 8-digit code on its display** for every pairing attempt; the sticker code does not work.
* The thermostat must **not** be paired with Apple Home or another HomeKit controller (HomeKit accepts one owner). Remove it there first, or reset only HomeKit on the thermostat: advanced menu, RESET, HomeKit. Do not do a factory reset, that also clears your installer settings (OpenTherm etc.).

The Resideo app and the cloud integration keep working next to this driver; you can remove the cloud integration from SmartThings once this one runs.

## Install

1. Enroll your hub in the channel: https://bestow-regional.api.smartthings.com/invite/qWjBdybRNG2y (Stoeckie Edge Drivers) and install **Honeywell T6 (HomeKit local)**.
2. SmartThings app: **Add device → Scan nearby**. A "Honeywell T6" device appears (found via mDNS).
3. The hub starts pairing by itself and the thermostat shows a code. Open the device → Settings → **HomeKit code** and type that code within 5 minutes (digits only or with dashes).
4. Pairing then takes 1 to 2 minutes on the hub (3072-bit SRP in Lua). A wrong code starts a new attempt after 10 s with a new code on the display. Reconnects only take a few seconds.

## Settings

| Setting | Meaning |
|---|---|
| HomeKit code | the 8 digits the thermostat shows while pairing, needed once |
| Thermostat IP | `auto` (mDNS) or a fixed IP |
| HomeKit port | `0` = auto (mDNS); set it together with a fixed IP |
| Setpoint without heat demand | heat demand: setpoint when no room asks for heat (default 19) |
| Extra degrees per room | heat demand: added per room asking for heat (default 0.5) |
| Remove pairing | Unpairs the hub from the thermostat, e.g. before re-pairing |

Give the thermostat a DHCP reservation in your router; the driver also follows a new IP via mDNS.

## Heat demand per room (zone control)

Useful when the T6 is the only thermostat that talks to the boiler (e.g. OpenTherm) and other rooms have their own radiator or floor heating thermostats in SmartThings.

The device has a capability **Heat Demand** with the command `setRoom(room, "on"/"off")`. Make a rule that sends, per room, `on` when its temperature is below its setpoint and `off` otherwise. With N rooms asking for heat the driver sets the T6 to its own temperature rounded up to 0.5 °C plus 0.5 °C per room (setting "Extra degrees per room"), and keeps following the T6 temperature. When no room asks any more, the setpoint goes back to "Setpoint without heat demand" (default 19 °C). The device shows which rooms ask for heat; `clearRooms` resets the list. When the T6 mode is off the driver leaves it alone.

Example rule action per room (Rules API):

```json
{"if": {"lessThan": {
   "left":  {"device": {"devices": ["<room>"], "component": "main", "capability": "temperatureMeasurement", "attribute": "temperature", "trigger": "Always"}},
   "right": {"device": {"devices": ["<room>"], "component": "main", "capability": "thermostatHeatingSetpoint", "attribute": "heatingSetpoint", "trigger": "Always"}}}},
 "then": [{"command": {"devices": ["<t6>"], "commands": [{"component": "main", "capability": "silvervalley08660.heatDemand", "command": "setRoom", "arguments": [{"string": "Kitchen"}, {"string": "on"}]}]}}],
 "else": [{"command": {"devices": ["<t6>"], "commands": [{"component": "main", "capability": "silvervalley08660.heatDemand", "command": "setRoom", "arguments": [{"string": "Kitchen"}, {"string": "off"}]}]}}]}
```

## Offline notification

SmartThings has no routine trigger for "device offline". Make a routine: if Honeywell T6 > Connection is Offline, send a notification. Connection only turns Offline after 2 minutes without a connection; every drop is shown afterwards as **Last drop** (time UTC, duration, reason).

## Troubleshooting

* **Not found by Scan nearby**: check that the thermostat is on Wi-Fi (Resideo app works) and in the same subnet as the hub. A device "Honeywell T6" is created anyway; set IP and port by hand.
* **"HomeKit error 2"**: wrong code (use the code on the display, not the sticker). **"HomeKit error 6"**: already paired with another controller (Apple Home): remove it there or reset HomeKit on the thermostat.
* Logs: `smartthings edge:drivers:logcat <driverId> --hub-address <hub-ip>`, lines start with `[t6]`. After pairing the log shows model, firmware, supported modes and setpoint range.

## Privacy

The HomeKit code is a device setting. The pairing keys are stored on the hub as device fields. Nothing secret is in this code or the package.

## Development

```
smartthings edge:drivers:package .
python3 -m pytest tests          # needs: pip install lupa pytest HAP-python
python3 tools/pair_test.py IP PORT 12345678   # pair from a PC, dump accessories, unpair
```

`tests/test_t6_driver.py` runs the whole driver (pairing, session, events) against a HAP-python thermostat on localhost.

Files:

* `src/init.lua`: driver (discovery, pairing, session, commands)
* `src/t6_model.lua`: maps the HomeKit Thermostat service to SmartThings
* `src/hap_client.lua`: HomeKit (HAP over IP) controller
* `src/srp.lua`, `src/bignum.lua`, `src/curve25519.lua`, `src/chacha20poly1305.lua`, `src/sha512.lua`, `src/tlv8.lua`: crypto

Not affiliated with Honeywell or Resideo. Apache 2.0.
