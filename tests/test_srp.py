"""Tests for src/bignum.lua (against Python ints) and src/srp.lua (against aiohomekit)."""
import hashlib
import os
import random
import time

import pytest
from aiohomekit.crypto import srp as hk_srp

from run_lua import req, runtime

N = hk_srp.MODULUS_VALUE


def to_bytes(i, length=None):
    if length is None:
        length = (i.bit_length() + 7) // 8
    return i.to_bytes(length, "big")


def from_bytes(b):
    return int.from_bytes(b, "big")


@pytest.fixture(scope="module")
def lua():
    return runtime()


@pytest.fixture(scope="module")
def bn(lua):
    return req(lua, "bignum")


@pytest.fixture(scope="module")
def srp(lua):
    return req(lua, "srp")


def L(bn, i):
    return bn.from_bytes(to_bytes(i))


def P(bn, x):
    return from_bytes(bn.to_bytes(x))


# --------------------------------------------------------------------------
# bignum
# --------------------------------------------------------------------------

def rand_values(rng):
    vals = [0, 1, 2, 2**28 - 1, 2**28, 2**56 - 1, 2**56, 2**64 - 1, 2**64, 2**3072 - 1]
    for bits in (1, 27, 28, 29, 56, 63, 64, 65, 100, 500, 3072, 3080, 6144):
        vals.append(rng.getrandbits(bits))
        vals.append((1 << bits) - 1)
        vals.append(1 << bits)
    return vals


def test_bytes_roundtrip(bn):
    rng = random.Random(1)
    for v in rand_values(rng):
        assert P(bn, L(bn, v)) == v
        if v < 2**3072:
            assert bytes(bn.to_bytes(L(bn, v), 384)) == to_bytes(v, 384)
    assert bytes(bn.to_bytes(bn.from_int(0))) == b""
    assert bytes(bn.to_bytes(bn.from_int(0), 4)) == b"\0\0\0\0"
    assert P(bn, bn.from_bytes(b"\0\0\0\x01\x02")) == 0x102
    assert P(bn, bn.from_bytes(b"")) == 0
    assert P(bn, bn.from_int(2**63 - 1)) == 2**63 - 1
    assert bn.bitlen(L(bn, 2**100)) == 101
    assert bn.bitlen(bn.from_int(0)) == 0
    assert P(bn, bn.from_hex(b"00ff01")) == 0xFF01
    assert bytes(bn.to_hex(L(bn, 0xFF01))) == b"ff01"


def test_add_sub_cmp(bn):
    rng = random.Random(2)
    vals = rand_values(rng)
    for a in vals:
        for b in vals:
            la, lb = L(bn, a), L(bn, b)
            assert P(bn, bn.add(la, lb)) == a + b
            c = bn.cmp(la, lb)
            assert c == (a > b) - (a < b)
            if a >= b:
                assert P(bn, bn.sub(la, lb)) == a - b
            else:
                with pytest.raises(Exception):
                    bn.sub(la, lb)
            assert bool(bn.is_zero(la)) == (a == 0)


def test_mul_divmod(bn):
    rng = random.Random(3)
    vals = rand_values(rng)
    for a in vals:
        for b in vals:
            la, lb = L(bn, a), L(bn, b)
            assert P(bn, bn.mul(la, lb)) == a * b
            if b != 0:
                q, r = bn.divmod(la, lb)
                assert (P(bn, q), P(bn, r)) == divmod(a, b), (a, b)
                assert P(bn, bn.mod(la, lb)) == a % b
    with pytest.raises(Exception):
        bn.mod(L(bn, 5), L(bn, 0))


def test_divmod_hard_cases(bn):
    """Cases that exercise Knuth D's qhat correction and add-back."""
    rng = random.Random(4)
    cases = []
    for _ in range(300):
        nb = rng.randint(2, 8)
        b = rng.getrandbits(28 * nb) | (1 << (28 * nb - 1))
        a = rng.getrandbits(28 * rng.randint(nb, 20))
        cases.append((a, b))
        cases.append((b * rng.getrandbits(200) + rng.randrange(b), b))
        cases.append((b * b - 1, b))
        cases.append((b * (2**28 - 1), b))
    # divisors with many 0xFF / top limbs maximal or minimal
    for nb in (2, 3, 5):
        for b in ((1 << (28 * nb)) - 1, (1 << (28 * nb - 1)) + 1, (1 << (28 * nb - 1)) | 0xFFFFFFF):
            for a in (b * b, b * b - 1, b * (2**56) + b - 1, (b << 200) - 1):
                cases.append((a, b))
    for a, b in cases:
        q, r = bn.divmod(L(bn, a), L(bn, b))
        assert (P(bn, q), P(bn, r)) == divmod(a, b), (a, b)


