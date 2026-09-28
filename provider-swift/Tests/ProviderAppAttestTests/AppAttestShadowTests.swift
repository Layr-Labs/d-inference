import Foundation
import XCTest
@testable import ProviderAppAttest

private actor FakeService: AppAttestService {
    var generated = 0
    var attested = 0
    var asserted = 0
    var failure: ShadowFailure?
    init(failure: ShadowFailure? = nil) { self.failure = failure }
    func checkAvailability(environment: String) throws { if let failure { throw failure } }
    func generateKey() -> String { generated += 1; return Data(repeating: 1, count: 32).base64EncodedString() }
    func attestKey(_ id: String, hash: Data) -> Data { attested += 1; return Data("attestation".utf8) }
    func generateAssertion(_ id: String, hash: Data) -> Data { asserted += 1; return Data("assertion".utf8) }
    func counts() -> [Int] { [generated, attested, asserted] }
    func operationHeldSince() -> Date? { nil }
}

private actor DiagnosticService: AppAttestService {
    let availabilityFailure: AppAttestAvailabilityFailure?
    let attestationError: AppAttestAppleErrorSource?
    let assertionError: AppAttestAppleErrorSource?
    let oversizedProof: Bool

    init(availabilityFailure: AppAttestAvailabilityFailure? = nil,
         attestationError: AppAttestAppleErrorSource? = nil,
         assertionError: AppAttestAppleErrorSource? = nil,
         oversizedProof: Bool = false) {
        self.availabilityFailure = availabilityFailure
        self.attestationError = attestationError
        self.assertionError = assertionError
        self.oversizedProof = oversizedProof
    }

    func checkAvailability(environment: String) throws {
        if let availabilityFailure { throw availabilityFailure }
    }
    func generateKey() -> String { Data(repeating: 1, count: 32).base64EncodedString() }
    func attestKey(_ id: String, hash: Data) throws -> Data {
        if let attestationError { throw attestationError }
        return Data("attestation".utf8)
    }
    func generateAssertion(_ id: String, hash: Data) throws -> Data {
        if let assertionError { throw assertionError }
        return oversizedProof ? Data(repeating: 0, count: 32 * 1024 + 1) : Data("assertion".utf8)
    }
    func operationHeldSince() -> Date? { nil }
}

private final class MemoryKeys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ShadowKeyRecord] = [:]
    func load(scope: String) -> ShadowKeyRecord? { lock.lock(); defer { lock.unlock() }; return records[scope] }
    func save(_ record: ShadowKeyRecord, scope: String) { lock.lock(); defer { lock.unlock() }; records[scope] = record }
}

private final class FailCleanupKeys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ShadowKeyRecord] = [:]
    private var savesUntilFailure = 0

    func failSecondSaveAfterArming() {
        lock.lock(); defer { lock.unlock() }
        savesUntilFailure = 2
    }

    func load(scope: String) -> ShadowKeyRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[scope]
    }

    func save(_ record: ShadowKeyRecord, scope: String) throws {
        lock.lock(); defer { lock.unlock() }
        if savesUntilFailure > 0 {
            savesUntilFailure -= 1
            if savesUntilFailure == 0 { throw ShadowFailure.keychainError }
        }
        records[scope] = record
    }
}

private struct UnwritableKeys: ShadowKeyStorage {
    func load(scope: String) -> ShadowKeyRecord? { nil }
    func save(_ record: ShadowKeyRecord, scope: String) throws { throw ShadowFailure.keychainError }
}

final class AppAttestShadowTests: XCTestCase {
    let session = Data(repeating: 0, count: 32).base64EncodedString()
    let publicKey = Data(repeating: 3, count: 32).base64EncodedString()

    func request(_ action: String, key: String? = nil, account: String = String(repeating: "a", count: 64)) -> AppAttestShadowPayload {
        var p = AppAttestShadowPayload(action: action, session: session)
        p.protocolVersion = 3; p.accountScope = account
        p.environment = "production"; p.keyID = key
        if action != "prepare" { p.challenge = Data(repeating: 2, count: 32).base64EncodedString() }
        return p
    }

