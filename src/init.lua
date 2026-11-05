-- SmartThings Edge driver: Honeywell (Resideo) Lyric T6 / T6R thermostat over HomeKit, locally from the hub.
-- The hub pairs with the thermostat as a HomeKit controller (the T6 shows a one-time code on its display
-- once pairing has started; the user types it as a device setting), keeps one encrypted HAP session open and receives
-- temperature, setpoint, mode and heating state events. No Resideo cloud, no Apple device.
-- No secrets live in the code: the HomeKit code is a device preference, the pairing keys are stored
-- on the hub as persistent device fields.
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local cosock = require "cosock"
local json = require "st.json"
local hap = require "hap_client"
local bignum = require "bignum"
local model_lib = require "t6_model"

local BUILD = "2026-11-05g"
local REQUEST_TIMEOUT = 15
local POLL_SECS = 300
local RECONNECT_MIN, RECONNECT_MAX = 10, 300
local TAG = "[t6]"

-- Connection status as a capability, so routines can notify when the thermostat loses its connection
-- (SmartThings itself has no "device offline" trigger for routines). Offline only after CONN_GRACE s.
local conn_cap = capabilities["silvervalley08660.connectionStatus"]
local drop_cap = capabilities["silvervalley08660.connectionLog"]
local CONN_GRACE = 120

-- Heat demand: a routine/rule tells the thermostat per room whether that room asks for heat
-- (command setRoom(room, "on"/"off")). With N rooms asking, the setpoint becomes the thermostat's own
-- temperature rounded up to 0.5 plus stepPerRoom x N, so the boiler is asked for more heat the more
-- rooms need it. With no room asking, the setpoint goes back to idleSetpoint.
local demand_cap = capabilities["silvervalley08660.heatDemand"]
local DEMAND_FIELD = "heat_rooms"
local apply_demand_soon -- defined after the session code

local tempMeas = capabilities.temperatureMeasurement
local heatSp = capabilities.thermostatHeatingSetpoint
local tMode = capabilities.thermostatMode
local opState = capabilities.thermostatOperatingState
local humidity = capabilities.relativeHumidityMeasurement

hap.json = json

local function now()
  local ok, t = pcall(cosock.socket.gettime)
  return ok and t or os.time()
end

math.randomseed(math.floor((now() * 1000000) % 2147483647))
bignum.yield_hook = function() cosock.socket.sleep(0) end -- SRP modpow runs for seconds: let others run

local conns = {}        -- device.id -> connection state
local discovered = {}   -- dni -> { ip, port, id, name }
local M_TXT_LOGGED = false

-- connection status ------------------------------------------------------------------------
local function emit_conn(dev, v)
  if dev:get_field("conn_status") == v then return end
  local ok = pcall(function() dev:emit_event(conn_cap.status(v)) end)
  if ok then dev:set_field("conn_status", v) end
