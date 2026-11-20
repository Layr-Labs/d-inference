import Foundation
import Testing

@testable import ProviderCore

/// `register` says request resume v1 (`request_resume_protocol: 1`) and lists the held resume ids
/// (`resumable_requests`), on the Codable path and on the raw-attestation path that attested registrations take.
@Suite("Request resume on register")
struct RequestResumeRegistrationTests {
    static func ids(_ count: Int) -> [String] {
        (0..<count).map { String(format: "%064lx", $0) }
    }

    @Test(arguments: [false, true]) func registerSaysResumeV1AndListsTheHeldRequests(rawAttestation: Bool) throws {
        let config = AppAttestResumeFixture.config(attestation: rawAttestation
            ? RawJSON(rawBytes: Data(#"{"signature":"fixture"}"#.utf8)) : nil)
        #expect(RequestResume.registerProtocolKey == "request_resume_protocol")
        #expect(RequestResume.registerHeldKey == "resumable_requests")
        for held in [[], Self.ids(2), Self.ids(70)] {
            let data = try CoordinatorClientCodec.encodeRegistration(from: config, resumableRequests: held)
            let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(fields["request_resume_protocol"] as? Int == 1)
            // `held` is newest first, as the loop publishes it: the first 64 are the newest.
            let expected = held.isEmpty ? nil : Array(held.prefix(64))
            #expect(fields["resumable_requests"] as? [String] == expected,
                    "omitted when empty; newest first, the newest 64 at most")
            guard case .register(let decoded) = try ProviderProtocolCodec.decodeProviderMessage(from: data) else {
                Issue.record("expected register"); return
            }
            #expect(decoded.requestResumeProtocol == 1)
            #expect(decoded.resumableRequests == expected)
        }
    }

    /// A cluster member never says resume v1 and lists nothing: pair and cluster requests are never resumed.
    @Test func aMemberNeverSaysResumeV1() throws {
        let config = CoordinatorClientConfig(url: "ws://127.0.0.1:1/ws/provider", hardware: HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546), models: [], backendName: "mlx-swift",
            executionRole: .clusterMember)
        guard case .register(let register) = CoordinatorClientCodec.registrationMessage(
            from: config, resumableRequests: Self.ids(2)) else {
            Issue.record("expected register"); return
        }
        #expect(register.requestResumeProtocol == nil)
        #expect(register.resumableRequests == nil)
    }

    /// `resumed` rides only the terminal usage of a dispatch that took a held answer.
    @Test func usageSaysResumedOnlyWhenItWas() throws {
        var usage = UsageInfo(promptTokens: 3, completionTokens: 2)
        let plain = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)) as? [String: Any])
        #expect(plain["resumed"] == nil)
        usage.resumed = true
        let resumed = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)) as? [String: Any])
        #expect(resumed["resumed"] as? Bool == true)
        #expect(try JSONDecoder().decode(UsageInfo.self, from: JSONEncoder().encode(usage)) == usage)
    }
}
