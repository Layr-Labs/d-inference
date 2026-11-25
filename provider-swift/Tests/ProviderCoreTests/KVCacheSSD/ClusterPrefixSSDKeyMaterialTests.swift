import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// The two-Mac prefix cache's SSD key from the product's KEK: a fixed,
/// domain-separated derivation, and nil (never an ephemeral key) when the
/// KEK cannot be loaded. The owner then uses a key of its own process that is
/// never written. These tests inject the loader: none touches the keychain or
/// the Secure Enclave.
@Suite("Cluster prefix SSD key material")
struct ClusterPrefixSSDKeyMaterialTests {
    private let kek = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))

    @Test func derivationIsStableAndSeparatedFromTheKEK() {
        let first = ClusterPrefixSSDKeyMaterial.derive(from: kek)
        let second = ClusterPrefixSSDKeyMaterial.derive(from: kek)
        #expect(first.count == 32)
        #expect(first == second)
        #expect(first != kek.withUnsafeBytes { Data($0) })
        let reference = HKDF<SHA256>.deriveKey(inputKeyMaterial: kek, salt: Data("darkbloom-cluster-prefix-ssd-v1".utf8),
            info: Data("owner-key".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        #expect(first == reference)
        let other = ClusterPrefixSSDKeyMaterial.derive(from: SymmetricKey(data: Data(repeating: 7, count: 32)))
        #expect(other != first)
    }

    @Test func loadDerivesFromTheLoadedKEK() {
        let key = kek
        let loaded = ClusterPrefixSSDKeyMaterial.load(timeoutSeconds: 5, loader: { key })
        #expect(loaded == ClusterPrefixSSDKeyMaterial.derive(from: kek))
    }

    @Test func unavailableKEKYieldsNil() {
        struct Unavailable: Error {}
        #expect(ClusterPrefixSSDKeyMaterial.load(timeoutSeconds: 5, loader: { throw Unavailable() }) == nil)
    }

    /// Without the derived key the owner's key is its own process's: no key file is created, and one an earlier
    /// build left on disk is deleted, never used.
    @Test func ownerKeyWithoutTheDerivedKeyIsNeverAFile() throws {
        // The real path: a directory reached through a symbolic link (/var) is refused before any file is read,
        // which would hide a key file the owner reads.
        let temporary = FileManager.default.temporaryDirectory.path
        let resolved = realpath(temporary, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? temporary
        let root = URL(fileURLWithPath: resolved, isDirectory: true).appendingPathComponent("prefix-owner-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        let written = root.appendingPathComponent("written", isDirectory: true)
        for directory in [empty, written] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let earlier = written.appendingPathComponent("prefix-ssd-v1.key")
        let earlierText = Data((String(repeating: "ab", count: 32) + "\n").utf8)
        try earlierText.write(to: earlier)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: earlier.path)
        DistributedInstalledPrefixSSD.installDurableKeySource { nil }
        defer { DistributedInstalledPrefixSSD.installDurableKeySource { nil } }
        for directory in [empty, written] {
            #expect(DistributedInstalledPrefixSSD.ownerKey(deviceDirectory: directory)
                == .process(DistributedInstalledPrefixSSD.processKey))
        }
        #expect(!FileManager.default.fileExists(atPath: empty.appendingPathComponent("prefix-ssd-v1.key").path))
        #expect(!FileManager.default.fileExists(atPath: earlier.path))
    }

    @Test func slowKEKYieldsNilWithinTheBound() {
        let key = kek
        let start = Date()
        let loaded = ClusterPrefixSSDKeyMaterial.load(timeoutSeconds: 0.2, loader: {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return key
        })
        #expect(loaded == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