    // The provider registers app_attest_protocol 3 only; any other version is
    // refused before Apple or Keychain work.
    func testOnlyProtocolThreeIsServed() async {
        for version in [nil, 1, 2] as [Int?] {
            let service = FakeService()
            let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
            var prepare = request("prepare"); prepare.protocolVersion = version
            let reply = await client.respond(to: prepare, publicKey: publicKey)
            XCTAssertEqual(reply.result, "invalid_request", "protocol \(String(describing: version))")
            let counts = await service.counts(); XCTAssertEqual(counts, [0, 0, 0])
        }
    }

    func testUnwritableKeychainDoesNotCreateKeys() async {
        let service = FakeService()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: UnwritableKeys())
        let response = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(response.result, "keychain_error")
        let counts = await service.counts(); XCTAssertEqual(counts, [0, 0, 0])
    }

    func testUnsupportedDoesNotCreateKeys() async {
        let service = FakeService(failure: .unsupported)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
        let response = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(response.result, "unsupported")
        let counts = await service.counts(); XCTAssertEqual(counts, [0, 0, 0])
    }

    func testClosedAvailabilityReasonDoesNotChangeUnsupportedResult() async {
        let service = DiagnosticService(availabilityFailure: AppAttestAvailabilityFailure(
            failure: .unsupported, reason: .isSupportedFalse))
        let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
        let response = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(response.result, "unsupported")
        XCTAssertEqual(response.availabilityReason, .isSupportedFalse)
        XCTAssertNil(response.appleError)
        XCTAssertNil(response.appleErrorSource)
    }

    func testSyntheticAppleErrorSourcesDoNotChangeResultOrSignedTranscript() async {
        for (source, oversized) in [(AppAttestAppleErrorSource.callbackWithoutNSError, false),
                                     (.proofOversize, true)] {
            let service = DiagnosticService(assertionError: oversized ? nil : source, oversizedProof: oversized)
            let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
            let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
            let attested = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey, status: shadowStatus)
            XCTAssertEqual(attested.result, "ok")
            let assertionRequest = request("assert", key: ready.keyID)
            let response = await client.respond(to: assertionRequest, publicKey: publicKey, status: shadowStatus)
            XCTAssertEqual(response.result, "apple_error")
            XCTAssertEqual(response.appleErrorSource, source)
            XCTAssertNil(response.appleError)
            XCTAssertNil(response.availabilityReason)
            var withoutDiagnostics = response
            withoutDiagnostics.appleErrorSource = nil
            XCTAssertEqual(response.clientHash(publicKey: publicKey), withoutDiagnostics.clientHash(publicKey: publicKey))
        }
    }

    func testCleanupWriteFailureClearsSyntheticAppleErrorSource() async throws {
        let storage = FailCleanupKeys()
        let service = DiagnosticService(attestationError: .callbackWithoutNSError)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(ready.result, "ok")
        storage.failSecondSaveAfterArming()

        let response = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey, status: shadowStatus)
        XCTAssertEqual(response.result, "keychain_error")
        XCTAssertNil(response.appleError)
        XCTAssertNil(response.availabilityReason)
        XCTAssertNil(response.appleErrorSource)
        let body = try JSONEncoder().encode(response)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("apple_error_source"))
    }

    func testPersistentKeySurvivesReconnectAndOnlyAttestsOnce() async {
        let service = FakeService(); let storage = MemoryKeys()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(ready.result, "ok")
        let proof = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey, status: shadowStatus)
        XCTAssertEqual(proof.result, "ok")
        let assertion = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey, status: shadowStatus)
        XCTAssertEqual(assertion.result, "ok")
        let restarted = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let next = await restarted.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(next.keyID, ready.keyID)
        let nextProof = await restarted.respond(to: request("assert", key: next.keyID), publicKey: publicKey, status: shadowStatus)
        XCTAssertEqual(nextProof.result, "ok")
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 1, 2])
    }

    func testWrongSessionOrKeyCannotSign() async {
        let service = FakeService()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        var bad = request("assert", key: ready.keyID); bad.session = Data(repeating: 9, count: 32).base64EncodedString()
        let response = await client.respond(to: bad, publicKey: publicKey, status: shadowStatus)
        XCTAssertEqual(response.result, "invalid_request")
        bad = request("assert", key: Data(repeating: 8, count: 32).base64EncodedString())
        let other = await client.respond(to: bad, publicKey: publicKey, status: shadowStatus)
        XCTAssertEqual(other.result, "invalid_request")
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 0, 0])
    }

    func testUnknownEnrolledKeyCannotCauseRapidKeyChurn() async {
        let service = FakeService()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        _ = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey, status: shadowStatus)
        // The first assertion consumes the cached enrollment proof; a later
        // attest for the now-used key cannot be replayed or re-enrolled.
        _ = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey, status: shadowStatus)
        let retry = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey, status: shadowStatus)
        XCTAssertEqual(retry.result, "key_unregistered")
        let prepared = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(prepared.result, "busy")
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 1, 1])
    }

    func testTranscriptMatchesGoVectorAndBindsEndpoint() throws {
        var p = request("assert", key: Data(repeating: 1, count: 32).base64EncodedString())
        p.status = hardwareStatus
        let hash = p.clientHash(publicKey: publicKey).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "e654e820b8dcd646201bb43de1cba0e0e56dff697f2ee62534bf28fe143bbf17")
        XCTAssertNotEqual(p.clientHash(publicKey: publicKey), p.clientHash(publicKey: Data(repeating: 4, count: 32).base64EncodedString()))
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(AppAttestShadowPayload.self, from: data), p)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["encrypted_challenge"])
        XCTAssertNotNil(object["key_id"])
    }

    func testClosedDiagnosticWireFieldsAreOptionalAndOutsideClientHash() throws {
        var payload = request("prepare")
        payload.result = "not_configured"
        let originalHash = payload.clientHash(publicKey: publicKey)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertNil(plain["availability_reason"])
        XCTAssertNil(plain["apple_error_source"])

        payload.availabilityReason = .signingInfoUnavailable
        payload.appleErrorSource = .callbackWithoutNSError
        let encoded = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["availability_reason"] as? String, "signing_info_unavailable")
        XCTAssertEqual(object["apple_error_source"] as? String, "callback_without_nserror")
        XCTAssertEqual(try JSONDecoder().decode(AppAttestShadowPayload.self, from: encoded), payload)
        XCTAssertEqual(payload.clientHash(publicKey: publicKey), originalHash)

        let unknown = Data(String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "signing_info_unavailable", with: "arbitrary_user_input").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppAttestShadowPayload.self, from: unknown))
    }

    func testRuntimeDiagnosticsUseSnakeCaseAndNeverChangeAnySignedTranscript() throws {
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request("prepare"))) as? [String: Any])
        let unset = ["launch_session", "boot_time", "operation_stalled_seconds", "process_started_at", "previous_exit",
                     "start_reason", "console_user_active", "sip_enabled", "authenticated_root", "preflight",
                     "key_history", "push_history", "native_error_chain"]
        for key in unset { XCTAssertNil(plain[key], key) }

        // Both signed actions (with and without hardware facts) and a ready reply.
        var payloads: [AppAttestShadowPayload] = [request("assert", key: Data(repeating: 1, count: 32).base64EncodedString())]
        var attest = request("attest", key: Data(repeating: 1, count: 32).base64EncodedString()); attest.status = shadowStatus
        var assert = attest; assert.action = "assert"; assert.status = hardwareStatus
        payloads += [attest, assert, request("prepare")]
        for var payload in payloads {
            let original = payload.clientHash(publicKey: publicKey)
            payload.launchSession = .background
            payload.bootTime = 1_789_430_804
            payload.operationStalledSeconds = 901
            payload.result = "busy"
            payload.attachAllDeepDiagnostics()
            XCTAssertEqual(payload.clientHash(publicKey: publicKey), original)
            let encoded = try JSONEncoder().encode(payload)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["launch_session"] as? String, "background")
            XCTAssertEqual(object["boot_time"] as? Int, 1_789_430_804)
            XCTAssertEqual(object["operation_stalled_seconds"] as? Int, 901)
            XCTAssertEqual(object["process_started_at"] as? Int, 1_789_430_900)
            XCTAssertEqual(object["previous_exit"] as? String, "unclean")
            XCTAssertEqual(object["start_reason"] as? String, "stall_restart")
            XCTAssertEqual(object["console_user_active"] as? Bool, true)
            XCTAssertEqual(object["sip_enabled"] as? Bool, false)
            XCTAssertEqual(object["authenticated_root"] as? Bool, true)
            let preflight = try XCTUnwrap(object["preflight"] as? [String: Any])
            XCTAssertEqual(preflight["opt_in_entitlement"] as? Bool, true)
            XCTAssertEqual(preflight["environment_entitlement"] as? String, "absent")
            XCTAssertEqual(preflight["profile_present"] as? Bool, true)
            XCTAssertEqual(preflight["profile_expired"] as? Bool, false)
            XCTAssertEqual(preflight["bundle_path_class"] as? String, "user_install")
            let history = try XCTUnwrap(object["key_history"] as? [String: Any])
            XCTAssertEqual(history["generations_last_24h"] as? Int, 3)
            XCTAssertEqual(history["last_generation_age_seconds"] as? Int, 60)
            XCTAssertEqual(history["last_success_age_seconds"] as? Int, 0)
            XCTAssertEqual(history["consecutive_assertion_failures"] as? Int, 2)
            XCTAssertEqual(history["key_age_seconds"] as? Int, 7200)
            XCTAssertEqual(history["created_boot_matches"] as? Bool, false)
            XCTAssertEqual(history["created_app_version"] as? String, "0.9.9")
            let push = try XCTUnwrap(object["push_history"] as? [String: Any])
            XCTAssertEqual(push["device_token_present"] as? Bool, false)
            XCTAssertEqual(push["pushes_received_last_24h"] as? Int, 0)
            XCTAssertEqual(push["last_push_received_age_seconds"] as? Int, 86_400)
            XCTAssertEqual(push["last_reply_sent_age_seconds"] as? Int, 90_000)
            let chain = try XCTUnwrap(object["native_error_chain"] as? [[String: Any]])
            XCTAssertEqual(chain.map { $0["domain"] as? String }, ["devicecheck", "cryptotokenkit", "aks"])
            XCTAssertEqual(chain.map { $0["code"] as? Int }, [0, -3, -536_362_989])
            XCTAssertEqual(try JSONDecoder().decode(AppAttestShadowPayload.self, from: encoded), payload)
        }
        // The pinned Go vector is unchanged with diagnostics present.
        var pinned = request("assert", key: Data(repeating: 1, count: 32).base64EncodedString())
        pinned.status = hardwareStatus
        pinned.launchSession = .gui; pinned.bootTime = 1
        pinned.attachAllDeepDiagnostics()
        XCTAssertEqual(pinned.clientHash(publicKey: publicKey).map { String(format: "%02x", $0) }.joined(),
                       "e654e820b8dcd646201bb43de1cba0e0e56dff697f2ee62534bf28fe143bbf17")
    }
}

