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
}

private final class MemoryKeys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ShadowKeyRecord] = [:]
    func load(scope: String) -> ShadowKeyRecord? { lock.lock(); defer { lock.unlock() }; return records[scope] }
    func save(_ record: ShadowKeyRecord, scope: String) { lock.lock(); defer { lock.unlock() }; records[scope] = record }
}

private struct UnwritableKeys: ShadowKeyStorage {
    func load(scope: String) -> ShadowKeyRecord? { nil }
    func save(_ record: ShadowKeyRecord, scope: String) throws { throw ShadowFailure.keychainError }
}

final class AppAttestShadowTests: XCTestCase {
    let session = Data(repeating: 0, count: 32).base64EncodedString()
    let publicKey = Data(repeating: 3, count: 32).base64EncodedString()

    func request(_ action: String, key: String? = nil) -> AppAttestShadowPayload {
        var p = AppAttestShadowPayload(action: action, session: session)
        p.environment = "production"; p.keyID = key
        if action != "prepare" { p.challenge = Data(repeating: 2, count: 32).base64EncodedString() }
        return p
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

    func testPersistentKeySurvivesReconnectAndOnlyAttestsOnce() async {
        let service = FakeService(); let storage = MemoryKeys()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(ready.result, "ok")
        let proof = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(proof.result, "ok")
        let assertion = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(assertion.result, "ok")
        let restarted = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let next = await restarted.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(next.keyID, ready.keyID)
        let nextProof = await restarted.respond(to: request("assert", key: next.keyID), publicKey: publicKey)
        XCTAssertEqual(nextProof.result, "ok")
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 1, 2])
    }

    func testWrongSessionOrKeyCannotSign() async {
        let service = FakeService()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        var bad = request("assert", key: ready.keyID); bad.session = Data(repeating: 9, count: 32).base64EncodedString()
        let response = await client.respond(to: bad, publicKey: publicKey)
        XCTAssertEqual(response.result, "invalid_request")
        bad = request("assert", key: Data(repeating: 8, count: 32).base64EncodedString())
        let other = await client.respond(to: bad, publicKey: publicKey)
        XCTAssertEqual(other.result, "invalid_request")
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 0, 0])
    }

    func testUnknownEnrolledKeyCannotCauseRapidKeyChurn() async {
        let service = FakeService()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        _ = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey)
        let retry = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(retry.result, "key_unregistered")
        let prepared = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(prepared.result, "busy")
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 1, 0])
    }

    func testTranscriptMatchesGoVectorAndBindsEndpoint() throws {
        let p = request("assert", key: Data(repeating: 1, count: 32).base64EncodedString())
        let hash = p.clientHash(publicKey: publicKey).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "6961d03f72d47b5e4d66746d590a82fabfca7a9fd4de48a05bfcef5c1e850449")
        XCTAssertNotEqual(p.clientHash(publicKey: publicKey), p.clientHash(publicKey: Data(repeating: 4, count: 32).base64EncodedString()))
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(AppAttestShadowPayload.self, from: data), p)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["encrypted_challenge"])
        XCTAssertNotNil(object["key_id"])
    }
}

extension AppAttestShadowTests {
    func requestV2(_ action: String, key: String? = nil, account: String = String(repeating:"a",count:64)) -> AppAttestShadowPayload {
        var p=request(action,key:key); p.protocolVersion=2; p.accountScope=account; return p
    }
    var statusV2: AppAttestStatus { AppAttestStatus(osVersion:"27.0.0",osBuild:"26A428",appVersion:"0.9.2",chip:"Apple M5 Max",binaryHash:String(repeating:"b",count:64)) }

    func testV2TranscriptBindsAccountAndMeasuredStatus() {
        var p=requestV2("assert",key:Data(repeating:1,count:32).base64EncodedString()); p.status=statusV2
        let hash=p.clientHash(publicKey:publicKey)
        XCTAssertEqual(hash.map { String(format:"%02x",$0) }.joined(),"91a11ff692299f9b8237fa9aaabde46de9f4dbbe5b9b00108b979cd985e1aae6")
        p.status?.osBuild="spoofed"; XCTAssertNotEqual(hash,p.clientHash(publicKey:publicKey))
        p.status=statusV2; p.accountScope=String(repeating:"c",count:64); XCTAssertNotEqual(hash,p.clientHash(publicKey:publicKey))
    }

