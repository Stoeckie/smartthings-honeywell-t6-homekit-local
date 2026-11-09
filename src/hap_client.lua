-- HomeKit Accessory Protocol (HAP over IP) controller in pure Lua 5.3.
-- Pair-setup (SRP-6a + Ed25519), pair-verify (X25519 + Ed25519), encrypted HTTP session
-- (ChaCha20-Poly1305 frames), GET /accessories, GET/PUT /characteristics and events.
--
-- Transport-agnostic: the caller passes a connected socket with LuaSocket semantics
-- (sock:send(data), sock:receive(n) -> data | nil, err). On the SmartThings hub that is a
-- cosock TCP socket; in tests a Python socket wrapper.
local sha = require "sha512"
local srp = require "srp"
local c25519 = require "curve25519"
local aead = require "chacha20poly1305"
local tlv = require "tlv8"

local M = {}

-- TLV types
local T = { method = 0, identifier = 1, salt = 2, public_key = 3, proof = 4, encrypted = 5,
            state = 6, error = 7, signature = 10, flags = 19 }
M.TLV = T
local ERRORS = { [1] = "unknown", [2] = "authentication (wrong code?)", [3] = "backoff (too many attempts, wait)",
                 [4] = "max peers", [5] = "max tries", [6] = "unavailable (already paired with another controller)",
                 [7] = "busy" }

-- json: st.json on the hub, injected in tests
M.json = nil
local function json() return M.json or require("st.json") end

-- random bytes for keys: see rng.lua (os.time/os.clock/math.random alone are far too predictable for a key)
local rng = require "rng"
M.rng = rng
function M.random_bytes(n) return rng.bytes(n) end

local function hkdf(key, salt, info) return sha.hkdf(key, salt, info, 32) end
local function u8(n) return string.char(n) end
local function nonce_str(s) return "\0\0\0\0" .. s end
local function nonce_ctr(n) return "\0\0\0\0" .. string.pack("<I8", n) end

------------------------------------------------------------------------
-- HTTP/1.1 parsing (plain or decrypted stream)
------------------------------------------------------------------------