def test_modpow_small(bn):
    rng = random.Random(5)
    for _ in range(200):
        m = rng.getrandbits(rng.randint(1, 200)) | 1  # odd (Montgomery path)
        b = rng.getrandbits(rng.randint(0, 300))
        e = rng.getrandbits(rng.randint(0, 300))
        assert P(bn, bn.modpow(L(bn, b), L(bn, e), L(bn, m))) == pow(b, e, m), (b, e, m)
    for _ in range(50):
        m = rng.getrandbits(rng.randint(2, 100)) | 2  # even (generic path)
        b = rng.getrandbits(rng.randint(0, 150))
        e = rng.getrandbits(rng.randint(0, 150))
        assert P(bn, bn.modpow(L(bn, b), L(bn, e), L(bn, m))) == pow(b, e, m)
    # edge cases
    assert P(bn, bn.modpow(L(bn, 7), L(bn, 0), L(bn, 13))) == 1
    assert P(bn, bn.modpow(L(bn, 7), L(bn, 5), L(bn, 1))) == 0
    assert P(bn, bn.modpow(L(bn, 0), L(bn, 5), L(bn, 13))) == 0
    assert P(bn, bn.modpow(L(bn, 13), L(bn, 5), L(bn, 13))) == 0
    assert P(bn, bn.modpow(L(bn, 2**3071 + 13), L(bn, 2**3071 + 99), L(bn, 2**3071 + 1))) == pow(2**3071 + 13, 2**3071 + 99, 2**3071 + 1)


def test_modpow_3072(bn):
    rng = random.Random(6)
    lN = L(bn, N)
    for b, e in [(5, rng.getrandbits(256)), (rng.getrandbits(3072) % N, rng.getrandbits(768)),
                 (N - 1, N - 1), (rng.getrandbits(3072) % N, 2**3072 - 1)]:
        assert P(bn, bn.modpow(L(bn, b), L(bn, e), lN)) == pow(b, e, N)
    # base >= N gets reduced
    b = N + 12345
    assert P(bn, bn.modpow(L(bn, b), L(bn, 777), lN)) == pow(b, 777, N)


def test_modpow_timing(bn):
    rng = random.Random(7)
    lN = L(bn, N)
    b, e = rng.getrandbits(3072) % N, rng.getrandbits(3072) | (1 << 3071)
    t0 = time.perf_counter()
    r = bn.modpow(L(bn, b), L(bn, e), lN)
    dt = time.perf_counter() - t0
    assert P(bn, r) == pow(b, e, N)
    print(f"\n3072-bit modpow (3072-bit exponent): {dt:.2f}s")
    assert dt < 20


# --------------------------------------------------------------------------
# srp
# --------------------------------------------------------------------------

def test_srp_constants(srp, bn):
    assert P(bn, srp.N) == N
    assert P(bn, srp.k) == hk_srp.CLIENT_K_VALUE


def run_exchange(srp, username, password, a_bytes=None, server=None):
    server = server or hk_srp.SrpServer(username, password)
    salt = to_bytes(server.get_salt(), 16)
    B_b = server.get_public_key_bytes()
    client = srp.new(username.encode(), password.encode(), salt, B_b, a_bytes)
    A_b = bytes(client.public_key(client))
    assert len(A_b) == 384
    server.set_client_public_key(A_b)
    M1 = bytes(client.proof(client))
    assert len(M1) == 64
    return server, client, A_b, M1


def test_srp_full_exchange(srp):
    server, client, A_b, M1 = run_exchange(srp, "Pair-Setup", "123-45-678")
    assert server.verify_clients_proof_bytes(M1), "server rejected M1"
    M2 = server.get_proof_bytes(M1)
    assert client.verify_server_proof(client, M2)
    assert bytes(client.session_key(client)) == server.get_session_key_bytes()
    assert not client.verify_server_proof(client, b"\0" * 64)
    assert not client.verify_server_proof(client, M2[:-1] + bytes([M2[-1] ^ 1]))


def test_srp_matches_aiohomekit_client(srp):
    """Same a, salt and B must give identical A, K and M1 as aiohomekit's client."""
    server = hk_srp.SrpServer("Pair-Setup", "031-45-154")
    ref = hk_srp.SrpClient("Pair-Setup", "031-45-154")
    salt = to_bytes(server.get_salt(), 16)
    ref.set_salt(bytearray(salt))
    ref.set_server_public_key(server.get_public_key_bytes())
    a_bytes = to_bytes(ref.a, 32)
    _, client, A_b, M1 = run_exchange(srp, "Pair-Setup", "031-45-154", a_bytes=a_bytes, server=server)
    assert A_b == ref.get_public_key_bytes()
    assert bytes(client.session_key(client)) == ref.get_session_key_bytes()
    assert M1 == ref.get_proof_bytes()
    assert server.verify_clients_proof_bytes(M1)


def test_srp_wrong_password_fails(srp):
    server = hk_srp.SrpServer("Pair-Setup", "123-45-678")
    _, client, A_b, M1 = run_exchange(srp, "Pair-Setup", "123-45-679", server=server)
    assert not server.verify_clients_proof_bytes(M1)
    assert not client.verify_server_proof(client, server.get_proof_bytes(M1))


def test_srp_several_random_exchanges(srp):
    for _ in range(3):
        pin = "%03d-%02d-%03d" % (random.randrange(1000), random.randrange(100), random.randrange(1000))
        server, client, A_b, M1 = run_exchange(srp, "Pair-Setup", pin)
        assert server.verify_clients_proof_bytes(M1)
        assert client.verify_server_proof(client, server.get_proof_bytes(M1))


def test_srp_set_rng(srp, lua):
    calls = []

    def rng(n):
        calls.append(n)
        return os.urandom(n)

    srp.set_rng(rng)
    try:
        server, client, A_b, M1 = run_exchange(srp, "Pair-Setup", "111-22-333")
        assert calls == [32]
        assert server.verify_clients_proof_bytes(M1)
    finally:
        srp.set_rng(lua.eval(b"function(n) return string.rep('\\7', n) end"))