end
local function fmt_secs(s)
  if s < 120 then return string.format("%d s", s) end
  if s < 7200 then return string.format("%d min", s // 60) end
  return string.format("%.1f h", s / 3600)
end
local function note_drop(dev, reason)
  if dev:get_field("conn_drop") then return end
  dev:set_field("conn_drop", { at = os.time(), reason = tostring(reason or "unknown"):sub(1, 120) }, { persist = true })
end
local function report_drop(dev)
  local d = dev:get_field("conn_drop")
  if type(d) ~= "table" or not d.at then return end
  dev:set_field("conn_drop", nil, { persist = true })
  local txt = string.format("%s UTC, %s: %s", os.date("!%Y-%m-%d %H:%M:%S", d.at),
    fmt_secs(math.max(0, os.time() - d.at)), tostring(d.reason))
  log.info(TAG .. " " .. tostring(dev.label) .. " back after drop at " .. txt)
  pcall(function() dev:emit_event(drop_cap.lastDrop(txt:sub(1, 200))) end)
end
local function set_conn(dev, up, reason)
  if up then
    dev:set_field("conn_down_since", nil)
    report_drop(dev)
    emit_conn(dev, "online")
    return
  end
  note_drop(dev, reason)
  if dev:get_field("conn_down_since") then return end
  local since = os.time()
  dev:set_field("conn_down_since", since)
  local ok = pcall(function()
    dev.thread:call_with_delay(CONN_GRACE, function()
      if dev:get_field("conn_down_since") == since then emit_conn(dev, "offline") end
    end)
  end)
  if not ok then emit_conn(dev, "offline") end
end

-- pairing storage ----------------------------------------------------------------------------
local function tohex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function fromhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end

local function uuid4()
  local b = { hap.random_bytes(16):byte(1, 16) }
  b[7] = (b[7] & 0x0f) | 0x40
  b[9] = (b[9] & 0x3f) | 0x80
  local h = string.format(string.rep("%02X", 16), table.unpack(b))
  return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end

local function load_pairing(dev)
  local p = dev:get_field("hap_pairing")
  if type(p) ~= "table" or not p.controller_id then return nil end
  return { controller_id = p.controller_id, controller_seed = fromhex(p.controller_seed),
           controller_pub = fromhex(p.controller_pub), accessory_id = p.accessory_id,
           accessory_pub = fromhex(p.accessory_pub) }
end

local function save_pairing(dev, p)
  dev:set_field("hap_pairing", {
    controller_id = p.controller_id, controller_seed = tohex(p.controller_seed),
    controller_pub = tohex(p.controller_pub), accessory_id = p.accessory_id,
    accessory_pub = tohex(p.accessory_pub) }, { persist = true })
end

-- addressing / mDNS --------------------------------------------------------------------------
-- TXT records: accept a list of "k=v" strings or a map {k = v}, under f.txt.text or f.txt itself
local function parse_txt(txt)
  local t = {}
  local function take(tbl)
    if type(tbl) ~= "table" then return end
    for k, v in pairs(tbl) do
      if type(k) == "number" then
        if type(v) == "table" then -- the hub gives each record as a list of byte values
          local ok, str = pcall(function() return string.char(table.unpack(v)) end)
          v = ok and str or ""
        end
        local kk, vv = tostring(v):match("^([^=]+)=(.*)$")
        if kk then t[kk:lower()] = vv end
      elseif type(k) == "string" and k ~= "text" then
        t[k:lower()] = tostring(v)
      end
    end
  end
  if type(txt) == "table" then
    take(txt.text)
    take(txt)
  end
  return t
end

-- HomeKit category 9 = thermostat. Accept it when the name/model looks like Honeywell/Lyric/Resideo/T6,
-- or any thermostat when nothing else matches (one HomeKit thermostat on the LAN is the normal case).
local function mdns_scan()
  local ok, mdns = pcall(require, "st.mdns")
  if not ok then
    log.warn(TAG .. " st.mdns not available on this hub firmware; set IP and port in the device settings")
    return {}
  end
  local res, err = mdns.discover("_hap._tcp", "local")
  if not res then
    log.warn(TAG .. " mDNS discover failed: " .. tostring(err))
    return {}
  end
  local named, thermostats = {}, {}
  log.info(string.format("%s mDNS: %d HomeKit device(s) answered", TAG, #(res.found or {})))
  for _, f in ipairs(res.found or {}) do
    local okd, desc = pcall(function()
      local t = parse_txt(f.txt)
      return string.format("%s at %s:%s ci=%s md=%s sf=%s", tostring((f.service_info or {}).name),
        tostring((f.host_info or {}).address), tostring((f.host_info or {}).port), tostring(t.ci), tostring(t.md),
        tostring(t.sf))
    end)
    log.info(TAG .. "   " .. (okd and desc or ("unreadable entry: " .. tostring(desc))))
    if f.txt ~= nil and not M_TXT_LOGGED then
      M_TXT_LOGGED = true
      local okj, enc = pcall(json.encode, f.txt)
      log.info(TAG .. "   txt record looks like: " .. (okj and tostring(enc):sub(1, 300) or type(f.txt)))
    end
  end
  for _, f in ipairs(res.found or {}) do
    local host = f.host_info or {}
    local svc = f.service_info or {}
    local txt = parse_txt(f.txt)
    local name = tostring(svc.name or "")
    local hay = (name .. " " .. tostring(txt.md or "")):upper()
    local ip = host.address and tostring(host.address)
    if ip and ip:match("^%d+%.%d+%.%d+%.%d+$") and txt.id then
      local e = { ip = ip, port = tonumber(host.port), id = txt.id, name = name, paired = txt.sf == "0",
                  model = txt.md }
      if hay:find("LYRIC", 1, true) or hay:find("HONEYWELL", 1, true) or hay:find("RESIDEO", 1, true)
         or hay:find("T6", 1, true) then
        named[#named + 1] = e
      elseif txt.ci == "9" then
        thermostats[#thermostats + 1] = e
      end
    end
  end
  return #named > 0 and named or thermostats
end

local function address(dev)
  local p = dev.preferences or {}
  local ip = p.ipAddress
  if ip == nil or ip == "" or ip == "auto" then ip = dev:get_field("ip") end
  local port = tonumber(p.hapPort)
  if not port or port == 0 then port = dev:get_field("port") end
  return ip, port
end

local function refresh_address(dev)
  local id = dev:get_field("hap_id")
  for _, f in ipairs(mdns_scan()) do
    if not id or f.id == id then
      if dev:get_field("ip") ~= f.ip or dev:get_field("port") ~= f.port then
        log.info(string.format("%s thermostat %s at %s:%s", TAG, f.id, f.ip, tostring(f.port)))
      end
      dev:set_field("ip", f.ip, { persist = true })
      dev:set_field("port", f.port, { persist = true })
      dev:set_field("hap_id", f.id, { persist = true })
      return true
    end
  end
  return false
end

local function open_socket(dev, timeout)
  local ip, port = address(dev)
  if not ip or not port then
    refresh_address(dev)
    ip, port = address(dev)
  end
  if not ip or not port then return nil, "thermostat address unknown (not found via mDNS; set IP and port)" end
  local sock = cosock.socket.tcp()
  sock:settimeout(timeout or 15)
  local ok, err = sock:connect(ip, port)
  if not ok then
    sock:close()
    return nil, string.format("connect %s:%s failed: %s", ip, tostring(port), tostring(err))
  end
  return sock, nil, ip
end

-- state -> events ------------------------------------------------------------------------------
local function emit_state(dev, model, touched)
  local v = model.values
  local all = touched == nil
  local function t(f) return all or touched[f] end
  if t("cur_temp") and tonumber(v.cur_temp) then
    dev:emit_event(tempMeas.temperature({ value = math.floor(tonumber(v.cur_temp) * 10 + 0.5) / 10, unit = "C" }))
  end
  if t("tgt_temp") and tonumber(v.tgt_temp) then
    dev:emit_event(heatSp.heatingSetpoint({ value = math.floor(tonumber(v.tgt_temp) * 10 + 0.5) / 10, unit = "C" }))
  end
  if t("tgt_state") then
    local name = model_lib.MODE_NAME[tonumber(v.tgt_state)]
    if name and tMode.thermostatMode[name] then dev:emit_event(tMode.thermostatMode[name]()) end
  end
  if t("cur_state") then
    local name = model_lib.STATE_NAME[tonumber(v.cur_state)]
    if name and opState.thermostatOperatingState[name] then
      dev:emit_event(opState.thermostatOperatingState[name]())
    end
  end
  if t("humidity") and tonumber(v.humidity) and dev:supports_capability(humidity) then
    dev:emit_event(humidity.humidity(math.floor(tonumber(v.humidity) + 0.5)))
  end
end

local function emit_static(dev, model)
  local modes = model_lib.supported_modes(model)
  pcall(function()
    dev:emit_event(tMode.supportedThermostatModes(modes, { visibility = { displayed = false } }))
  end)
  local m = model.meta.tgt_temp or {}
  pcall(function()
    dev:emit_event(heatSp.heatingSetpointRange({ value = { minimum = m.min or 5, maximum = m.max or 35,
      step = (m.step and m.step > 0) and m.step or 0.5 }, unit = "C" }, { visibility = { displayed = false } }))
  end)
  log.info(string.format("%s %s %s (fw %s), modes %s, setpoint %s..%s step %s", TAG,
    tostring(model.info.manufacturer), tostring(model.info.model), tostring(model.info.firmware),
    table.concat(modes, "/"), tostring(m.min), tostring(m.max), tostring(m.step)))
end

local function safe_emit(dev, model, touched)
  local ok, err = pcall(emit_state, dev, model, touched)
  if not ok then log.error(TAG .. " emit: " .. tostring(err)) end
end

-- session ------------------------------------------------------------------------------------------
local function close_conn(c)
  c.alive = false
  if c.sock then pcall(function() c.sock:close() end) end
  c.sock = nil
end

local function make_waiter(c)
  return function()
    local deadline = now() + REQUEST_TIMEOUT
    while #c.responses == 0 do
      if not c.alive then return nil, "connection closed" end
      if now() > deadline then
        close_conn(c) -- resync: a late response would otherwise be taken by the next request
        return nil, "timeout"
      end
      cosock.socket.sleep(0.05)
    end
    return table.remove(c.responses, 1)
  end
end

local function run_session(driver, dev)
  local c = conns[dev.id]
  local backoff = RECONNECT_MIN
  while c and not c.stopped do
    local pairing = load_pairing(dev)
    if not pairing then
      log.info(TAG .. " not paired yet")
      return
    end
    local drop_reason
    local sock, err = open_socket(dev, 20)
    if sock then
      c.sock, c.alive, c.responses = sock, true, {}
      local s = hap.session(sock, { host = "lyric" })
      c.session = s
      local ok, verr = s:pair_verify(pairing)
      local accs, model
      if ok then accs, verr = s:accessories() end
      if accs then model, verr = model_lib.build(accs) end
      if model then
        c.model = model
        local _, serr = s:subscribe(model_lib.read_ids(model))
        if serr then log.warn(TAG .. " subscribe: " .. tostring(serr)) end
        dev:online(); set_conn(dev, true)
        emit_static(dev, model)
        safe_emit(dev, model, nil)
        log.info(TAG .. " session up")
        apply_demand_soon(dev)
        backoff = RECONNECT_MIN
        sock:settimeout(nil) -- reader loop owns the socket from now on
        s.on_event = function(chars)
          local touched = model_lib.apply(model, chars)
          if touched then safe_emit(dev, model, touched) end
          if touched and (touched.cur_temp or touched.tgt_state) then apply_demand_soon(dev) end
        end
        s.wait_response = make_waiter(c)
        while c.alive do
          local msg, rerr = s:read_message()
          if not msg then
            if c.alive then log.warn(TAG .. " session closed: " .. tostring(rerr)) end
            drop_reason = "session closed: " .. tostring(rerr)
            break
          end
          if msg.event then s:_dispatch_event(msg) else c.responses[#c.responses + 1] = msg end
        end
      else
        log.error(TAG .. " session setup failed: " .. tostring(verr))
        drop_reason = "session setup failed: " .. tostring(verr)
        if tostring(verr):find("unknown accessory id") or tostring(verr):find("authentication") then
          log.error(TAG .. " the thermostat no longer knows this hub; remove pairing and pair again")
        end
      end
      close_conn(c)
    else
      log.warn(TAG .. " " .. tostring(err))
      drop_reason = "no connection: " .. tostring(err)
    end
    if c.stopped then return end
    set_conn(dev, false, drop_reason); dev:offline()
    cosock.socket.sleep(backoff)
    backoff = math.min(backoff * 2, RECONNECT_MAX)
    refresh_address(dev)
  end
end

local function start_session(driver, dev)
  local old = conns[dev.id]
  if old then
    old.stopped = true
    close_conn(old)
  end
  conns[dev.id] = { responses = {} }
  cosock.spawn(function() run_session(driver, dev) end, "t6-session-" .. dev.id)
end

-- pairing -----------------------------------------------------------------------------------------
local function normalize_pin(pin)
  local d = tostring(pin or ""):gsub("%D", "")
  if #d ~= 8 then return nil end
  return d:sub(1, 3) .. "-" .. d:sub(4, 5) .. "-" .. d:sub(6, 8)
end

local CODE_WAIT = 300 -- seconds the hub waits for the code from the thermostat display

local function pair(driver, dev)
  conns[dev.id] = conns[dev.id] or { responses = {} }
  local c = conns[dev.id]
  if c.pairing then return end
  c.pairing, c.new_pin = true, nil
  local function again(delay)
    dev.thread:call_with_delay(delay, function() if not load_pairing(dev) then pair(driver, dev) end end)
  end
  cosock.spawn(function()
    refresh_address(dev)
    local sock, err = open_socket(dev, 120)
    if not sock then
      log.warn(TAG .. " pairing: " .. tostring(err) .. " (HomeKit not active? retry in 60 s)")
      c.pairing = false
      again(60)
      return
    end
    local t0 = now()
    local s = hap.session(sock, { host = "lyric" })
    -- The T6 shows a new 8-digit code on its display for every pairing attempt (the sticker code does
    -- not work), so the hub starts pairing first and then waits for the user to type that code.
    local function get_pin()
      log.info(TAG .. " >>> the thermostat now shows a HomeKit code: enter it in the device settings"
        .. " (HomeKit code) within 5 minutes")
      local deadline = now() + CODE_WAIT
      while not c.new_pin and now() < deadline and not c.stopped do cosock.socket.sleep(1) end
      local pin = c.new_pin
      c.new_pin = nil
      if not pin then return nil, "no code entered within 5 minutes" end
      return pin
    end
    log.info(TAG .. " pairing started")
    local p, perr = s:pair_setup(get_pin, uuid4(), { yield = function() cosock.socket.sleep(0) end,
      progress = function(m) log.info(string.format("%s pairing: %s (%.0f s)", TAG, m, now() - t0)) end })
    pcall(function() sock:close() end)
    c.pairing = false
    if not p then
      local e = tostring(perr)
      log.error(TAG .. " pairing failed: " .. e)
      if e:find("HomeKit error 2") then
        log.error(TAG .. " wrong code: a new attempt starts in 10 s, the thermostat then shows a new code")
        again(10)
      elseif e:find("HomeKit error [56]") then
        log.error(TAG .. " the thermostat refuses pairing (already paired or too many tries):"
          .. " Menu, RESET, HomeKit on the thermostat; retry in 10 min")
        again(600)
      else
        again(60)
      end
      return
    end
    save_pairing(dev, p)
    log.info(string.format("%s paired in %.0f s with accessory %s", TAG, now() - t0, tostring(p.accessory_id)))
    start_session(driver, dev)
  end, "t6-pair-" .. dev.id)
end

local function unpair(driver, dev)
  local c = conns[dev.id]
  local p = load_pairing(dev)
  if not p then return end
  cosock.spawn(function()
    local ok, err
    if c and c.session and c.alive then ok, err = c.session:remove_pairing(p.controller_id) end
    if c then
      c.stopped = true
      close_conn(c)
    end
    dev:set_field("hap_pairing", nil, { persist = true })
    log.info(TAG .. " pairing removed" .. (ok and "" or (" locally (thermostat: " .. tostring(err) .. ")")))
  end, "t6-unpair")
end

-- commands -------------------------------------------------------------------------------------------
local function write(dev, field, value, what)
  local c = conns[dev.id]
  if not (c and c.alive and c.model and c.model.chars[field]) then
    log.warn(TAG .. " " .. what .. ": not connected")
    return false
  end
  local _, err = c.session:put({ { aid = c.model.aid, iid = c.model.chars[field], value = value } })
  if err then
    log.error(TAG .. " " .. what .. " failed: " .. tostring(err))
    return false
  end
  local touched = model_lib.apply(c.model, { { aid = c.model.aid, iid = c.model.chars[field], value = value } })
  if touched then safe_emit(dev, c.model, touched) end
  return true
end

local function handle_setpoint(driver, dev, cmd)
  local c = conns[dev.id]
  local v = c and c.model and model_lib.clamp_setpoint(c.model, cmd.args.setpoint) or tonumber(cmd.args.setpoint)
  cosock.spawn(function() write(dev, "tgt_temp", v, "setpoint " .. tostring(v)) end, "t6-setpoint")
end

local function set_mode(dev, name)
  local v = model_lib.MODE_VALUE[name]
  if v == nil then
    log.warn(TAG .. " unsupported mode " .. tostring(name))
    return
  end
  cosock.spawn(function() write(dev, "tgt_state", v, "mode " .. name) end, "t6-mode")
end

local function handle_mode(driver, dev, cmd) set_mode(dev, cmd.args.mode) end

-- heat demand -----------------------------------------------------------------------------------------
local function demand_rooms(dev)
  local r = dev:get_field(DEMAND_FIELD)
  return type(r) == "table" and r or {}
end

local function demand_list(rooms)
  local names = {}
  for k, v in pairs(rooms) do if v then names[#names + 1] = tostring(k) end end
  table.sort(names)
  return names
end

local function emit_demand(dev)
  local names = demand_list(demand_rooms(dev))
  local summary = #names == 0 and "none" or table.concat(names, ", ")
  if dev:get_field("demand_emitted") == summary then return end
  local ok = pcall(function()
    dev:emit_event(demand_cap.rooms(#names))
    dev:emit_event(demand_cap.summary(summary:sub(1, 200)))
  end)
  if ok then dev:set_field("demand_emitted", summary) end
end

local function ceil_half(x) return math.ceil(x * 2 - 1e-9) / 2 end

-- Only active once a rule has sent setRoom: without it the driver never touches the setpoint.
-- Back to idleSetpoint only on the change from "some rooms" to "no room", so a manual setpoint
-- is left alone while no room asks for heat.
-- (a stored room list also counts as active, so control resumes right after a driver update)
local function apply_demand(dev)
  if not dev:get_field("demand_active") and dev:get_field(DEMAND_FIELD) == nil then return end
  local c = conns[dev.id]
  if not (c and c.alive and c.model) then return end
  local v = c.model.values
  local mode = tonumber(v.tgt_state)
  if mode ~= 1 and mode ~= 3 then return end -- thermostat off: leave it alone
  local n = #demand_list(demand_rooms(dev))
  local p = dev.preferences or {}
  local idle = tonumber(p.idleSetpoint) or 19
  local step = tonumber(p.stepPerRoom) or 0.5
  local cur_sp = tonumber(v.tgt_temp)
  local last_n = tonumber((dev:get_field("demand_last_n"))) or 0 -- get_field may return nothing at all
  local target
  if n > 0 then
    local t = tonumber(v.cur_temp)
    if not t then return end
    target = model_lib.clamp_setpoint(c.model, ceil_half(t) + step * n)
  elseif last_n > 0 and cur_sp and cur_sp > idle then
    target = model_lib.clamp_setpoint(c.model, idle)
  end
  if n ~= last_n then dev:set_field("demand_last_n", n, { persist = true }) end
  if target and (not cur_sp or math.abs(target - cur_sp) > 0.01) then
    log.info(string.format("%s heat demand: %d room(s), temperature %s, setpoint %s -> %s", TAG, n,
      tostring(v.cur_temp), tostring(cur_sp), tostring(target)))
    write(dev, "tgt_temp", target, "heat demand setpoint " .. tostring(target))
  end
end

-- never let a heat demand error take the whole driver down
local function safe_apply_demand(dev)
  local ok, err = pcall(apply_demand, dev)
  if not ok then log.error(TAG .. " heat demand: " .. tostring(err)) end
end

-- the rule sends one command per room in a burst: settle for 2 s, then apply once
apply_demand_soon = function(dev)
  local c = conns[dev.id]
  if not c then return end
  c.demand_token = (c.demand_token or 0) + 1
  local token = c.demand_token
  local ok = pcall(function()
    dev.thread:call_with_delay(2, function()
      local c2 = conns[dev.id]
      if c2 and c2.demand_token == token then cosock.spawn(function() safe_apply_demand(dev) end, "t6-demand") end
    end)
  end)
  if not ok then cosock.spawn(function() safe_apply_demand(dev) end, "t6-demand") end
end

local function handle_set_room(driver, dev, cmd)
  local room = tostring(cmd.args.room or ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 40)
  if room == "" then return end
  local on = cmd.args.demand == "on" or cmd.args.demand == true
  if not dev:get_field("demand_active") then
    dev:set_field("demand_active", true, { persist = true })
    log.info(TAG .. " heat demand control active (setRoom received)")
  end
  local rooms = demand_rooms(dev)
  if (rooms[room] == true) ~= on then
    rooms[room] = on or nil
    dev:set_field(DEMAND_FIELD, rooms, { persist = true })
    log.info(string.format("%s heat demand: %s %s (%d room(s) asking)", TAG, room, on and "on" or "off",
      #demand_list(rooms)))
  end
  emit_demand(dev)
  apply_demand_soon(dev)
end

-- clearRooms: forget all rooms and switch heat demand control off until the next setRoom
local function handle_clear_rooms(driver, dev)
  dev:set_field(DEMAND_FIELD, nil, { persist = true })
  dev:set_field("demand_active", nil, { persist = true })
  dev:set_field("demand_last_n", 0, { persist = true })
  log.info(TAG .. " heat demand: all rooms cleared, control off until the next setRoom")
  emit_demand(dev)
  apply_demand_soon(dev)
end

local function poll(driver, dev)
  local c = conns[dev.id]
  if not (c and c.alive and c.model) then return end
  local chars, err = c.session:get(model_lib.read_ids(c.model))
  if chars then
    local touched = model_lib.apply(c.model, chars)
    if touched then safe_emit(dev, c.model, touched) end
  else
    log.warn(TAG .. " poll failed: " .. tostring(err))
  end
end

local function handle_refresh(driver, dev)
  cosock.spawn(function() poll(driver, dev) end, "t6-refresh")
end

-- lifecycle ----------------------------------------------------------------------------------------------
local function device_init(driver, dev)
  dev.thread:call_on_schedule(POLL_SECS, function()
    cosock.spawn(function() poll(driver, dev) end, "t6-poll")
  end, "t6-poll")
  pcall(emit_demand, dev)
  if load_pairing(dev) then start_session(driver, dev) else pair(driver, dev) end
end

local function device_added(driver, dev)
  local d = discovered[dev.device_network_id]
  if d then
    dev:set_field("ip", d.ip, { persist = true })
    dev:set_field("port", d.port, { persist = true })
    dev:set_field("hap_id", d.id, { persist = true })
  end
  device_init(driver, dev)
end

local function info_changed(driver, dev, event, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = dev.preferences or {}
  if new.resetPairing and not old.resetPairing then
    unpair(driver, dev)
    return
  end
  if old.idleSetpoint ~= new.idleSetpoint or old.stepPerRoom ~= new.stepPerRoom then apply_demand_soon(dev) end
  if old.ipAddress ~= new.ipAddress or old.hapPort ~= new.hapPort then
    if load_pairing(dev) then start_session(driver, dev) end
  end
  if old.homekitCode ~= new.homekitCode and not load_pairing(dev) then
    local pin = normalize_pin(new.homekitCode)
    local c = conns[dev.id]
    if pin and c and c.pairing then
      c.new_pin = pin
      log.info(TAG .. " code received")
    elseif pin then
      log.warn(TAG .. " no pairing attempt was running: starting one now, enter the NEW code from the display")
      pair(driver, dev)
    end
  end
end

local function device_removed(driver, dev)
  local c = conns[dev.id]
  if c then
    c.stopped = true
    close_conn(c)
    conns[dev.id] = nil
  end
end

local function discovery(driver, opts, should_continue)
  local found = mdns_scan()
  log.info(string.format("%s discovery: %d HomeKit thermostat(s)", TAG, #found))
  local existing = {}
  for _, dev in ipairs(driver:get_devices()) do existing[dev.device_network_id] = dev end
  for _, f in ipairs(found) do
    local dni = "t6-hap-" .. f.id:gsub(":", ""):lower()
    discovered[dni] = f
    if existing[dni] then
      existing[dni]:set_field("ip", f.ip, { persist = true })
      existing[dni]:set_field("port", f.port, { persist = true })
    else
      log.info(string.format("%s new thermostat %s '%s' at %s:%d (%s)", TAG, f.id, f.name, f.ip, f.port,
        f.paired and "already paired with another controller" or "ready to pair"))
      driver:try_create_device({
        type = "LAN", device_network_id = dni, label = "Honeywell T6", profile = "honeywell-t6",
        manufacturer = "Honeywell", model = f.model or "Lyric T6", vendor_provided_label = "Honeywell T6",
      })
    end
  end
  if #found == 0 and next(existing) == nil then
    -- nothing via mDNS: create the device anyway so IP and port can be set by hand
    driver:try_create_device({
      type = "LAN", device_network_id = "t6-hap-manual", label = "Honeywell T6", profile = "honeywell-t6",
      manufacturer = "Honeywell", model = "Lyric T6", vendor_provided_label = "Honeywell T6",
    })
  end
end

local driver = Driver("honeywell-t6-homekit-local", {
  discovery = discovery,
  _t6 = { conns = conns, apply_demand = function(dev) return apply_demand(dev) end }, -- for tests
  lifecycle_handlers = { init = device_init, added = device_added, infoChanged = info_changed,
                         removed = device_removed },
  capability_handlers = {
    [demand_cap.ID] = { setRoom = handle_set_room, clearRooms = handle_clear_rooms },
    [capabilities.refresh.ID] = { [capabilities.refresh.commands.refresh.NAME] = handle_refresh },
    [heatSp.ID] = { [heatSp.commands.setHeatingSetpoint.NAME] = handle_setpoint },
    [tMode.ID] = {
      [tMode.commands.setThermostatMode.NAME] = handle_mode,
      [tMode.commands.heat.NAME] = function(_, dev) set_mode(dev, "heat") end,
      [tMode.commands.off.NAME] = function(_, dev) set_mode(dev, "off") end,
      [tMode.commands.auto.NAME] = function(_, dev) set_mode(dev, "auto") end,
    },
  },
})

log.info(TAG .. " Honeywell T6 (HomeKit local) driver starting, build " .. BUILD)
driver:run()
