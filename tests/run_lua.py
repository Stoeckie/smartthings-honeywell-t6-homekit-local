"""Helper: run Lua 5.3 code from Python (lupa) with package.path pointing at ../src and this folder.

Binary strings cross the boundary as bytes (encoding=None makes the conversion lossless).
"""
import pathlib
from lupa import lua53

TESTS = pathlib.Path(__file__).resolve().parent
SRC = TESTS.parent / "src"


def runtime():
    lua = lua53.LuaRuntime(unpack_returned_tuples=True, encoding=None)
    lua.execute(f'package.path = "{SRC}/?.lua;{TESTS}/?.lua;" .. package.path'.encode())
    return lua


def req(lua, name):
    return lua.execute(f'return require("{name}")'.encode())
