"""Independent fixed-byte interoperability fixture; never production key code.

HKDF uses Python stdlib HMAC/SHA256. AES-GCM uses the existing OpenSSL EVP
implementation through ctypes, because no local Python cryptography package was
available. No Swift source, CryptoKit, generated header or codec output is read.
"""
import argparse
import ctypes
import ctypes.util
import hashlib
import hmac
import json
from pathlib import Path
import struct
import uuid


def aes_gcm(lib, key, nonce, aad, plaintext):
    ptr = ctypes.c_void_p
    integer = ctypes.c_int
    lib.EVP_CIPHER_CTX_new.argtypes = []; lib.EVP_CIPHER_CTX_new.restype = ptr
    lib.EVP_CIPHER_CTX_free.argtypes = [ptr]; lib.EVP_CIPHER_CTX_free.restype = None
    lib.EVP_aes_256_gcm.argtypes = []; lib.EVP_aes_256_gcm.restype = ptr
    lib.EVP_EncryptInit_ex.argtypes = [ptr, ptr, ptr, ptr, ptr]; lib.EVP_EncryptInit_ex.restype = integer
    lib.EVP_EncryptUpdate.argtypes = [ptr, ptr, ctypes.POINTER(integer), ptr, integer]
    lib.EVP_EncryptUpdate.restype = integer
    lib.EVP_EncryptFinal_ex.argtypes = [ptr, ptr, ctypes.POINTER(integer)]
    lib.EVP_EncryptFinal_ex.restype = integer
    lib.EVP_CIPHER_CTX_ctrl.argtypes = [ptr, integer, integer, ptr]
    lib.EVP_CIPHER_CTX_ctrl.restype = integer
    def buffer(value): return ctypes.create_string_buffer(value, len(value))
    def good(result):
        if result != 1: raise ValueError('OpenSSL fixture EVP operation failed')
    ctx = lib.EVP_CIPHER_CTX_new()
    if not ctx: raise ValueError('OpenSSL fixture context failed')
    try:
        good(lib.EVP_EncryptInit_ex(ctx, lib.EVP_aes_256_gcm(), None, None, None))
        good(lib.EVP_CIPHER_CTX_ctrl(ctx, 0x9, 12, None))  # EVP_CTRL_AEAD_SET_IVLEN
        good(lib.EVP_EncryptInit_ex(ctx, None, None, buffer(key), buffer(nonce)))
        count = integer()
        good(lib.EVP_EncryptUpdate(ctx, None, ctypes.byref(count), buffer(aad), len(aad)))
        output = ctypes.create_string_buffer(len(plaintext) + 16)
        good(lib.EVP_EncryptUpdate(ctx, output, ctypes.byref(count), buffer(plaintext), len(plaintext)))
        used = count.value
        good(lib.EVP_EncryptFinal_ex(ctx, ctypes.byref(output, used), ctypes.byref(count)))
        used += count.value
        tag = ctypes.create_string_buffer(16)
        good(lib.EVP_CIPHER_CTX_ctrl(ctx, 0x10, 16, tag))  # EVP_CTRL_AEAD_GET_TAG
        return output.raw[:used], tag.raw
    finally:
        lib.EVP_CIPHER_CTX_free(ctx)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--libcrypto', default=ctypes.util.find_library('crypto'))
    args = parser.parse_args()
    if not args.libcrypto: raise ValueError('No existing libcrypto; do not install a dependency')
    lib = ctypes.CDLL(args.libcrypto)
    lib.OpenSSL_version.argtypes = [ctypes.c_int]; lib.OpenSSL_version.restype = ctypes.c_char_p
    epoch = uuid.UUID('9633081f-8116-4a15-8ae3-39ee1451f3ed')
    request = uuid.UUID('d811512b-125f-4dfc-a41a-3ea1f6a86c93')
    key = bytes([91]) * 32
    plan = bytes([17]) * 32; membership = bytes([31]) * 32; expectation = bytes([47]) * 32
    limits = struct.pack('>IQQ', 1024, 128, 65536)
    binding = b'darkbloom/rdma-record/binding/v1\0' + bytes([1]) + epoch.bytes + plan + membership
    salt = b'darkbloom/rdma-record/hkdf-salt/v1\0' + binding + limits
    prk = hmac.new(salt, key, hashlib.sha256).digest()
    payload = b'Darkbloom RDMA fixture v1\0' + bytes(range(16))
    vectors = []
    for rank in [0, 1]:
        record_type = 6 if rank == 0 else 1
        request_bytes = request.bytes if rank == 0 else bytes(16)
        context = bytes([1 if rank == 0 else 0, record_type]) + request_bytes + expectation
        info = b'darkbloom/rdma-record/directional-aes256-gcm/v1\0' + bytes([rank, 1 - rank])
        aes_key = hmac.new(prk, info + b'\x01', hashlib.sha256).digest()
        nonce = bytes([0x44, 0x42, 1, rank]) + struct.pack('>Q', 0)
        header = b'DBRD' + bytes([1, 1, rank, record_type]) + struct.pack('>QI', 0, len(payload)) + bytes(4)
        aad = b'darkbloom/rdma-record/aad/v1\0' + binding + limits + context + header
        ciphertext, tag = aes_gcm(lib, aes_key, nonce, aad, payload)
        vectors.append({'rank': rank, 'recordType': record_type,
            'requestID': str(request) if rank == 0 else None,
            'contextHex': context.hex(), 'hkdfInfoHex': info.hex(), 'derivedKeyHex': aes_key.hex(),
            'nonceHex': nonce.hex(), 'headerHex': header.hex(), 'aadHex': aad.hex(),
            'ciphertextHex': ciphertext.hex(), 'tagHex': tag.hex(),
            'sealedRecordHex': (header + ciphertext + tag).hex()})
    result = {'schema': 'darkbloom_rdma_record_fixed_vector_v1', 'fixtureOnly': True,
        'generator': 'Python stdlib hmac/HKDF-SHA256 + OpenSSL EVP AES-256-GCM via ctypes',
        'opensslVersion': lib.OpenSSL_version(0).decode('ascii'),
        'sessionKeyHex': key.hex(), 'epoch': str(epoch), 'planSHA256Hex': plan.hex(),
        'membershipTranscriptSHA256Hex': membership.hex(), 'expectationSHA256Hex': expectation.hex(),
        'maximumPlaintextBytes': 1024, 'maximumRecordsPerDirection': 128,
        'maximumCumulativePlaintextBytesPerDirection': 65536,
        'bindingHex': binding.hex(), 'limitsHex': limits.hex(), 'hkdfSaltHex': salt.hex(),
        'hkdfPRKHex': prk.hex(), 'plaintextHex': payload.hex(), 'vectors': vectors}
    with args.output.open('x') as file:
        json.dump(result, file, indent=2, sort_keys=True); file.write('\n')
    print(json.dumps({'fixtureOnly': True, 'vectors': 2, 'sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(),
                      'opensslVersion': result['opensslVersion']}))


if __name__ == '__main__': main()