    func testLostEnrollmentReplyRecoversAcrossRestartWithoutAppleOrKeyRotation() async {
        let service=FakeService(); let storage=MemoryKeys()
        let first=AppAttestShadowClient(scope:"server",service:service,storage:storage)
        let ready=await first.respond(to:requestV2("prepare"),publicKey:publicKey)
        let original=await first.respond(to:requestV2("attest",key:ready.keyID),publicKey:publicKey,status:statusV2)
        XCTAssertEqual(original.result,"ok")
        let restarted=AppAttestShadowClient(scope:"server",service:service,storage:storage)
        var prepare=requestV2("prepare"); prepare.session=Data(repeating:7,count:32).base64EncodedString()
        let next=await restarted.respond(to:prepare,publicKey:publicKey)
        var retry=requestV2("attest",key:next.keyID); retry.session=prepare.session
        let recovered=await restarted.respond(to:retry,publicKey:publicKey,status:statusV2)
        XCTAssertEqual(recovered.proof,original.proof); XCTAssertEqual(recovered.enrollmentSession,session)
        let counts=await service.counts(); XCTAssertEqual(counts,[1,1,0])
        retry.action="assert"
        let assertion=await restarted.respond(to:retry,publicKey:publicKey,status:statusV2)
        XCTAssertEqual(assertion.result,"ok")
        XCTAssertNil(storage.load(scope:"server:production:account:"+String(repeating:"a",count:64))?.pendingProof)
    }

    func testAccountScopesDoNotReuseCredentialsOrAcceptMidSessionChanges() async {
        let service=FakeService(); let storage=MemoryKeys()
        let client=AppAttestShadowClient(scope:"server",service:service,storage:storage)
        let ready=await client.respond(to:requestV2("prepare"),publicKey:publicKey)
        let other=String(repeating:"c",count:64)
        let bad=await client.respond(to:requestV2("assert",key:ready.keyID,account:other),publicKey:publicKey,status:statusV2)
        XCTAssertEqual(bad.result,"invalid_request")
        _ = await client.respond(to:requestV2("prepare",account:other),publicKey:publicKey)
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
    func testV3TranscriptBindsHardwareWithoutChangingV2() {
        var p=requestV2("assert",key:Data(repeating:1,count:32).base64EncodedString())
        p.protocolVersion=3
        p.status=AppAttestStatus(osVersion:"27.0.0",osBuild:"26A428",appVersion:"0.9.2",chip:"Apple M5 Max",binaryHash:String(repeating:"b",count:64),machineModel:"Mac17,6",memoryGB:"128",cpuTotal:"18",cpuPerformance:"12",cpuEfficiency:"6",gpuCores:"40")
        let hash=p.clientHash(publicKey:publicKey)
        XCTAssertEqual(hash.map { String(format:"%02x",$0) }.joined(),"1876a4d206f61a8c1ad4fbe70faa724cedef1212d45ab4d2f19920972e8e079d")
        p.status?.memoryGB="1024"
        XCTAssertNotEqual(hash,p.clientHash(publicKey:publicKey))
    }

    func testV3UpgradeKeepsPendingV2ProofAndUsesFreshV3Assertion() async {
        let service=FakeService(); let storage=MemoryKeys()
        let original=AppAttestShadowClient(scope:"upgrade",service:service,storage:storage)
        let ready=await original.respond(to:requestV2("prepare"),publicKey:publicKey)
        let proof=await original.respond(to:requestV2("attest",key:ready.keyID),publicKey:publicKey,status:statusV2)
        let upgraded=AppAttestShadowClient(scope:"upgrade",service:service,storage:storage)
        var prepare=requestV2("prepare"); prepare.protocolVersion=3; prepare.session=Data(repeating:8,count:32).base64EncodedString()
        let next=await upgraded.respond(to:prepare,publicKey:publicKey)
        var attest=requestV2("attest",key:next.keyID);attest.protocolVersion=3;attest.session=prepare.session
        let recovered=await upgraded.respond(to:attest,publicKey:publicKey,status:statusV2)
        XCTAssertEqual(recovered.proof,proof.proof)
        XCTAssertEqual(recovered.enrollmentSession,session)
        attest.action="assert"
        let fresh=await upgraded.respond(to:attest,publicKey:publicKey,status:statusV2)
        XCTAssertEqual(fresh.result,"ok")
        let counts=await service.counts();XCTAssertEqual(counts,[1,1,1])
    }
}
