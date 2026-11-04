"""Tests for src/curve25519.lua against RFC 7748 / RFC 8032 vectors and Python `cryptography`."""
import os
import time

import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519

from run_lua import req, runtime

RAW = serialization.Encoding.Raw
PUB = serialization.PublicFormat.Raw
PRIV = serialization.PrivateFormat.Raw
NOENC = serialization.NoEncryption()


@pytest.fixture(scope="module")
def c():
    return req(runtime(), "curve25519")


# --- X25519 -----------------------------------------------------------------

RFC7748_VECTORS = [
    ("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
     "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
     "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"),
    ("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
     "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493",
     "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"),
]


@pytest.mark.parametrize("k,u,expected", RFC7748_VECTORS)
def test_x25519_rfc7748(c, k, u, expected):
    assert c.x25519(bytes.fromhex(k), bytes.fromhex(u)).hex() == expected


def test_x25519_rfc7748_iterated(c):
    k = u = (9).to_bytes(32, "little")
    for _ in range(1000):
        k, u = c.x25519(k, u), k
    assert k.hex() == "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51"


def test_x25519_rfc7748_dh(c):
    a = bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    b = bytes.fromhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    a_pub, b_pub = c.x25519_base(a), c.x25519_base(b)
    assert a_pub.hex() == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
    assert b_pub.hex() == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
    shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
    assert c.x25519(a, b_pub).hex() == shared
    assert c.x25519(b, a_pub).hex() == shared


def test_x25519_random_against_python(c):
    for _ in range(20):
        a = x25519.X25519PrivateKey.generate()
        b = x25519.X25519PrivateKey.generate()
        a_raw = a.private_bytes(RAW, PRIV, NOENC)
        b_pub = b.public_key().public_bytes(RAW, PUB)
        assert c.x25519_base(a_raw) == a.public_key().public_bytes(RAW, PUB)
        assert c.x25519(a_raw, b_pub) == a.exchange(b.public_key())


# --- Ed25519 ----------------------------------------------------------------

RFC8032_VECTORS = [
    # (seed, public, message, signature)
    ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
     "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
     "",
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
    ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
     "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
     "72",
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
    ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
     "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
     "af82",
     "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
    # 1023-byte message
    ("f5e5767cf153319517630f226876b86c8160cc583bc013744c6bf255f5cc0ee5",
     "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e",
     None,  # loaded from RFC_LONG_MSG below
     "0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350aa5371b1508f9f4528ecea23c436d94b5e8fcd4f681e30a6ac00a9704a188a03"),
    # SHA(abc) message
    ("833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
     "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
     "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
     "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704"),
]

RFC_LONG_MSG = bytes.fromhex(
    "08b8b2b733424243760fe426a4b54908632110a66c2f6591eabd3345e3e4eb98fa6e264bf09efe12ee50f8f54e9f77b1e355f6c50544e23fb1433ddf73be84d8"
    "79de7c0046dc4996d9e773f4bc9efe5738829adb26c81b37c93a1b270b20329d658675fc6ea534e0810a4432826bf58c941efb65d57a338bbd2e26640f89ffbc"
    "1a858efcb8550ee3a5e1998bd177e93a7363c344fe6b199ee5d02e82d522c4feba15452f80288a821a579116ec6dad2b3b310da903401aa62100ab5d1a36553e"
    "06203b33890cc9b832f79ef80560ccb9a39ce767967ed628c6ad573cb116dbefefd75499da96bd68a8a97b928a8bbc103b6621fcde2beca1231d206be6cd9ec7"
    "aff6f6c94fcd7204ed3455c68c83f4a41da4af2b74ef5c53f1d8ac70bdcb7ed185ce81bd84359d44254d95629e9855a94a7c1958d1f8ada5d0532ed8a5aa3fb2"
    "d17ba70eb6248e594e1a2297acbbb39d502f1a8c6eb6f1ce22b3de1a1f40cc24554119a831a9aad6079cad88425de6bde1a9187ebb6092cf67bf2b13fd65f270"
    "88d78b7e883c8759d2c4f5c65adb7553878ad575f9fad878e80a0c9ba63bcbcc2732e69485bbc9c90bfbd62481d9089beccf80cfe2df16a2cf65bd92dd597b07"
    "07e0917af48bbb75fed413d238f5555a7a569d80c3414a8d0859dc65a46128bab27af87a71314f318c782b23ebfe808b82b0ce26401d2e22f04d83d1255dc51a"
    "ddd3b75a2b1ae0784504df543af8969be3ea7082ff7fc9888c144da2af58429ec96031dbcad3dad9af0dcbaaaf268cb8fcffead94f3c7ca495e056a9b47acdb7"
    "51fb73e666c6c655ade8297297d07ad1ba5e43f1bca32301651339e22904cc8c42f58c30c04aafdb038dda0847dd988dcda6f3bfd15c4b4c4525004aa06eeff8"
    "ca61783aacec57fb3d1f92b0fe2fd1a85f6724517b65e614ad6808d6f6ee34dff7310fdc82aebfd904b01e1dc54b2927094b2db68d6f903b68401adebf5a7e08"
    "d78ff4ef5d63653a65040cf9bfd4aca7984a74d37145986780fc0b16ac451649de6188a7dbdf191f64b5fc5e2ab47b57f7f7276cd419c17a3ca8e1b939ae49e4"
    "88acba6b965610b5480109c8b17b80e1b7b750dfc7598d5d5011fd2dcc5600a32ef5b52a1ecc820e308aa342721aac0943bf6686b64b2579376504ccc493d97e"
    "6aed3fb0f9cd71a43dd497f01f17c0e2cb3797aa2a2f256656168e6c496afc5fb93246f6b1116398a346f1a641f3b041e989f7914f90cc2c7fff357876e506b5"
    "0d334ba77c225bc307ba537152f3f1610e4eafe595f6d9d90d11faa933a15ef1369546868a7f3a45a96768d40fd9d03412c091c6315cf4fde7cb68606937380d"
    "b2eaaa707b4c4185c32eddcdd306705e4dc1ffc872eeee475a64dfac86aba41c0618983f8741c5ef68d3a101e8a3b8cac60c905c15fc910840b94c00a0b9d0"
)


