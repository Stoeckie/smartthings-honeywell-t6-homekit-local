"""rng.lua: key bytes come from a pool fed by /dev/urandom (when allowed) and CPU timing jitter."""
import time
from pathlib import Path

import lupa.lua53 as lua53

SRC = Path(__file__).resolve().parents[1] / "src"


def runtime(no_io=False):
    lua = lua53.LuaRuntime(unpack_returned_tuples=True, encoding=None)
    lua.execute(f'package.path = "{SRC}/?.lua;" .. package.path')
    if no_io:
        lua.execute("io = nil")          # like a sandbox without file access: jitter only
    return lua


def test_bytes_unique_and_sized():
    for no_io in (False, True):
        lua = runtime(no_io)
        lua.execute('rng = require "rng"')
        t = time.time()
        a, b = lua.eval("rng.bytes(32)"), lua.eval("rng.bytes(32)")
        assert len(a) == 32 and len(b) == 32 and a != b
        assert len(lua.eval("rng.bytes(80)")) == 80
        assert time.time() - t < 30


def test_two_fresh_runtimes_differ_even_without_urandom():
    """Same second, same seed for math.random: the outputs must still differ (timing jitter)."""
    outs = set()
    for _ in range(4):
        lua = runtime(no_io=True)
        lua.execute('math.randomseed(1); rng = require "rng"')
        outs.add(lua.eval("rng.bytes(32)"))
    assert len(outs) == 4


def test_pool_is_saved_and_moves_on():
    lua = runtime(no_io=True)
    lua.execute('rng = require "rng"; SAVED = {}; rng.save = function(p) SAVED[#SAVED + 1] = p end')
    lua.execute("rng.bytes(32); rng.bytes(32)")
    assert lua.eval("#SAVED") == 2 and lua.eval("SAVED[1] ~= SAVED[2]")


def test_hap_client_uses_rng():
    lua = runtime()
    lua.execute('hap = require "hap_client"')
    assert lua.eval("hap.rng == require('rng')")
    assert len(lua.eval("hap.random_bytes(32)")) == 32
