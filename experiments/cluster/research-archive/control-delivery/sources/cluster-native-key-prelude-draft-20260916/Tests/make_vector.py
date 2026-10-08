"""Independent fixture-only X25519 + stdlib HKDF framing vector; never product keys.
Uses the already installed OpenSSL 3 EVP implementation through ctypes.
No install/network fallback is allowed.
Do not run until the root grants CPU validation. No Swift source is imported.
"""
import argparse
import ctypes
import hashlib
import hmac
import json
from pathlib import Path
import struct
import uuid


def x25519(lib, private):
    pointer, size, integer = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int
    lib.EVP_PKEY_new_raw_private_key_ex.argtypes = [pointer, ctypes.c_char_p, ctypes.c_char_p, pointer, size]
    lib.EVP_PKEY_new_raw_private_key_ex.restype = pointer
    lib.EVP_PKEY_get_raw_public_key.argtypes = [pointer, pointer, ctypes.POINTER(size)]
    lib.EVP_PKEY_get_raw_public_key.restype = integer
    lib.EVP_PKEY_free.argtypes = [pointer]; lib.EVP_PKEY_free.restype = None
    lib.EVP_PKEY_CTX_new_from_pkey.argtypes = [pointer, pointer, ctypes.c_char_p]
    lib.EVP_PKEY_CTX_new_from_pkey.restype = pointer
    lib.EVP_PKEY_CTX_free.argtypes = [pointer]; lib.EVP_PKEY_CTX_free.restype = None
    lib.EVP_PKEY_derive_init.argtypes = [pointer]; lib.EVP_PKEY_derive_init.restype = integer
    lib.EVP_PKEY_derive_set_peer.argtypes = [pointer, pointer]; lib.EVP_PKEY_derive_set_peer.restype = integer
    lib.EVP_PKEY_derive.argtypes = [pointer, pointer, ctypes.POINTER(size)]; lib.EVP_PKEY_derive.restype = integer
    def good(value):
        if value != 1: raise ValueError('OpenSSL fixture X25519 operation failed')
    keys, public, shared = [], [], []
    try:
        for raw in private:
            key = lib.EVP_PKEY_new_raw_private_key_ex(None, b'X25519', None, ctypes.create_string_buffer(raw), len(raw))
            if not key: raise ValueError('OpenSSL fixture key failed')
            keys.append(key)
            out, count = ctypes.create_string_buffer(32), size(32)
            good(lib.EVP_PKEY_get_raw_public_key(key, out, ctypes.byref(count)))
            if count.value != 32: raise ValueError('OpenSSL fixture public key size')
            public.append(out.raw)
        for rank in range(2):
            ctx = lib.EVP_PKEY_CTX_new_from_pkey(None, keys[rank], None)
            if not ctx: raise ValueError('OpenSSL fixture context failed')
            try:
                good(lib.EVP_PKEY_derive_init(ctx)); good(lib.EVP_PKEY_derive_set_peer(ctx, keys[1-rank]))
                out, count = ctypes.create_string_buffer(32), size(32)
                good(lib.EVP_PKEY_derive(ctx, out, ctypes.byref(count)))
                if count.value != 32: raise ValueError('OpenSSL fixture secret size')
                shared.append(out.raw)
            finally: lib.EVP_PKEY_CTX_free(ctx)
        if shared[0] != shared[1] or shared[0] == bytes(32): raise ValueError('OpenSSL fixture DH agreement')
        return public, shared[0]
    finally:
        for key in keys: lib.EVP_PKEY_free(key)


def hkdf(secret, salt, info):
    prk = hmac.new(salt, secret, hashlib.sha256).digest()
    return hmac.new(prk, info + b'\x01', hashlib.sha256).digest()


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--libcrypto', type=Path, required=True)
    args = parser.parse_args()
    private = [bytes(range(1, 33)), bytes(range(65, 97))]
    library = args.libcrypto.resolve(strict=True)
    lib = ctypes.CDLL(str(library))
    public, shared = x25519(lib, private)
    epoch = uuid.UUID('01020304-0506-0708-090a-0b0c0d0e0f10').bytes
    digests = [hashlib.sha256(('fixture-native-field-' + str(i)).encode()).digest() for i in range(8)]
    common = (b'darkbloom/native-authorization/common/v1\0' + epoch + struct.pack('>QQ', 7, 11)
              + b''.join(digests) + bytes([1, 1, 2]) + struct.pack('>IIQQ', 4136, 4096, 64, 262144))
    starts = []
    for rank in range(2):
        ids = [uuid.UUID(int=100 + 10 * rank + i).bytes for i in range(3)]
        starts.append(b'DBNS\x01' + common + bytes([rank]) + b''.join(ids))
    hellos = [b'DBNH\x01' + starts[i] + public[i] for i in range(2)]
    binding = b'DBNB\x01' + b''.join(hellos)
    digest = hashlib.sha256(binding).digest()
    master = hkdf(shared, digest, b'darkbloom/native-rdma/record-master/v1')
    confirmation = hkdf(shared, digest, b'darkbloom/native-rdma/key-confirmation/v1')
    tags = [hmac.new(confirmation, b'darkbloom/native-rdma/key-confirmation-proof/v1\0' + bytes([rank]) + digest, hashlib.sha256).digest() for rank in range(2)]
    value = {'fixtureOnly': True, 'generator': 'Python stdlib HMAC/HKDF + OpenSSL EVP X25519',
             'libcryptoSHA256': hashlib.sha256(library.read_bytes()).hexdigest(), 'privateKeys': [x.hex() for x in private], 'publicKeys': [x.hex() for x in public],
             'common': common.hex(), 'starts': [x.hex() for x in starts], 'hellos': [x.hex() for x in hellos],
             'binding': binding.hex(), 'transcriptSHA256': digest.hex(), 'sharedSecret': shared.hex(),
             'recordMaster': master.hex(), 'confirmationKey': confirmation.hex(), 'confirmations': [x.hex() for x in tags]}
    out = args.output.resolve()
    with out.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')
    print(json.dumps({'fixtureOnly': True, 'vectorSHA256': hashlib.sha256(out.read_bytes()).hexdigest(),
                      'bindingBytes': len(binding)}))


if __name__ == '__main__':
    main()