-- Try to take one complete HTTP message from buf. Returns msg, rest  or nil (need more data).
local function parse_message(buf)
  local head_end = buf:find("\r\n\r\n", 1, true)
  if not head_end then return nil end
  local head = buf:sub(1, head_end - 1)
  local first, rest_head = head:match("^([^\r\n]*)\r?\n?(.*)$")
  local headers = {}
  for line in (rest_head .. "\r\n"):gmatch("([^\r\n]*)\r\n") do
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k then headers[k:lower()] = v end
  end
  local proto, status = first:match("^(%S+)%s+(%d+)")
  local msg = { proto = proto, status = tonumber(status), headers = headers,
                event = proto ~= nil and proto:sub(1, 5) == "EVENT" }
  local body_start = head_end + 4
  local te = (headers["transfer-encoding"] or ""):lower()
  if te:find("chunked") then
    local pos, parts = body_start, {}
    while true do
      local line_end = buf:find("\r\n", pos, true)
      if not line_end then return nil end
      local size = tonumber(buf:sub(pos, line_end - 1):match("^%x+"), 16)
      if not size then return nil end
      if size == 0 then
        local trailer_end = buf:find("\r\n", line_end + 2, true)
        if not trailer_end then return nil end
        msg.body = table.concat(parts)
        return msg, buf:sub(trailer_end + 2)
      end
      if #buf < line_end + 2 + size + 1 then return nil end
      parts[#parts + 1] = buf:sub(line_end + 2, line_end + 1 + size)
      pos = line_end + 2 + size + 2
    end
  end
  local len = tonumber(headers["content-length"] or "0") or 0
  if #buf < body_start + len - 1 then return nil end
  msg.body = buf:sub(body_start, body_start + len - 1)
  return msg, buf:sub(body_start + len)
end
M._parse_message = parse_message

local function build_request(method, path, body, ctype, host)
  body = body or ""
  local lines = {
    method .. " " .. path .. " HTTP/1.1",
    "Host: " .. (host or "hap"),
  }
  if method ~= "GET" or #body > 0 then
    lines[#lines + 1] = "Content-Type: " .. (ctype or "application/hap+json")
    lines[#lines + 1] = "Content-Length: " .. #body
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
end

------------------------------------------------------------------------
-- Session
------------------------------------------------------------------------
local Session = {}
Session.__index = Session

--- M.session(sock, opts) ; opts.host (for Host header), opts.on_event(list_of_{aid,iid,value})
function M.session(sock, opts)
  opts = opts or {}
  return setmetatable({ sock = sock, buf = "", plain = "", host = opts.host, on_event = opts.on_event,
                        encrypted = false }, Session)
end

function Session:_recv_raw(n)
  local data, err, partial = self.sock:receive(n)
  if not data then
    if partial and #partial > 0 then return partial end
    return nil, err or "closed"
  end
  return data
end

-- read exactly n raw bytes. With a socket timeout set: a timeout before the first byte is returned as
-- "timeout" when idle_ok (the caller can check its own state and read again, nothing is lost); a timeout
-- in the middle keeps waiting a few times, so a slow frame is not cut in half.
local MID_FRAME_TIMEOUTS = 4
function Session:_read_exact(n, idle_ok)
  local parts, have, waits = {}, 0, 0
  while have < n do
    local d, err = self:_recv_raw(n - have)
    if not d then
      if err == "timeout" and have > 0 and waits < MID_FRAME_TIMEOUTS then
        waits = waits + 1
      else
        return nil, err
      end
    else
      parts[#parts + 1] = d
      have = have + #d
    end
  end
  return table.concat(parts)
end

-- read and decrypt one frame, append to self.plain
function Session:_read_frame()
  local hdr, err = self:_read_exact(2, true)
  if not hdr then return nil, err end
  local len = string.unpack("<I2", hdr)
  local ct, err2 = self:_read_exact(len + 16)
  if not ct then return nil, err2 end
  local pt = aead.decrypt(self.read_key, nonce_ctr(self.read_ctr), ct, hdr)
  if not pt then return nil, "frame authentication failed" end
  self.read_ctr = self.read_ctr + 1
  self.plain = self.plain .. pt
  return true
end

--- Read one complete HTTP message (response or EVENT). Blocking.
function Session:read_message()
  while true do
    local msg, rest = parse_message(self.plain)
    if msg then
      self.plain = rest
      return msg
    end
    if self.encrypted then
      local ok, err = self:_read_frame()
      if not ok then return nil, err end
    else
      local d, err = self:_recv_raw(1)
      if not d then return nil, err end
      -- read what is available in bigger chunks once headers are known
      self.plain = self.plain .. d
    end
  end
end

function Session:_send(data)
  if not self.encrypted then
    local ok, err = self.sock:send(data)
    if not ok then return nil, err end
    return true
  end
  local pos = 1
  while pos <= #data do
    local chunk = data:sub(pos, pos + 1023)
    local hdr = string.pack("<I2", #chunk)
    local ct = aead.encrypt(self.write_key, nonce_ctr(self.write_ctr), chunk, hdr)
    self.write_ctr = self.write_ctr + 1
    local ok, err = self.sock:send(hdr .. ct)
    if not ok then return nil, err end
    pos = pos + 1024
  end
  return true
end

-- Event dispatch helper
function Session:_dispatch_event(msg)
  if not self.on_event then return end
  local ok, data = pcall(json().decode, msg.body or "")
  if ok and type(data) == "table" and data.characteristics then
    self.on_event(data.characteristics)
  end
end

--- Send a request and wait for its response.
--- If self.wait_response is set (async mode: a reader task owns the socket), it is used instead
--- of reading inline. Events received while waiting are dispatched.
function Session:request(method, path, body, ctype)
  local ok, err = self:_send(build_request(method, path, body, ctype, self.host))
  if not ok then return nil, err end
  if self.wait_response then return self.wait_response() end
  while true do
    local msg, rerr = self:read_message()
    if not msg then return nil, rerr end
    if msg.event then self:_dispatch_event(msg) else return msg end
  end
end

local function tlv_request(self, path, items)
  local msg, err = self:request("POST", path, tlv.encode(items), "application/pairing+tlv8")
  if not msg then return nil, err end
  if msg.status ~= 200 then return nil, "HTTP " .. tostring(msg.status) end
  local r = tlv.decode(msg.body or "")
  local e = tlv.get(r, T.error)
  if e then
    local code = e:byte(1)
    return nil, "HomeKit error " .. code .. " " .. (ERRORS[code] or "")
  end
  return r
end

------------------------------------------------------------------------
-- Pair setup: returns pairing table to persist
--   { controller_id, controller_seed (32), controller_pub (32), accessory_id, accessory_pub }
------------------------------------------------------------------------
function Session:pair_setup(pin, controller_id, opts)
  opts = opts or {}
  local yield = opts.yield or function() end
  local progress = opts.progress or function() end
  -- M1
  progress("M1 sent")
  local r, err = tlv_request(self, "/pair-setup", { { T.state, u8(1) }, { T.method, u8(opts.method or 0) } })
  if not r then return nil, "M2: " .. err end
  local salt, B = tlv.get(r, T.salt), tlv.get(r, T.public_key)
  if not salt or not B then return nil, "M2: no salt/B" end
  progress("M2 received, computing SRP")
  -- M3 (the slow part: two 3072-bit modpows). A does not depend on the code, so it is computed
  -- first; accessories with a code on their display (Honeywell T6) only show it after M1, so pin may be
  -- a function that waits for the user to type it.
  local client = srp.new("Pair-Setup", "", salt, B, M.random_bytes(32))
  yield()
  if type(pin) == "function" then
    progress("waiting for the code")
    local perr
    pin, perr = pin()
    if not pin then return nil, "M3: " .. tostring(perr or "no code") end
    progress("code received, computing SRP")
  end
  client.P = pin
  yield()
  local A, M1 = client:public_key(), client:proof()
  yield()
  progress("M3 sent")
  r, err = tlv_request(self, "/pair-setup", { { T.state, u8(3) }, { T.public_key, A }, { T.proof, M1 } })
  if not r then return nil, "M4: " .. err end
  progress("M4 received")
  if not client:verify_server_proof(tlv.get(r, T.proof) or "") then return nil, "M4: accessory proof invalid" end
  local K = client:session_key()
  -- M5: controller identity, signed with its long-term key
  local seed = M.random_bytes(32)
  local pub = c25519.ed25519_keypair(seed)
  local enc_key = hkdf(K, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info")
  local x = hkdf(K, "Pair-Setup-Controller-Sign-Salt", "Pair-Setup-Controller-Sign-Info")
  local sig = c25519.ed25519_sign(x .. controller_id .. pub, seed, pub)
  local sub = tlv.encode({ { T.identifier, controller_id }, { T.public_key, pub }, { T.signature, sig } })
  local enc = aead.encrypt(enc_key, nonce_str("PS-Msg05"), sub, "")
  r, err = tlv_request(self, "/pair-setup", { { T.state, u8(5) }, { T.encrypted, enc } })
  if not r then return nil, "M6: " .. err end
  -- M6: accessory identity
  local dec = aead.decrypt(enc_key, nonce_str("PS-Msg06"), tlv.get(r, T.encrypted) or "", "")
  if not dec then return nil, "M6: decrypt failed" end
  local d = tlv.decode(dec)
  local acc_id, acc_pub, acc_sig = tlv.get(d, T.identifier), tlv.get(d, T.public_key), tlv.get(d, T.signature)
  local ax = hkdf(K, "Pair-Setup-Accessory-Sign-Salt", "Pair-Setup-Accessory-Sign-Info")
  if not (acc_id and acc_pub and acc_sig) or not c25519.ed25519_verify(ax .. acc_id .. acc_pub, acc_sig, acc_pub) then
    return nil, "M6: accessory signature invalid"
  end
  return { controller_id = controller_id, controller_seed = seed, controller_pub = pub,
           accessory_id = acc_id, accessory_pub = acc_pub }
end

------------------------------------------------------------------------
-- Pair verify: sets up the encrypted session
------------------------------------------------------------------------
function Session:pair_verify(p)
  local priv = M.random_bytes(32)
  local pub = c25519.x25519_base(priv)
  local r, err = tlv_request(self, "/pair-verify", { { T.state, u8(1) }, { T.public_key, pub } })
  if not r then return nil, "V2: " .. err end
  local acc_eph = tlv.get(r, T.public_key)
  if not acc_eph then return nil, "V2: no accessory key" end
  local shared = c25519.x25519(priv, acc_eph)
  local key = hkdf(shared, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info")
  local dec = aead.decrypt(key, nonce_str("PV-Msg02"), tlv.get(r, T.encrypted) or "", "")
  if not dec then return nil, "V2: decrypt failed" end
  local d = tlv.decode(dec)
  local acc_id, acc_sig = tlv.get(d, T.identifier), tlv.get(d, T.signature)
  if acc_id ~= p.accessory_id then return nil, "V2: unknown accessory id " .. tostring(acc_id) end
  if not c25519.ed25519_verify(acc_eph .. acc_id .. pub, acc_sig or "", p.accessory_pub) then
    return nil, "V2: accessory signature invalid"
  end
  local sig = c25519.ed25519_sign(pub .. p.controller_id .. acc_eph, p.controller_seed, p.controller_pub)
  local sub = tlv.encode({ { T.identifier, p.controller_id }, { T.signature, sig } })
  local enc = aead.encrypt(key, nonce_str("PV-Msg03"), sub, "")
  r, err = tlv_request(self, "/pair-verify", { { T.state, u8(3) }, { T.encrypted, enc } })
  if not r then return nil, "V4: " .. err end
  self.write_key = hkdf(shared, "Control-Salt", "Control-Write-Encryption-Key")
  self.read_key = hkdf(shared, "Control-Salt", "Control-Read-Encryption-Key")
  self.write_ctr, self.read_ctr = 0, 0
  self.encrypted = true
  return true
end

------------------------------------------------------------------------
-- Accessory API (after pair_verify)
------------------------------------------------------------------------
local function json_response(msg, err)
  if not msg then return nil, err end
  if msg.status ~= 200 and msg.status ~= 207 and msg.status ~= 204 then
    return nil, "HTTP " .. tostring(msg.status) .. " " .. tostring(msg.body)
  end
  if not msg.body or msg.body == "" then return {} end
  local ok, data = pcall(json().decode, msg.body)
  if not ok then return nil, "bad json" end
  return data
end

function Session:accessories()
  local data, err = json_response(self:request("GET", "/accessories"))
  if not data then return nil, err end
  return data.accessories
end

--- ids: list of {aid, iid}
function Session:get(ids)
  local parts = {}
  for i, id in ipairs(ids) do parts[i] = id[1] .. "." .. id[2] end
  local data, err = json_response(self:request("GET", "/characteristics?id=" .. table.concat(parts, ",")))
  if not data then return nil, err end
  return data.characteristics
end

--- items: list of {aid=, iid=, value=} or {aid=, iid=, ev=true}
function Session:put(items)
  local body = json().encode({ characteristics = items })
  return json_response(self:request("PUT", "/characteristics", body, "application/hap+json"))
end

function Session:subscribe(ids)
  local items = {}
  for i, id in ipairs(ids) do items[i] = { aid = id[1], iid = id[2], ev = true } end
  return self:put(items)
end

--- Remove our pairing from the accessory (POST /pairings, RemovePairing).
function Session:remove_pairing(controller_id)
  return tlv_request(self, "/pairings", { { T.state, u8(1) }, { T.method, u8(4) }, { T.identifier, controller_id } })
end

return M
