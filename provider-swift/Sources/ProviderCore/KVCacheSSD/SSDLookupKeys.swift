// Copyright © 2026 Eigen Labs.
//
// HMAC-keyed lookup tags for the SSD prefix cache — the mitigation that
// closes T-041 leak #2 (the legacy tier's plaintext on-disk
// tokenPrefixHash confirmation oracle).
//
//     K_lookup = HKDF-SHA256-Expand(PRK: KEK, info: "dbkv3-lookup-v1", L=32)
//     tag_i    = HMAC-SHA256(K_lookup,
//                    "dbkv3-name-v1" ‖ u64le(len(saltUTF8)) ‖ saltUTF8
//                                    ‖ chainHash_i)
//     win_i    = HMAC-SHA256(K_lookup,
//                    "dbkv3-window-v1" ‖ u64le(len(saltUTF8)) ‖ saltUTF8
//                                      ‖ chainHash_i)
//     wbase_i  = HMAC-SHA256(K_lookup,
//                    "dbkv3-window-base-v1" ‖ u64le(base) ‖ win_i)
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

    static let hkdfInfo = Data("dbkv3-lookup-v1".utf8)
    static let nameDomainTag = Data("dbkv3-name-v1".utf8)
    /// Domain tag for WS-4.2 windowed sidecars. A DIFFERENT domain, not a
    /// different key: the sidecar of a block must land on its own filename
    /// (both live in the same fan-out tree under the same grammar), and a
    /// disk observer must not be able to pair a block with its sidecar —
    /// which a shared domain plus a suffix would hand them for free.
    static let windowNameDomainTag = Data("dbkv3-window-v1".utf8)
    /// Domain tag for the windowed sidecar's POSITION commitment. The
    /// sidecar's absolute base index must be bound into the authenticated
    /// header — that binding is what stops a truncated-tag collision from
    /// restoring the wrong 256 tokens — but the header is plaintext so
    /// startup can index a file without the KEK, and an absolute token
    /// position is conversation-length information (TB-003). Committing to
    /// it under K_lookup keeps the binding and publishes 32 pseudorandom
    /// bytes instead of the index.
    static let windowBaseDomainTag = Data("dbkv3-window-base-v1".utf8)
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
        tag(chainHash: chainHash, cacheSalt: cacheSalt, domain: Self.nameDomainTag)
    }

    private func tag(chainHash: Data, cacheSalt: String, domain: Data) -> Data {
        var message = Data()
        message.append(domain)
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

    /// Full 32-byte lookup tag for the WINDOWED SIDECAR of one chain hash.
    func windowTag(chainHash: Data, cacheSalt: String) -> Data {
        tag(chainHash: chainHash, cacheSalt: cacheSalt, domain: Self.windowNameDomainTag)
    }

    /// Truncated 16-byte sidecar tag (RAM-index key and filename identity).
    func windowTag16(chainHash: Data, cacheSalt: String) -> Data {
        windowTag(chainHash: chainHash, cacheSalt: cacheSalt)
            .prefix(Self.truncatedTagLength)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

extension SSDLookupKeys {

    /// Keyed commitment to a windowed sidecar's absolute base position,
    /// bound to that sidecar's own full lookup tag (which already folds the
    /// chain hash and the scope salt). A reader recomputes it from the base
    /// it EXPECTS and rejects any mismatch; an observer without K_lookup
    /// cannot invert it, test a guessed position against it, or link two
    /// sidecars of the same conversation through it.
    func windowBaseCommitment(windowTag: Data, base: Int) -> Data {
        var message = Data()
        message.append(Self.windowBaseDomainTag)
        var position = UInt64(bitPattern: Int64(base)).littleEndian
        withUnsafeBytes(of: &position) { message.append(contentsOf: $0) }
        message.append(windowTag)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    /// Hex form written to (and compared against) DBK3 metadata.
    func windowBaseCommitmentHex(windowTag: Data, base: Int) -> String {
        Self.hex(windowBaseCommitment(windowTag: windowTag, base: base))
    }
}
