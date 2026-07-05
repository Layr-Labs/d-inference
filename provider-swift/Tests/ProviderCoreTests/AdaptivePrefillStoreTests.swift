import Foundation
import Testing
@testable import ProviderCore

@Suite("Adaptive prefill store + migration")
struct AdaptivePrefillStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-prefill-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private func key(
        model: String = "model-a",
        policyIdentity: String = AdaptivePrefillPolicy.algorithmIdentity
    ) -> AdaptivePrefillStoreKey {
        AdaptivePrefillStoreKey(
            modelId: model, weightIdentity: "weight-a", kvMode: "fp16",
            hardwareMemoryFingerprint: "mem-a", policyIdentity: policyIdentity)
    }

    @Test("round-trips via a hashed key that never leaks the model id")
    func roundTripHashed() throws {
        let url = tempURL()
        let store = AdaptivePrefillStore(url: url)
        let k = key()
        try store.save(AdaptivePrefillState(currentChunkSize: 1536), key: k)

        #expect(store.load(key: k)?.currentChunkSize == 1536)
        let raw = try String(contentsOf: url)
        #expect(!raw.contains("model-a"))
        #expect(raw.contains("\"version\":2"))
    }

    @Test("a v1 file is ignored on load (clean re-seed)")
    func v1FileIgnored() throws {
        let url = tempURL()
        let k = key()
        // Hand-write a structurally valid v1 file under this key's hash.
        let file: [String: Any] = [
            "version": 1,
            "states": [k.storageKey: ["currentChunkSize": 1024]],
        ]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: file).write(to: url)

        #expect(AdaptivePrefillStore(url: url).load(key: k) == nil)
    }

    @Test("policy identity namespaces the key — an algorithm change misses old entries")
    func policyIdentityNamespacesKey() throws {
        let url = tempURL()
        let store = AdaptivePrefillStore(url: url)
        let current = key(policyIdentity: AdaptivePrefillPolicy.algorithmIdentity)
        let legacy = key(policyIdentity: "duration.v1")

        try store.save(AdaptivePrefillState(currentChunkSize: 2048), key: legacy)
        #expect(store.load(key: legacy)?.currentChunkSize == 2048)
        #expect(store.load(key: current) == nil)          // different hash namespace
        #expect(current.storageKey != legacy.storageKey)
    }

    @Test("different chip fingerprints do not share learned rungs")
    func fingerprintIsolation() throws {
        let url = tempURL()
        let store = AdaptivePrefillStore(url: url)
        let m4 = AdaptivePrefillStoreKey(
            modelId: "m", weightIdentity: "w", kvMode: "fp16",
            hardwareMemoryFingerprint: "chip:Apple M4 Max")
        let m5 = AdaptivePrefillStoreKey(
            modelId: "m", weightIdentity: "w", kvMode: "fp16",
            hardwareMemoryFingerprint: "chip:Apple M5 Max")
        try store.save(AdaptivePrefillState(currentChunkSize: 1536), key: m4)
        #expect(store.load(key: m5) == nil)
    }
}
