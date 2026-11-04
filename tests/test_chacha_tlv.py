"""Tests for src/chacha20poly1305.lua and src/tlv8.lua against Python references."""
import os
import time

import pytest
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from aiohomekit.protocol.tlv import TLV

from run_lua import runtime, req

lua = runtime()
cc = req(lua, "chacha20poly1305")
tlv = req(lua, "tlv8")

LENGTHS = [0, 1, 15, 16, 17, 63, 64, 65, 1023, 1024, 1025]


# ---------------------------------------------------------------- RFC 8439 vectors

def test_chacha20_block_rfc_2_3_2():
    key = bytes(range(32))
    nonce = bytes.fromhex("000000090000004a00000000")
    out = cc.chacha20_block(key, nonce, 1)
    assert out == bytes.fromhex(
        "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e"
        "d2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e")


def test_poly1305_rfc_2_5_2():
    key = bytes.fromhex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
    msg = b"Cryptographic Forum Research Group"
    assert cc.poly1305(key, msg) == bytes.fromhex("a8061dc1305136c6c22b8baf0c0127a9")


def test_aead_rfc_2_8_2():
    key = bytes.fromhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    nonce = bytes.fromhex("070000004041424344454647")
    aad = bytes.fromhex("50515253c0c1c2c3c4c5c6c7")
    pt = (b"Ladies and Gentlemen of the class of '99: If I could offer you only one "
          b"tip for the future, sunscreen would be it.")
    ct = cc.encrypt(key, nonce, pt, aad)
    assert ct[-16:] == bytes.fromhex("1ae10b594f09e26a7e902ecbd0600691")
    assert ct == ChaCha20Poly1305(key).encrypt(nonce, pt, aad)
    assert cc.decrypt(key, nonce, ct, aad) == pt


# ---------------------------------------------------------------- random vs cryptography

@pytest.mark.parametrize("n", LENGTHS)
def test_aead_random(n):
    key, nonce = os.urandom(32), os.urandom(12)
    pt = os.urandom(n)
    aad = os.urandom(n % 40)
    ref = ChaCha20Poly1305(key)
    ct = cc.encrypt(key, nonce, pt, aad)
    assert ct == ref.encrypt(nonce, pt, aad)
    assert cc.decrypt(key, nonce, ct, aad) == pt
    # Lua decrypts what Python encrypted (empty AAD path too)
    ct2 = ref.encrypt(nonce, pt, b"")
    assert cc.decrypt(key, nonce, ct2, b"") == pt


def test_homekit_style_nonce_and_aad():
    key = os.urandom(32)
    nonce = bytes(4) + (7).to_bytes(8, "little")
    pt = os.urandom(1024)
    aad = len(pt).to_bytes(2, "little")
    ct = cc.encrypt(key, nonce, pt, aad)
    assert ct == ChaCha20Poly1305(key).encrypt(nonce, pt, aad)


def test_reject_wrong_tag_and_aad():
    key, nonce = os.urandom(32), os.urandom(12)
    pt, aad = os.urandom(100), b"\x64\x00"
    ct = bytearray(cc.encrypt(key, nonce, pt, aad))
    assert cc.decrypt(key, nonce, bytes(ct), b"\x65\x00") == (None, b"auth failed")
    ct[-1] ^= 1
    assert cc.decrypt(key, nonce, bytes(ct), aad) == (None, b"auth failed")
    ct[-1] ^= 1
    ct[0] ^= 1
    assert cc.decrypt(key, nonce, bytes(ct), aad) == (None, b"auth failed")
    assert cc.decrypt(key, nonce, b"short", aad) == (None, b"auth failed")
    with pytest.raises(InvalidTag):  # sanity: reference rejects too
        ChaCha20Poly1305(key).decrypt(nonce, bytes(ct), aad)


def test_timing_1024(capsys):
    key, nonce = os.urandom(32), os.urandom(12)
    pt, aad = os.urandom(1024), b"\x00\x04"
    cc.encrypt(key, nonce, pt, aad)  # warm up
    n = 50
    t0 = time.perf_counter()
    for _ in range(n):
        ct = cc.encrypt(key, nonce, pt, aad)
        cc.decrypt(key, nonce, ct, aad)
    dt = (time.perf_counter() - t0) / n
    with capsys.disabled():
        print(f"\n[timing] encrypt+decrypt 1024 B: {dt * 1000:.2f} ms")


# ---------------------------------------------------------------- TLV8

def to_py(items):
    return [(int(it[b"type"]), bytes(it[b"value"])) for it in items.values()]


def lua_items(pairs):
    return lua.table(*[lua.table(t, v) for t, v in pairs])


@pytest.mark.parametrize("pairs", [
    [(6, b"\x01"), (3, os.urandom(32))],
    [(6, b"\x02"), (3, os.urandom(300)), (4, os.urandom(64))],  # 300 B must fragment
    [(1, b"a" * 255), (2, b"b" * 256), (3, b"c" * 511)],
    [(9, b"x"), (0xFF, b""), (9, b"y")],
])
def test_tlv_roundtrip_vs_aiohomekit(pairs):
    ref = bytes(TLV.encode_list([[t, bytearray(v)] for t, v in pairs]))
    enc = tlv.encode(lua_items(pairs))
    assert enc == ref
    assert to_py(tlv.decode(enc)) == pairs
    assert [(k, bytes(v)) for k, v in TLV.decode_bytes(enc)] == pairs


def test_tlv_fragmentation_layout():
    v = bytes(range(256)) + b"\x00" * 44  # 300 bytes
    enc = tlv.encode(lua_items([(3, v)]))
    assert enc[0:2] == b"\x03\xff" and enc[257:259] == b"\x03\x2d" and len(enc) == 304


def test_tlv_named_fields_and_get():
    enc = tlv.encode(lua.table(lua.table_from({b"type": 6, b"value": b"\x03"}), lua.table_from({b"type": 7, b"value": b"\x02"})))
    items = tlv.decode(enc)
    assert tlv.get(items, 6) == b"\x03"
    assert tlv.get(items, 7) == b"\x02"
    assert tlv.get(items, 8) is None


def test_tlv_truncated():
    assert tlv.decode(b"\x06\x05ab") == (None, b"truncated TLV value")
    assert tlv.decode(b"\x06") == (None, b"truncated TLV header")
    assert to_py(tlv.decode(b"")) == []