def _vectors():
    for seed, pub, msg, sig in RFC8032_VECTORS:
        yield bytes.fromhex(seed), bytes.fromhex(pub), (RFC_LONG_MSG if msg is None else bytes.fromhex(msg)), bytes.fromhex(sig)


@pytest.mark.parametrize("seed,pub,msg,sig", list(_vectors()))
def test_ed25519_rfc8032(c, seed, pub, msg, sig):
    assert c.ed25519_keypair(seed) == pub
    assert c.ed25519_sign(msg, seed, pub) == sig
    assert c.ed25519_verify(msg, sig, pub) is True


def test_ed25519_lua_sign_python_verify(c):
    for i in range(20):
        seed = os.urandom(32)
        msg = os.urandom(i * 7)
        pub = c.ed25519_keypair(seed)
        py_key = ed25519.Ed25519PrivateKey.from_private_bytes(seed)
        assert pub == py_key.public_key().public_bytes(RAW, PUB)
        sig = c.ed25519_sign(msg, seed, pub)
        py_key.public_key().verify(sig, msg)  # raises on failure
        assert sig == py_key.sign(msg)         # deterministic


def test_ed25519_python_sign_lua_verify(c):
    for i in range(20):
        py_key = ed25519.Ed25519PrivateKey.generate()
        pub = py_key.public_key().public_bytes(RAW, PUB)
        msg = os.urandom(i * 13)
        assert c.ed25519_verify(msg, py_key.sign(msg), pub) is True


def test_ed25519_tampered(c):
    py_key = ed25519.Ed25519PrivateKey.generate()
    pub = py_key.public_key().public_bytes(RAW, PUB)
    msg = b"velux hap"
    sig = py_key.sign(msg)
    assert c.ed25519_verify(msg, sig, pub) is True
    assert c.ed25519_verify(msg + b"!", sig, pub) is False
    for pos in (0, 17, 31, 32, 50, 63):          # flip a bit in R and in S
        bad = bytearray(sig)
        bad[pos] ^= 1
        assert c.ed25519_verify(msg, bytes(bad), pub) is False
        with pytest.raises(InvalidSignature):
            py_key.public_key().verify(bytes(bad), msg)
    other = ed25519.Ed25519PrivateKey.generate().public_key().public_bytes(RAW, PUB)
    assert c.ed25519_verify(msg, sig, other) is False
    assert c.ed25519_verify(msg, sig[:63], pub) is False
    # non-canonical S (S + L) must be rejected
    L = 2 ** 252 + 27742317777372353535851937790883648493
    s = int.from_bytes(sig[32:], "little")
    bad = sig[:32] + ((s + L) % 2 ** 256).to_bytes(32, "little")
    assert c.ed25519_verify(msg, bad, pub) is False
    # public key that is not on the curve
    assert c.ed25519_verify(msg, sig, bytes(31) + b"\x02") is False


def test_sign_without_public_key(c):
    seed = os.urandom(32)
    pub = c.ed25519_keypair(seed)
    sig = c.ed25519_sign(b"m", seed, None)
    ed25519.Ed25519PublicKey.from_public_bytes(pub).verify(sig, b"m")


def test_timings(c, capsys):
    seed = os.urandom(32)
    pub = c.ed25519_keypair(seed)
    msg = b"x" * 100
    n = 20
    t = time.perf_counter(); [c.ed25519_sign(msg, seed, pub) for _ in range(n)]; sign = (time.perf_counter() - t) / n
    sig = c.ed25519_sign(msg, seed, pub)
    t = time.perf_counter(); [c.ed25519_verify(msg, sig, pub) for _ in range(n)]; verify = (time.perf_counter() - t) / n
    k = os.urandom(32)
    t = time.perf_counter(); [c.x25519_base(k) for _ in range(n)]; dh = (time.perf_counter() - t) / n
    with capsys.disabled():
        print(f"\n[timings] sign {sign*1000:.1f} ms, verify {verify*1000:.1f} ms, x25519 {dh*1000:.1f} ms")
