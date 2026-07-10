/// SpecDecStore -- on-disk layout + completeness verification for the
/// speculative-decoding drafter store at `~/.darkbloom/spec-dec/`.
///
/// This store is deliberately OUTSIDE the HuggingFace cache: drafter
/// artifacts are never scanned, advertised, weight-hashed, or attested
/// (plan D3 -- with the greedy accept-walk, drafter bytes can only affect
/// speed, never output). Artifacts are keyed by a stable hash of their
/// `r2_prefix`, so multiple catalog builds pointing at one drafter artifact
/// share a single download.

import CryptoKit
import Foundation
import ProviderCoreFoundation

enum SpecDecStore {

    static let manifestFileName = "manifest.json"

    /// `~/.darkbloom/spec-dec/` -- sibling of the other provider-owned state
    /// dirs (device auth, enrollment, logs), never inside the HF cache.
    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom", isDirectory: true)
            .appendingPathComponent("spec-dec", isDirectory: true)
    }

    /// Stable directory key for an artifact prefix: first 16 hex chars of
    /// SHA-256 over the exact `r2_prefix` string. Both gemma builds carry the
    /// same prefix, hash to the same key, and share one download. The full
    /// prefix stays introspectable via the stored manifest's `r2_prefix`.
    static func key(forR2Prefix prefix: String) -> String {
        let digest = SHA256.hash(data: Data(prefix.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    static func artifactDirectory(root: URL, r2Prefix: String) -> URL {
        root.appendingPathComponent(key(forR2Prefix: r2Prefix), isDirectory: true)
    }

    /// Stable staging dir (keyed like the artifact dir, dot-prefixed) so an
    /// interrupted download resumes into the same dir -- mirroring the
    /// ModelDownloader staging convention.
    static func stagingDirectory(root: URL, r2Prefix: String) -> URL {
        root.appendingPathComponent(".staging-" + key(forR2Prefix: r2Prefix), isDirectory: true)
    }

    /// A stored copy is complete when its `manifest.json` decodes and every
    /// listed file exists with the manifest's exact size. Per-file SHA-256 was
    /// verified at download time; the warm re-resolve is size-only by design
    /// (there is no aggregate-hash enforcement for drafters, plan D3).
    static func verifiedManifest(at directory: URL) -> ModelManifest? {
        let manifestURL = directory.appendingPathComponent(manifestFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? ModelCatalogClient.manifestDecoder.decode(ModelManifest.self, from: data),
              !manifest.files.isEmpty
        else { return nil }

        let fm = FileManager.default
        for file in manifest.files {
            guard let relative = try? ModelDownloader.validatedManifestRelativePath(file.path) else {
                return nil
            }
            let onDisk = directory.appendingPathComponent(relative, isDirectory: false)
            guard let attrs = try? fm.attributesOfItem(atPath: onDisk.path),
                  let size = attrs[.size] as? Int64, size == file.sizeBytes
            else { return nil }
        }
        return manifest
    }
}
