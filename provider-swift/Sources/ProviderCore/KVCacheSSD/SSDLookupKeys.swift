// Copyright © 2026 Eigen Labs.
//
// HMAC-keyed lookup tags for the SSD prefix cache — the mitigation that
// closes T-041 leak #2 (the legacy tier's plaintext on-disk
// tokenPrefixHash confirmation oracle).
//
//     K_lookup = HKDF-SHA256-Expand(PRK: KEK, info: "dbkv2-lookup-v1", L=32)
//     tag_i    = HMAC-SHA256(K_lookup,
//                    "dbkv2-name-v1" ‖ u64le(len(saltUTF8)) ‖ saltUTF8
//                                    ‖ chainHash_i)
//
// * K_lookup is derived from the existing Secure-Enclave-rooted KEK
//   (RFC 5869 Expand-only — the KEK is already a uniform 256-bit key, so
//   Extract is a no-op; the dedicated info string gives clean domain
//   separation: the KEK is never used directly as an HMAC key). No new
//   stored key material; a KEK `wipe()` makes the cache unreadable AND
//   unfindable — the correct failure direction.
// * `chainHash_i` is the engine's `CBv2BlockHasher` chain hash (which
//   already folds modelName and — for scoped requests — the cacheSalt
//   into block 1). The EXPLICIT re-fold of the salt here, length-prefixed
//   so an empty salt is unambiguous, is defense-in-depth: scope isolation
//   on disk survives even a future BlockHasher change to salt
//   propagation. Two scopes can never produce the same tag for the same
//   tokens.
// * On-disk file names and the RAM index carry ONLY (truncated) tags.
//   Raw chain hashes never touch disk, filenames, metadata, or logs. A
//   disk observer cannot test a guessed prefix against anything: the tag
//   requires K_lookup, K_lookup requires the KEK, the KEK requires an
//   ECIES decrypt inside this machine's Secure Enclave.

import CryptoKit
import Foundation

struct SSDLookupKeys: Sendable {

    static let hkdfInfo = Data("dbkv2-lookup-v1".utf8)
    static let nameDomainTag = Data("dbkv2-name-v1".utf8)
    /// Truncated-tag length used for filenames and the RAM index (128-bit;
    /// the full 256-bit tag rides inside the authenticated file metadata).
    static let truncatedTagLength = 16

    /// The per-install lookup-key secret (K_lookup).
    private let key: SymmetricKey

    init(kek: SymmetricKey) {
        self.key = HKDF<SHA256>.expand(
            pseudoRandomKey: kek, info: Self.hkdfInfo, outputByteCount: 32)
    }

    /// Full 32-byte lookup tag for one chain hash under a scope salt
    /// ("" ⇒ unscoped — length-prefixed, so it can never collide with a
    /// non-empty salt whose bytes happen to align).
    func tag(chainHash: Data, cacheSalt: String) -> Data {
        var message = Data()
        message.append(Self.nameDomainTag)
        let saltBytes = Data(cacheSalt.utf8)
        var len = UInt64(saltBytes.count).littleEndian
        withUnsafeBytes(of: &len) { message.append(contentsOf: $0) }
        message.append(saltBytes)
        message.append(chainHash)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    /// Truncated 16-byte tag (the RAM-index key and filename identity).
    func tag16(chainHash: Data, cacheSalt: String) -> Data {
        tag(chainHash: chainHash, cacheSalt: cacheSalt).prefix(Self.truncatedTagLength)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
