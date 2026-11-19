import Foundation
import Testing
@testable import ProviderCore

@Suite struct ProviderAuthorizationProtocolTests {
    @Test func periodicRenewalsRetainTheSameDiagnosticDecision() {
        let original = ProviderAuthorizationStatus(appAttestAvailable: true, path: "app_attest",
                                                  expiresAt: 130,
                                                  sessionID: "session", machineID: "machine")
        var renewed = original
        renewed.expiresAt = 135
        #expect(ProviderAuthorizationStatus.sameDiagnosticDecision(original, renewed))
        renewed.reason = "renewed"
        #expect(!ProviderAuthorizationStatus.sameDiagnosticDecision(original, renewed))
        #expect(!ProviderAuthorizationStatus.sameDiagnosticDecision(original, nil))
        #expect(ProviderAuthorizationStatus.sameDiagnosticDecision(nil, nil))
    }

    /// Unknown authorization keys from a coordinator or a state file are
    /// ignored on input and never written back.
    @Test func unknownAuthorizationKeysAreIgnored() throws {
        let data = Data(#"{"protocol":1,"app_attest_available":true,"path":"app_attest","expires_at":130,"retired_flag":true,"reason":"qualified","session_id":"s","machine_id":"m"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProviderAuthorizationStatus.self, from: data)
        #expect(decoded.hasCurrentAppAttestAuthorization(now: 100))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(object["retired_flag"] == nil)
    }

    @Test func legacyCoordinatorStatusRemainsCompatible() throws {
        let data = Data(#"{"type":"trust_status","trust_level":"hardware","status":"online"}"#.utf8)
        guard case .trustStatus(let status) = try ProviderProtocolCodec.decodeCoordinatorMessage(from: data) else {
            Issue.record("expected trust status"); return
        }
        #expect(status.authorization == nil)
        let encoded = try JSONEncoder().encode(CoordinatorMessage.trustStatus(status))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["authorization"] == nil)
    }

    @Test func authorizationUsesTheCanonicalWireKeys() throws {
        let data = Data(#"{"type":"trust_status","trust_level":"self_signed","status":"online","authorization":{"protocol":1,"app_attest_available":true,"path":"app_attest","expires_at":130,"reason":"qualified","session_id":"session","machine_id":"machine"}}"#.utf8)
        guard case .trustStatus(let status) = try ProviderProtocolCodec.decodeCoordinatorMessage(from: data) else {
            Issue.record("expected trust status"); return
        }
        let authorization = try #require(status.authorization)
        #expect(authorization.hasCurrentAppAttestAuthorization(now: 100))
        #expect(authorization.sessionID == "session")
        #expect(authorization.machineID == "machine")
        let encoded = try JSONEncoder().encode(CoordinatorMessage.trustStatus(status))
        #expect(try JSONDecoder().decode(CoordinatorMessage.self, from: encoded) == .trustStatus(status))
        let root = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let object = try #require(root["authorization"] as? [String: Any])
        #expect(object["protocol"] as? Int == 1)
        #expect(object["app_attest_available"] as? Bool == true)
        #expect(object["expires_at"] as? Int == 130)
        #expect(object["session_id"] as? String == "session")
        #expect(object["machine_id"] as? String == "machine")
        #expect(object["protocol_version"] == nil)
    }
}