extension AppAttestShadowTests {
    var shadowStatus: AppAttestStatus { AppAttestStatus(osVersion:"27.0.0",osBuild:"26A428",appVersion:"0.9.2",chip:"Apple M5 Max",binaryHash:String(repeating:"b",count:64)) }
    /// The status behind the Go `TestAppAttestV3TranscriptBindsHardware` vector.
    var hardwareStatus: AppAttestStatus { AppAttestStatus(osVersion:"27.0.0",osBuild:"26A428",appVersion:"0.9.2",chip:"Apple M5 Max",binaryHash:String(repeating:"b",count:64),machineModel:"Mac17,6",memoryGB:"128",cpuTotal:"18",cpuPerformance:"12",cpuEfficiency:"6",gpuCores:"40",attestationPublicKey:"verification-key") }

    func testTranscriptBindsAccountAndMeasuredStatus() {
        var p=request("assert",key:Data(repeating:1,count:32).base64EncodedString()); p.status=shadowStatus
        let hash=p.clientHash(publicKey:publicKey)
        p.status?.osBuild="spoofed"; XCTAssertNotEqual(hash,p.clientHash(publicKey:publicKey))
        p.status=shadowStatus; p.accountScope=String(repeating:"c",count:64); XCTAssertNotEqual(hash,p.clientHash(publicKey:publicKey))
    }

