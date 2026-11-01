import Foundation
import Testing

@testable import ProviderCore

/// `busy_reason`, `busy_since_ms` and `busy_addon` are optional and omitted
/// when not busy, so legacy frames stay byte-identical; older coordinators
/// still stop routing on `status: draining`.
@Suite("Provider busy wire fields")
struct ProviderBusyWireTests {
    private static let busy = ProviderBusy(reason: .addon, sinceMs: 1_800_000_000_123, addon: "io.darkbloom.sandbox")
    private static let hardware = HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 64, memoryAvailableGb: 60, cpuCores: .init(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)

    private func object(_ message: ProviderMessage) throws -> [String: Any] {
        let data = try ProviderProtocolCodec.encodeProviderMessage(message)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func heartbeat(status: ProviderStatus, busy: ProviderBusy?) -> ProviderMessage {
        CoordinatorClientCodec.heartbeatMessage(
            status: status, activeModel: nil, warmModels: [],
            stats: ProviderStats(requestsServed: 0, tokensGenerated: 0),
            systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
            backendCapacity: nil, busy: busy)
    }

    private func register(attestation: RawJSON?, busy: ProviderBusy?) -> ProviderMessage {
        CoordinatorClientCodec.registrationMessage(
            from: CoordinatorClientConfig(url: "ws://127.0.0.1:0/ws/provider", hardware: Self.hardware,
                                          models: [], backendName: "mlx-swift", attestation: attestation),
            busy: busy)
    }

    @Test func heartbeatCarriesBusyFieldsBesideDraining() throws {
        let json = try object(heartbeat(status: .draining, busy: Self.busy))
        #expect(json["status"] as? String == "draining")
        #expect(json["busy_reason"] as? String == "addon")
        #expect((json["busy_since_ms"] as? NSNumber)?.int64Value == 1_800_000_000_123)
        #expect(json["busy_addon"] as? String == "io.darkbloom.sandbox")

        let idle = try object(heartbeat(status: .idle, busy: nil))
        for key in ["busy_reason", "busy_since_ms", "busy_addon"] { #expect(idle[key] == nil) }
    }

    @Test func registerCarriesBusyFieldsOnBothEncodingPaths() throws {
        let attestation = RawJSON(rawBytes: Data(#"{"signature":"fixture"}"#.utf8))
        for raw in [nil, attestation] {
            let json = try object(register(attestation: raw, busy: Self.busy))
            #expect(json["busy_reason"] as? String == "addon", "attested: \(raw != nil)")
            #expect((json["busy_since_ms"] as? NSNumber)?.int64Value == 1_800_000_000_123)
            #expect(json["busy_addon"] as? String == "io.darkbloom.sandbox")
            let plain = try object(register(attestation: raw, busy: nil))
            for key in ["busy_reason", "busy_since_ms", "busy_addon"] { #expect(plain[key] == nil) }
        }
    }

    @Test func busyFieldsRoundTripAndUnknownReasonsDecodeAsAbsent() throws {
        for message in [heartbeat(status: .draining, busy: Self.busy), register(attestation: nil, busy: Self.busy)] {
            let decoded = try ProviderProtocolCodec.decodeProviderMessage(
                from: ProviderProtocolCodec.encodeProviderMessage(message))
            switch decoded {
            case .heartbeat(let heartbeat): #expect(heartbeat.busy == Self.busy)
            case .register(let register): #expect(register.busy == Self.busy)
            default: Issue.record("unexpected \(decoded)")
            }
        }
        let future = Data("""
            {"type":"heartbeat","status":"draining","busy_reason":"maintenance","busy_since_ms":1,\
            "stats":{"requests_served":0,"tokens_generated":0},\
            "system_metrics":{"memory_pressure":0,"cpu_usage":0,"thermal_state":"nominal"}}
            """.utf8)
        guard case .heartbeat(let heartbeat) = try ProviderProtocolCodec.decodeProviderMessage(from: future) else {
            Issue.record("expected a heartbeat")
            return
        }
        #expect(heartbeat.busy == nil && heartbeat.status == .draining)
    }

    @Test func theClientSendsBusyFieldsOnlyBesideADrainingStatus() async throws {
        let state = ProviderState()
        let client = CoordinatorClient(
            config: .init(url: "ws://127.0.0.1:0/ws/provider", hardware: Self.hardware, models: [],
                          backendName: "mlx-swift"),
            stats: AtomicProviderStats(), state: state, liveAPNsToken: { nil })
        state.busy = Self.busy
        state.refusingNewWork = true
        let draining = try #require(JSONSerialization.jsonObject(with: Data(await client.buildHeartbeatJSON().utf8)) as? [String: Any])
        #expect(draining["status"] as? String == "draining" && draining["busy_addon"] as? String == "io.darkbloom.sandbox")
        // A stale busy value never rides a routable status.
        state.refusingNewWork = false
        let idle = try #require(JSONSerialization.jsonObject(with: Data(await client.buildHeartbeatJSON().utf8)) as? [String: Any])
        #expect(idle["status"] as? String == "idle" && idle["busy_reason"] == nil)
    }
}
