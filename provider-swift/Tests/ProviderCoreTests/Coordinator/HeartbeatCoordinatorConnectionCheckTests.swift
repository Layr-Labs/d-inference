import Foundation
import Testing

@testable import ProviderCore

/// Heartbeats report how the current coordinator connection compares with the
/// build's coordinator host and certificate authorities
/// (`coordinator_connection_check`), so the coordinator can count it by
/// provider version. Until the comparison ends, and for a connection without
/// TLS, the key is omitted and the heartbeat keeps its earlier shape.
@Suite("Heartbeat coordinator_connection_check")
struct HeartbeatCoordinatorConnectionCheckTests {
    @Test func eachCombinationOfDifferencesIsOneReport() {
        #expect(CoordinatorServerPin.Report([]) == .matches)
        #expect(CoordinatorServerPin.Report([.host]) == .hostDiffers)
        #expect(CoordinatorServerPin.Report([.certificateKey]) == .certificateDiffers)
        #expect(CoordinatorServerPin.Report([.host, .certificateKey]) == .hostAndCertificateDiffer)
        #expect(CoordinatorServerPin.Report([.certificateKey, .host]) == .hostAndCertificateDiffer)
        #expect([CoordinatorServerPin.Report.matches, .hostDiffers, .certificateDiffers, .hostAndCertificateDiffer]
            .map(\.rawValue) == ["matches", "host_differs", "certificate_differs", "host_and_certificate_differ"])
    }

    @Test func aConnectionReportIsEmptyUntilItsComparisonEnds() {
        let report = CoordinatorServerPin.ConnectionReport()
        #expect(report.value == nil)
        report.record(.certificateDiffers)
        #expect(report.value == .certificateDiffers)
        #expect(CoordinatorServerPin.ConnectionReport().value == nil)
    }

    @Test func theCheckRoundTripsAndIsOmittedWhenUnknown() throws {
        for check in [nil, "matches", "host_and_certificate_differ"] as [String?] {
            let data = try ProviderProtocolCodec.encodeProviderMessage(heartbeat(check: check))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["coordinator_connection_check"] as? String == check)
            #expect(object.keys.contains("coordinator_connection_check") == (check != nil))
            guard case .heartbeat(let decoded) = try JSONDecoder().decode(ProviderMessage.self, from: data) else {
                Issue.record("expected a heartbeat")
                return
            }
            #expect(decoded.coordinatorConnectionCheck == check)
        }
    }

    /// The client's heartbeat carries the current connection's report once it
    /// has one.
    @Test func theClientHeartbeatCarriesTheCurrentConnectionsReport() async throws {
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: "wss://api.darkbloom.dev/ws/provider",
                hardware: HardwareInfo(
                    machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                    memoryGb: 128, memoryAvailableGb: 124,
                    cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                    gpuCores: 40, memoryBandwidthGbs: 546),
                models: [], backendName: "mlx-swift"),
            stats: AtomicProviderStats(), state: ProviderState(), liveAPNsToken: { nil })
        #expect(try object(try #require(await client.buildHeartbeatJSON()))["coordinator_connection_check"] == nil)
        await client.coordinatorConnectionReport.record(.hostDiffers)
        #expect(try object(try #require(await client.buildHeartbeatJSON()))["coordinator_connection_check"] as? String
            == "host_differs")
    }

    private func heartbeat(check: String?) -> ProviderMessage {
        CoordinatorClientCodec.heartbeatMessage(
            status: .idle, activeModel: nil, warmModels: [],
            stats: ProviderStats(requestsServed: 0, tokensGenerated: 0),
            systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
            backendCapacity: nil, coordinatorConnectionCheck: check)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
