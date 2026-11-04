"""Pair the Lua HAP stack with a real Honeywell T6 from a PC, list the thermostat, then remove the pairing
again (so the SmartThings hub can pair afterwards). Usage: python3 pair_test.py IP PORT PIN [keep]
Needs: pip install lupa. Run from this folder with ../src and ../tests on the Lua path."""
import os, socket, sys, time, json, uuid
from lupa import lua53
HERE = os.path.dirname(os.path.abspath(__file__))
ip, port, pin = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode()
keep = len(sys.argv) > 4
lua = lua53.LuaRuntime(unpack_returned_tuples=True, encoding=None)
lua.execute(f'package.path = "{HERE}/../src/?.lua;{HERE}/../tests/?.lua;" .. package.path'.encode())
hap = lua.execute(b'return require "hap_client"')
hap.json = lua.execute(b'return require "st.json"')
hap.random_bytes = lambda n: os.urandom(int(n))

class Sock:
    def __init__(self): self.s = socket.create_connection((ip, port), timeout=60)
    def send(self, d): self.s.sendall(d); return len(d)
    def receive(self, n):
        try: d = self.s.recv(int(n))
        except socket.timeout: return None, b"timeout"
        return d if d else (None, b"closed")
def call(f, *a):
    r = f(*a); return r if isinstance(r, tuple) else (r, None)
def py(o):
    if hasattr(o, "items"):
        keys = list(o.keys())
        if keys and all(isinstance(k, int) for k in keys): return [py(o[k]) for k in sorted(keys)]
        return {(k.decode() if isinstance(k, bytes) else k): py(v) for k, v in o.items()}
    return o.decode("utf-8", "replace") if isinstance(o, bytes) else o

opts = lua.table_from({b"host": ip.encode()})
s = hap.session(Sock(), opts)
t0 = time.time()
p, err = call(s.pair_setup, s, pin, str(uuid.uuid4()).upper().encode())
print("pair_setup:", "OK" if p else err, f"{time.time()-t0:.1f}s")
if not p: sys.exit(1)
s2 = hap.session(Sock(), opts)
ok, err = call(s2.pair_verify, s2, p)
print("pair_verify:", "OK" if ok else err)
if not ok: sys.exit(1)
accs, err = call(s2.accessories, s2)
json.dump(py(accs), open(os.path.join(HERE, "accessories.json"), "w"), indent=1)
m = lua.execute(b'return require "t6_model"')
model = m.build(accs)
print("thermostat:", py(model[b"info"]), py(model[b"values"]), py(m.supported_modes(model)))
if not keep:
    r, err = call(s2.remove_pairing, s2, p[b"controller_id"])
    print("remove_pairing:", "OK" if r else err)
