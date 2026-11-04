"""Load an Edge driver's init.lua with stubbed SmartThings modules to catch load-time errors."""
import sys
from run_lua import runtime, SRC, TESTS
src = sys.argv[1] if len(sys.argv) > 1 else str(SRC)
lua = runtime()
lua.execute(f'package.path = "{src}/?.lua;{TESTS}/?.lua;" .. package.path'.encode())
lua.execute(rb'''
local function any() return setmetatable({}, {__index = function(t, k) local v = any(); rawset(t, k, v); return v end,
  __call = function() return any() end}) end
package.loaded["st.driver"] = function(name, tmpl) DRIVER = tmpl; return { run = function() end } end
package.loaded["st.capabilities"] = any()
package.loaded["log"] = { info = print, warn = print, error = print, debug = function() end }
package.loaded["cosock"] = { socket = { gettime = os.time, sleep = function() end, tcp = any, udp = any },
  spawn = function() end, asyncify = function() return any() end }
package.loaded["ltn12"] = any(); package.loaded["cosock.socket"] = any(); package.loaded["cosock.ssl"] = any()
''')
lua.execute(b'dofile("' + src.encode() + b'/init.lua")')
print("loaded OK, handlers:", list(lua.eval(b"DRIVER").keys()))
