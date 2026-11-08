-- emitq: emit a capability event only when its value changed.
--
-- Why: a driver that re-emits every value on every poll floods the hub (one bridge did about 6 events a second);
-- the hub then drops events of that device and the app keeps a stale value. SmartThings asks for about one event
-- a minute per device outside real changes, and allows about 12 state events a minute per device.
--
-- The hub itself drops an event whose value it already has, so a value the cloud missed would stay wrong for ever.
-- Therefore the first emit of every attribute after a driver start carries state_change = true, which the hub
-- always passes on. An optional periodic resend (seconds; 0 = off) does the same later; note that a forced event
-- also fires routines and notifications again, like a button press does.
--
-- Usage: local emitq = require "emitq"
--        emitq.emit(dev, capabilities.switch.switch.on())              -- main component
--        emitq.emit(dev, capabilities.temperatureMeasurement.temperature({ value = 21, unit = "C" }), comp)
--        emitq.resend_secs = 15 * 60                                    -- optional
-- Events whose shape is not recognised are emitted as they are (no filtering); a hub event looks like
-- { capability = <capability>, attribute = <attribute>, value = { value = .., unit = .. } }.
local json = require "st.json"
local log = require "log"

local M = { resend_secs = 0, cache = {}, shape_logged = {} }

local function ev_state(ev) if ev.value ~= nil then return ev.value end return ev.state end

local function ev_key(comp, ev)
  if type(ev) ~= "table" then return nil end
  local cap = ev.capability_id or ev.capability
  if type(cap) == "table" then cap = cap.ID or cap.id end
  local attr = ev.attribute_id or ev.attribute
  if type(attr) == "table" then attr = attr.NAME or attr.name end
  if type(cap) ~= "string" or type(attr) ~= "string" or ev_state(ev) == nil then return nil end
  return (comp and comp.id or "main") .. "/" .. cap .. "/" .. attr
end

-- spread periodic resends of one device over up to 5 minutes instead of all at once
local function jitter(key, secs)
  local span = math.max(1, math.min(300, math.floor(secs / 2)))
  local n = 0
  for i = 1, #key do n = (n + key:byte(i)) % span end
  return n
end

local function raw_emit(dev, comp, ev)
  if comp then dev:emit_component_event(comp, ev) else dev:emit_event(ev) end
end

--- Emit ev on dev (component comp, or main). Returns true when an event went out, false when it was unchanged.
--- force = true sends it even when unchanged, with state_change (a manual refresh: the cloud catches up).
--- Errors from the device (e.g. a capability not in the profile) propagate like with dev:emit_event, and the
--- value is then not remembered, so the next identical value is tried again.
function M.emit(dev, ev, comp, force)
  local key = ev_key(comp, ev)
  local val
  if key then
    local ok, s = pcall(json.encode, { ev_state(ev), ev.visibility })
    val = ok and s or nil
  end
  if not M.shape_logged[dev.id] then
    M.shape_logged[dev.id] = true
    if key then log.debug("[emitq] " .. tostring(dev.label) .. ": event shape ok (" .. key .. ")")
    else
      local ks = {}
      if type(ev) == "table" then for k in pairs(ev) do ks[#ks + 1] = tostring(k) end end
      log.warn("[emitq] " .. tostring(dev.label) .. ": unknown event shape, no filtering: " .. table.concat(ks, ","))
    end
  end
  if not (key and val) then raw_emit(dev, comp, ev); return true end
  local cache = M.cache[dev.id]
  if not cache then cache = {}; M.cache[dev.id] = cache end
  local c, now = cache[key], os.time()
  local resend = M.resend_secs or 0
  if c and c.v == val and not force and (resend <= 0 or now - c.t < resend + jitter(key, resend)) then return false end
  if not c or c.v == val then ev.state_change = true end
  raw_emit(dev, comp, ev)
  cache[key] = { v = val, t = now }
  return true
end

--- Emit and swallow errors (an unknown enum value only skips that event). Returns true when it went out.
function M.try(dev, ev, comp, force)
  local ok, res = pcall(M.emit, dev, ev, comp, force)
  if not ok then log.warn("[emitq] " .. tostring(dev.label) .. ": " .. tostring(res)); return false end
  return res
end

--- Forget what was sent for a device (e.g. when it is removed).
function M.forget(dev) M.cache[dev.id] = nil; M.shape_logged[dev.id] = nil end

return M
