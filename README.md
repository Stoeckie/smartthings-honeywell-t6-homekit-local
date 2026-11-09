# Honeywell T6 (HomeKit local): SmartThings Edge driver

Local control of the **Honeywell (Resideo) Lyric T6 / T6R** thermostat in SmartThings. The hub talks to the thermostat directly over **HomeKit** on your own network: no Resideo cloud, no Honeywell account, no Apple device, no bridge computer.

Why: the cloud integration (Honeywell Home / Resideo) runs on Resideo's older Lyric platform and can lose its login while the app keeps working. Over HomeKit the hub does not depend on that.

The complete HomeKit controller (pair setup with SRP-6a, Ed25519, X25519, ChaCha20-Poly1305, TLV8, encrypted sessions and events) is written in pure Lua and runs on the hub. It is the same controller as in [VELUX ACTIVE (HomeKit local)](https://github.com/Stoeckie/smartthings-velux-active-local).

Forum topic: https://community.smartthings.com/t/311952

## What you get

* **Temperature** (the thermostat's own sensor)
* **Heating setpoint**: read and set, rounded to the thermostat's step (0.5 °C). With a SmartThings location in Fahrenheit the app shows °F; a setpoint sent in °F is converted to °C
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
| Setpoint without heat demand | heat demand: setpoint in °C when no room asks for heat (default 19; a value above 40 is read as °F, e.g. 66) |
| Extra degrees per room | heat demand: °C added per room asking for heat (default 0.5 °C, about 1 °F) |
| Remove pairing | Unpairs the hub from the thermostat, e.g. before re-pairing |

Give the thermostat a DHCP reservation in your router; the driver also follows a new IP via mDNS.

## Heat demand per room (zone control)

Optional, for setups where the T6 is the only thermostat that talks to the boiler (e.g. OpenTherm) and the rooms have their own radiator or floor heating thermostats in SmartThings. **Without a heat demand rule nothing changes**: the driver only starts doing this after it has received its first `setRoom` command.

How it works: a rule tells the T6 per room whether that room asks for heat (temperature below its own setpoint). With N rooms asking, the driver sets the T6 to its own temperature rounded up to 0.5 °C plus 0.5 °C per room, and follows the T6 temperature upwards (it only goes down when fewer rooms ask, so the T6's 0.5 °C flicker does not flip the setpoint). When the last room stops asking, the setpoint goes back to "Setpoint without heat demand" (default 19 °C); after that a manual setpoint is left alone. The device shows which rooms ask for heat. When the T6 mode is off the driver leaves it alone.

**Choosing the rooms.** The SmartThings app cannot compare a temperature with a setpoint, so this needs a rule (Rules API). The script `tools/heat-demand-rule.ps1` makes it for you on Windows, with the [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli) logged in:

```
powershell -ExecutionPolicy Bypass -File heat-demand-rule.ps1
```

It lists every device in the T6's location that has a temperature and a heating setpoint (radiator valves, floor heating thermostats), you type the numbers of the rooms that count, and it creates or updates the rule "Heat demand (Honeywell T6)". Run it again to change the rooms. Options: `-RoomIds "<id>,<id>"` (no questions), `-RuleName "..."`, `-DryRun` (only writes the JSON), `-Cli "C:\Program Files\SmartThings\smartthings.exe"`.

To stop: delete the rule (`smartthings rules:delete <ruleId>`) and send `clearRooms` to the T6 (or just delete the rule; with no room asking the setpoint returns to the idle value once and is then left alone).

A complete example of the rule (my own setup with placeholder IDs) and the logic step by step: [examples/](examples/). The rule per room looks like this:

```json
{"if": {"lessThan": {
   "left":  {"device": {"devices": ["<room>"], "component": "main", "capability": "temperatureMeasurement", "attribute": "temperature", "trigger": "Always"}},
   "right": {"device": {"devices": ["<room>"], "component": "main", "capability": "thermostatHeatingSetpoint", "attribute": "heatingSetpoint", "trigger": "Always"}}},
 "then": [{"command": {"devices": ["<t6>"], "commands": [{"component": "main", "capability": "silvervalley08660.heatDemand", "command": "setRoom", "arguments": [{"string": "Kitchen"}, {"string": "on"}]}]}}],
 "else": [{"command": {"devices": ["<t6>"], "commands": [{"component": "main", "capability": "silvervalley08660.heatDemand", "command": "setRoom", "arguments": [{"string": "Kitchen"}, {"string": "off"}]}]}}]}}
```

## Offline and online notification

SmartThings has no routine trigger for "device offline". Make a routine: if Honeywell T6 > Connection is Offline, send a notification. Connection only turns Offline after **Offline after (minutes)** without a connection (setting, default 5, so a router update at night gives no notification); every drop is shown afterwards as **Last drop** (time UTC, duration, reason). Tip: duplicate that routine and change the condition to Connection is Connected to also get a "back online" notification.

## Events

A value only goes to the hub when it changed. After a driver start every value is sent once so the app catches up on anything it missed. (Re-emitting unchanged values makes the hub drop events of a device, and the app then keeps a stale value.)

## Troubleshooting

* **Not found by Scan nearby**: check that the thermostat is on Wi-Fi (Resideo app works) and in the same subnet as the hub. A device "Honeywell T6" is created anyway; set IP and port by hand.
* **"HomeKit error 2"**: wrong code (use the code on the display, not the sticker). **"HomeKit error 6"**: already paired with another controller (Apple Home): remove it there or reset HomeKit on the thermostat.
* Logs: `smartthings edge:drivers:logcat <driverId> --hub-address <hub-ip>`, lines start with `[t6]`. After pairing the log shows model, firmware, supported modes and setpoint range.

## Keys

The driver makes its HomeKit keys itself. The hub offers drivers no secure random source, and the clock plus `math.random` hold far too little randomness for a key, so from build 2026-11-09 the keys come from `rng.lua`: `/dev/urandom` where the hub allows it, plus timing jitter of the CPU, collected in a pool that is kept across restarts. Pairings made with an older build keep working; to get a new long-term key, remove the device, reset the HomeKit pairing and add it again (not required).

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