    func testLostEnrollmentReplyRecoversAcrossRestartWithoutAppleOrKeyRotation() async {
        let service=FakeService(); let storage=MemoryKeys()
        let first=AppAttestShadowClient(scope:"server",service:service,storage:storage)
        let ready=await first.respond(to:request("prepare"),publicKey:publicKey)
        let original=await first.respond(to:request("attest",key:ready.keyID),publicKey:publicKey,status:shadowStatus)
        XCTAssertEqual(original.result,"ok")
        let restarted=AppAttestShadowClient(scope:"server",service:service,storage:storage)
        var prepare=request("prepare"); prepare.session=Data(repeating:7,count:32).base64EncodedString()
        let next=await restarted.respond(to:prepare,publicKey:publicKey)
        var retry=request("attest",key:next.keyID); retry.session=prepare.session
        let recovered=await restarted.respond(to:retry,publicKey:publicKey,status:shadowStatus)
        XCTAssertEqual(recovered.proof,original.proof); XCTAssertEqual(recovered.enrollmentSession,session)
        let counts=await service.counts(); XCTAssertEqual(counts,[1,1,0])
        retry.action="assert"
        let assertion=await restarted.respond(to:retry,publicKey:publicKey,status:shadowStatus)
        XCTAssertEqual(assertion.result,"ok")
        XCTAssertNil(storage.load(scope:"server:production:account:"+String(repeating:"a",count:64))?.pendingProof)
    }

