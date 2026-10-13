import Foundation
import Testing

@testable import ProviderCore

@Suite("Local checkpoint precision observations")
struct KVCheckpointPostureTests {
    @Test func builderPreservesEffectivePrecisionAndLayout() throws {
        let slots = DaemonSlotPostureBuilder.build(
            live: [.init(model: "model", kvBackend: "contiguous",
                         kvQuantization: "native", kvCheckpointQuantization: "balanced",
                         checkpointBackendLayout: "compressed-native-test-layout",
                         mtpEnabled: false, mtpActive: false, mtpInactiveReason: nil)],
            requestedGlobal: "auto", requestedByModel: [:], lastModelLoadError: nil)
        let slot = try #require(slots.first)
        #expect(slot.kvQuantization == "native")
        #expect(slot.kvCheckpointQuantization == "balanced")
        #expect(slot.checkpointBackendLayout == "compressed-native-test-layout")
        #expect(try JSONDecoder().decode(DaemonState.SlotPosture.self, from: JSONEncoder().encode(slot)) == slot)
    }

    @Test func olderStateDoesNotInventPrecision() throws {
        let old = Data("""
            {"model":"model","kvBackend":"contiguous","kvBackendRequested":"auto",
             "mtpEnabled":false,"mtpActive":false}
            """.utf8)
        let slot = try JSONDecoder().decode(DaemonState.SlotPosture.self, from: old)
        #expect(slot.kvQuantization == nil)
        #expect(slot.kvCheckpointQuantization == nil)
        #expect(slot.checkpointBackendLayout == nil)
    }
}
