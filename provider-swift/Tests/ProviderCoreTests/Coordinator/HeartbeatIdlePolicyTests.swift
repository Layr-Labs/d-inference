import Foundation
import Testing

@testable import ProviderCore

/// `idle_unload_mins` tells the coordinator (and the owner's dashboard) whether
/// a missing slot is "unloaded on purpose, wakes on demand" or "should be
/// loaded and isn't". Zero is the always-ready policy and MUST reach the wire;
/// only an unreported policy (nil) is omitted, so legacy heartbeats decode
/// unchanged.
@Suite("Heartbeat idle_unload_mins")
struct HeartbeatIdlePolicyTests {

    private func encodedObject(idleUnloadMins: UInt64?) throws -> [String: Any] {
        let message = CoordinatorClientCodec.heartbeatMessage(
            status: .idle,
            activeModel: nil,
            warmModels: [],
            stats: ProviderStats(requestsServed: 0, tokensGenerated: 0),
            systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
            backendCapacity: nil,
            idleUnloadMins: idleUnloadMins)
        let data = try ProviderProtocolCodec.encodeProviderMessage(message)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("always-ready (0) is encoded, not dropped as empty")
    func zeroReachesTheWire() throws {
        let object = try encodedObject(idleUnloadMins: 0)
        #expect(object["idle_unload_mins"] as? Int == 0)
    }

    @Test("a window is encoded in minutes")
    func windowIsEncoded() throws {
        let object = try encodedObject(idleUnloadMins: 60)
        #expect(object["idle_unload_mins"] as? Int == 60)
    }

    @Test("an unreported policy keeps the legacy wire shape")
    func nilIsOmitted() throws {
        let object = try encodedObject(idleUnloadMins: nil)
        #expect(object["idle_unload_mins"] == nil)
    }

    @Test("the field round-trips through the provider-message decoder")
    func roundTrip() throws {
        let message = CoordinatorClientCodec.heartbeatMessage(
            status: .serving,
            activeModel: "model-a",
            warmModels: ["model-a"],
            stats: ProviderStats(requestsServed: 1, tokensGenerated: 10),
            systemMetrics: SystemMetrics(memoryPressure: 0.1, cpuUsage: 0.2, thermalState: .nominal),
            backendCapacity: nil,
            idleUnloadMins: 45)
        let data = try ProviderProtocolCodec.encodeProviderMessage(message)
        let decoded = try JSONDecoder().decode(ProviderMessage.self, from: data)
        guard case .heartbeat(let heartbeat) = decoded else {
            Issue.record("expected a heartbeat, got \(decoded)")
            return
        }
        #expect(heartbeat.idleUnloadMins == 45)

        // Legacy heartbeat without the key: nil, never a defaulted 0 or 60.
        let legacy = Data("""
            {"type":"heartbeat","status":"idle","stats":{"requests_served":0,"tokens_generated":0},\
            "system_metrics":{"memory_pressure":0,"cpu_usage":0,"thermal_state":"nominal"}}
            """.utf8)
        guard case .heartbeat(let old) = try JSONDecoder().decode(ProviderMessage.self, from: legacy) else {
            Issue.record("expected a heartbeat")
            return
        }
        #expect(old.idleUnloadMins == nil)
    }

    @Test("the client config carries the policy into every heartbeat")
    func clientConfigCarriesPolicy() {
        let hardware = HardwareInfo(
            machineModel: "Mac16,5",
            chipName: "Apple M4 Max",
            chipFamily: .m4,
            chipTier: .max,
            memoryGb: 128,
            memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40,
            memoryBandwidthGbs: 546)
        let config = CoordinatorClientConfig(
            url: "wss://example.invalid/ws/provider",
            hardware: hardware,
            models: [],
            backendName: "mlx-swift",
            idleUnloadMins: 0)
        #expect(config.idleUnloadMins == 0)

        let unset = CoordinatorClientConfig(
            url: "wss://example.invalid/ws/provider",
            hardware: hardware,
            models: [],
            backendName: "mlx-swift")
        #expect(unset.idleUnloadMins == nil)
    }
}
