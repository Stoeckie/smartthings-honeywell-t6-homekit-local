-- Apple HomeKit TLV8 encoder/decoder in pure Lua 5.3.
-- Items are {type=<0..255>, value=<string>} or positional {type, value}.
local M = {}

local schar, ssub, sbyte = string.char, string.sub, string.byte

local function item_fields(item)
  local t = item.type or item[1]
  local v = item.value or item[2] or ""
  assert(type(t) == "number" and t >= 0 and t <= 255, "TLV8 type must be 0..255")
  assert(type(v) == "string", "TLV8 value must be a string")
  return t, v
end

-- Encode a list of items; values > 255 bytes are split into 255-byte fragments.
function M.encode(items)
  local out = {}
  for _, item in ipairs(items) do
    local t, v = item_fields(item)
    local tc = schar(t)
    if #v == 0 then
      out[#out + 1] = tc .. "\0"
    else
      local pos = 1
      while pos <= #v do
        local chunk = ssub(v, pos, pos + 254)
        out[#out + 1] = tc .. schar(#chunk) .. chunk
        pos = pos + 255
      end
    end
  end
  return table.concat(out)
end

-- Decode to an ordered list of {type=, value=}; consecutive same-type fragments are merged.
-- Returns nil, err on truncated input.
function M.decode(s)
  local items = {}
  local pos, len = 1, #s
  while pos <= len do
    if pos + 1 > len then return nil, "truncated TLV header" end
    local t, l = sbyte(s, pos, pos + 1)
    local v = ssub(s, pos + 2, pos + 1 + l)
    if #v ~= l then return nil, "truncated TLV value" end
    local last = items[#items]
    if last and last.type == t then
      last.value = last.value .. v   -- same as aiohomekit: merge any adjacent same-type items
    else
      items[#items + 1] = { type = t, value = v }
    end
    pos = pos + 2 + l
  end
  return items
end

-- First value with the given type, or nil.
function M.get(items, t)
  for _, it in ipairs(items) do
    if it.type == t then return it.value end
  end
  return nil
end

return M
