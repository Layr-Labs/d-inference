import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// The two-Mac prefix cache's SSD key from the product's KEK: a fixed,
/// domain-separated derivation, and nil (never an ephemeral key) when the
/// KEK cannot be loaded. These tests inject the loader: none touches the
/// keychain or the Secure Enclave.
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
