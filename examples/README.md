# Heat demand rule (example)

`heat-demand-rule.example.json` is the rule that runs in my own home (one T6 on the boiler, two floor heating thermostats and four radiator valves), with the device IDs replaced by placeholders and generic room names.

The logic, per room thermostat:

* **if** its temperature is below its own heating setpoint **then** send `setRoom("<name>", "on")` to the T6
* **else** send `setRoom("<name>", "off")`

`"trigger": "Always"` on both sides makes the rule run on every temperature or setpoint change of that room. A plain `lessThan` condition is evaluated on every event, so the T6 gets `on` or `off` for that room each time (see the [Rules API documentation](https://developer.smartthings.com/docs/automations/rules); wrapping it in `changes` would only fire on the transition). The driver ignores repeats and remembers the list.

The driver then sets the T6 to its own temperature rounded up to 0.5 °C plus 0.5 °C per room asking (setting "Extra degrees per room"), and back to "Setpoint without heat demand" (19 °C) when no room asks any more.

Use it:

1. Replace the placeholders with your device IDs (`smartthings devices`) and the names with your own. Each thermostat needs its own unique name; two devices in one room count twice.
2. `smartthings rules:create -i heat-demand-rule.example.json --location <locationId>`

Or let `tools/heat-demand-rule.ps1` build the same rule for you from a list of your devices.
