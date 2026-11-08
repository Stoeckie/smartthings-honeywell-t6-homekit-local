-- Map a HomeKit /accessories tree with a Thermostat service (Honeywell Lyric T6) to one SmartThings
-- thermostat, and characteristic updates to its state.
local M = {}

local SUFFIX = "-0000-1000-8000-0026BB765291"

--- HomeKit type ("35", "00000035-0000-1000-8000-0026BB765291") -> short upper form "35"
function M.short(t)
  t = tostring(t or ""):upper()
  if t:sub(-#SUFFIX) == SUFFIX then t = t:sub(1, -#SUFFIX - 1) end
  t = t:gsub("^0+", "")
  return t
end

local S = { info = "3E", thermostat = "4A", hum = "82" }
local C = { name = "23", manufacturer = "20", model = "21", serial = "30", firmware = "52",
            cur_state = "F", tgt_state = "33", cur_temp = "11", tgt_temp = "35", units = "36", hum = "10" }

-- HomeKit TargetHeatingCoolingState / CurrentHeatingCoolingState values
M.MODE_NAME = { [0] = "off", [1] = "heat", [2] = "cool", [3] = "auto" }
M.MODE_VALUE = { off = 0, heat = 1, cool = 2, auto = 3 }
M.STATE_NAME = { [0] = "idle", [1] = "heating", [2] = "cooling" }

local function chars_by_type(svc)
  local out = {}
  for _, ch in ipairs(svc.characteristics or {}) do out[M.short(ch.type)] = ch end
  return out
end

--- Build the model from the first accessory that has a Thermostat service.
--- model = { aid, name, info = {manufacturer, model, serial, firmware}, chars = {field -> iid},
---           values = {field -> value}, meta = {field -> {min, max, step, valid}}, index = {"aid.iid" -> field} }
--- Returns nil, err when there is no thermostat.
function M.build(accessories)
  for _, acc in ipairs(accessories or {}) do
    local thermo
    for _, svc in ipairs(acc.services or {}) do
      if M.short(svc.type) == S.thermostat then thermo = svc end
    end
    if thermo then
      local model = { aid = acc.aid, name = "Thermostat", info = {}, chars = {}, values = {}, meta = {}, index = {} }
      local function add(ch, field)
        if not ch then return end
        model.chars[field] = ch.iid
        model.values[field] = ch.value
        model.meta[field] = { min = tonumber(ch.minValue), max = tonumber(ch.maxValue), step = tonumber(ch.minStep),
                              valid = ch["valid-values"] }
        model.index[acc.aid .. "." .. ch.iid] = field
      end
      for _, svc in ipairs(acc.services or {}) do
        local st, ch = M.short(svc.type), chars_by_type(svc)
        if st == S.info then
          for field, ct in pairs({ manufacturer = C.manufacturer, model = C.model, serial = C.serial,
                                   firmware = C.firmware }) do
            if ch[ct] then model.info[field] = ch[ct].value end
          end
          if ch[C.name] and ch[C.name].value and ch[C.name].value ~= "" then model.name = ch[C.name].value end
        elseif st == S.thermostat then
          add(ch[C.cur_state], "cur_state")
          add(ch[C.tgt_state], "tgt_state")
          add(ch[C.cur_temp], "cur_temp")
          add(ch[C.tgt_temp], "tgt_temp")
          add(ch[C.hum], "humidity")
        elseif st == S.hum and not model.chars.humidity then
          add(ch[C.hum], "humidity")
        end
      end
      return model
    end
  end
  return nil, "no thermostat service found"
end

--- ids to subscribe to / poll: list of {aid, iid}
function M.read_ids(model)
  local ids = {}
  for _, field in ipairs({ "cur_state", "tgt_state", "cur_temp", "tgt_temp", "humidity" }) do
    if model.chars[field] then ids[#ids + 1] = { model.aid, model.chars[field] } end
  end
  return ids
end

--- Apply a list of {aid, iid, value}; returns set of touched fields (nil when nothing changed).
function M.apply(model, chars)
  local touched
  for _, c in ipairs(chars or {}) do
    local field = model.index[tostring(c.aid) .. "." .. tostring(c.iid)]
    if field and c.value ~= nil then
      model.values[field] = c.value
      touched = touched or {}
      touched[field] = true
    end
  end
  return touched
end

--- Thermostat modes the device accepts (from valid-values, else off/heat/auto minus cool).
function M.supported_modes(model)
  local out, valid = {}, model.meta.tgt_state and model.meta.tgt_state.valid
  if type(valid) == "table" and #valid > 0 then
    for _, v in ipairs(valid) do
      local n = M.MODE_NAME[tonumber(v)]
      if n then out[#out + 1] = n end
    end
  end
  if #out == 0 then
    local max = model.meta.tgt_state and model.meta.tgt_state.max or 3
    for v = 0, math.min(3, max) do
      if v ~= 2 then out[#out + 1] = M.MODE_NAME[v] end
    end
  end
  return out
end

-- HomeKit always works in Celsius. A SmartThings location set to Fahrenheit sends setpoints in °F
-- (68 instead of 20); no sensible Celsius setpoint is above 40, so such a value is read as °F.
M.MAX_CELSIUS = 40

--- Setpoint in °C: values above MAX_CELSIUS are taken as °F and converted.
function M.to_celsius(value)
  local v = tonumber(value)
  if v and v > M.MAX_CELSIUS then v = (v - 32) * 5 / 9 end
  return v
end

--- Clamp and round a setpoint to the characteristic's range and step (default 5 to 35, step 0.5).
function M.clamp_setpoint(model, value)
  local m = model.meta.tgt_temp or {}
  local lo, hi, step = m.min or 5, m.max or 35, m.step or 0.5
  if not step or step <= 0 then step = 0.5 end
  local v = tonumber(value) or lo
  v = math.floor(v / step + 0.5) * step
  if v < lo then v = lo end
  if v > hi then v = hi end
  return math.floor(v * 100 + 0.5) / 100
end

return M