    func testAccountScopesDoNotReuseCredentialsOrAcceptMidSessionChanges() async {
        let service=FakeService(); let storage=MemoryKeys()
        let client=AppAttestShadowClient(scope:"server",service:service,storage:storage)
        let ready=await client.respond(to:request("prepare"),publicKey:publicKey)
        let other=String(repeating:"c",count:64)
        let bad=await client.respond(to:request("assert",key:ready.keyID,account:other),publicKey:publicKey,status:shadowStatus)
        XCTAssertEqual(bad.result,"invalid_request")
        _ = await client.respond(to:request("prepare",account:other),publicKey:publicKey)
        let counts=await service.counts(); XCTAssertEqual(counts,[2,0,0])
    }

    func testCallbackDeadlineHandlesMissingAndDuplicateCallbacks() async throws {
        do {
            let _: String = try await CallbackDeadline.call(seconds:0.01) { _ in }
            XCTFail("missing callback hung past deadline")
        } catch { XCTAssertEqual(error as? ShadowFailure,.operationTimeout) }
        let result: String = try await CallbackDeadline.call(seconds:0.01) { complete in
            complete(.success("first")); complete(.success("second"))
        }
        XCTAssertEqual(result,"first")
        try await Task.sleep(for:.milliseconds(20))
    }
}

extension AppAttestShadowTests {
    func testTranscriptBindsHardwareAndVerificationKey() {
        var p=request("assert",key:Data(repeating:1,count:32).base64EncodedString())
        p.status=hardwareStatus
        let hash=p.clientHash(publicKey:publicKey)
        XCTAssertEqual(hash.map { String(format:"%02x",$0) }.joined(),"e654e820b8dcd646201bb43de1cba0e0e56dff697f2ee62534bf28fe143bbf17")
        p.status?.memoryGB="1024"
        XCTAssertNotEqual(hash,p.clientHash(publicKey:publicKey))
        p.status?.memoryGB="128"; p.status?.attestationPublicKey="substituted-key"
        XCTAssertNotEqual(hash,p.clientHash(publicKey:publicKey))
    }
}
