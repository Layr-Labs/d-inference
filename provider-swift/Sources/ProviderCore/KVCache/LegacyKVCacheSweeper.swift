// Copyright © 2026 Eigen Labs.
//
// One-shot startup sweep of the RETIRED on-disk KV cache tier.
//
// Through v0.7.4 the legacy engine persisted encrypted prefix-cache
// checkpoints under `~/Library/Caches/darkbloom/kv`, accounted by a
// `GlobalDiskAccountant` that also wiped stale files from a prior crash
// at startup. v0.7.5 deleted that tier wholesale (its successor, the
// encrypted SSD-offload tier under `KVCacheSSD/`, ships in v0.7.5 on its
// OWN root — `darkbloom/kv3`, a SIBLING of this sweeper's target, never
// inside it — and reuses `KVCacheKEK`). This sweeper preserves the two
// hygiene properties the accountant's startup sweep provided, forever:
//
//   * a crash can never strand partial cache files, and
//   * a box upgrading from ≤ 0.7.4 sheds the retired tier's on-disk
//     footprint (potentially many GB of ciphertext) on first start.
//
// The files are AES-GCM ciphertext (unreadable without the SE-wrapped
// KEK), so this is disk hygiene, not a confidentiality fix.

import Foundation
#if canImport(os)
import os
#endif

public enum LegacyKVCacheSweeper {

    /// The retired tier's root: `<caches>/darkbloom/kv`.
    public static func defaultKVRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("darkbloom/kv", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("darkbloom/kv")
    }

    /// Delete the retired on-disk KV tier if present. Best-effort and
    /// silent on a missing directory; returns the number of bytes removed
    /// (0 when nothing existed) for the caller's log line.
    @discardableResult
    public static func sweep(kvRoot: URL = defaultKVRoot()) -> UInt64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: kvRoot.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return 0 }
        var bytes: UInt64 = 0
        if let enumerator = fm.enumerator(
            at: kvRoot, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                let size = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
                let (sum, overflow) = bytes.addingReportingOverflow(UInt64(max(0, size)))
                bytes = overflow ? .max : sum
            }
        }
        try? fm.removeItem(at: kvRoot)
        return bytes
    }
}
