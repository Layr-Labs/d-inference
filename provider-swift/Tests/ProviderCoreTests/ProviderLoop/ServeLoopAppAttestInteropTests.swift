import CryptoKit
import Foundation
import Testing

@testable import ProviderAppAttest
@testable import ProviderCore

#if DEBUG
/// Invoked by darkbloom-platform's TestSwiftProviderAppAttestInterop. Only the
/// Apple callback, prior enrollment/receipt, authenticated registration, privacy
/// and runtime qualification are fixtures. Both process runtimes, encrypted
/// challenge, transcript, verifier, counter and grant writer are real.
@Suite("Swift / Go App Attest interoperability", .serialized)
struct ServeLoopAppAttestInteropTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_ATTEST_INTEROP_URL"] != nil))
    func composedCoordinatorExchange() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(environment["DARKBLOOM_ATTEST_INTEROP_URL"])
        let directory = URL(fileURLWithPath: try #require(environment["DARKBLOOM_ATTEST_INTEROP_DIRECTORY"]))
        let endpoint = try #require(URL(string: url))
        try #require(endpoint.scheme == "ws" && endpoint.host == "127.0.0.1",
                     "interop fixtures may connect only to loopback")
        let fixture = try await ServeLoopFixture.make(
            heartbeatIntervalSecs: 1, coordinatorURL: url,
            memoryGB: ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let service = InteropAppleService()
        await fixture.loop.installInteropAttestClient(service)
        let info: [String: Any] = [
            "binary_hash": try #require(selfBinaryHash()),
            "version": ProviderCore.version,
            "attestation_public_key": fixture.signer.publicKeyBase64,
            "credential_public_key": service.publicKey.base64EncodedString(),
            "key_id": service.keyID,
        ]
        try JSONSerialization.data(withJSONObject: info).write(
            to: directory.appendingPathComponent("identity.json"), options: .atomic)
        let task = fixture.start()
        do {
            let deadline = ContinuousClock.now + .seconds(420)
            var sessions = [String]()
            var expiries = [String: Double]()
            while ContinuousClock.now < deadline {
                let authorization = DaemonStateFile.read(from: fixture.stateFile)?.trust?.authorization
                if let authorization,
                   authorization.hasCurrentAppAttestAuthorization(now: Date().timeIntervalSince1970),
                   !sessions.contains(authorization.sessionID) {
                    sessions.append(authorization.sessionID)
                    expiries[authorization.sessionID] = authorization.expiresAt
                    let observation: [String: Any] = ["sessions": sessions, "expiries": expiries]
                    try JSONSerialization.data(withJSONObject: observation).write(
                        to: directory.appendingPathComponent("observations.json"), options: .atomic)
                }
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("done").path) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("done").path))
            #expect(sessions.count == 3, "three renewed connections use the same live provider process")
            let revoked = await modelLoadingWaitUntil {
                let authorization = DaemonStateFile.read(from: fixture.stateFile)?.trust?.authorization
                return authorization != nil && authorization?.path != "app_attest"
            }
            #expect(revoked, "coordinator revocation clears the native grant")
            #expect(await service.assertionCount() == 4, "one lost proof is retried with a fresh counter")
            print("APP_ATTEST_INTEROP sessions=\(sessions.count) assertions=\(await service.assertionCount()) revoked=\(revoked)")
        } catch {
            await fixture.stop(task)
            throw error
        }
        #expect(await fixture.stop(task))
    }
}

private actor InteropAppleService: AppAttestService {
    // Public test-vector key. Never used by production or persisted to Keychain.
    private let key = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + [1])
    nonisolated let publicKey = (try! P256.Signing.PrivateKey(
        rawRepresentation: Data(repeating: 0, count: 31) + [1])).publicKey.x963Representation
    nonisolated var keyID: String { Data(SHA256.hash(data: publicKey)).base64EncodedString() }
    private var counter: UInt32 = 0
    func checkAvailability(environment: String) {}
    func generateKey() throws -> String { throw ShadowFailure.keychainError }
    func attestKey(_ id: String, hash: Data) throws -> Data { throw ShadowFailure.invalidRequest }
    func generateAssertion(_ id: String, hash: Data) throws -> Data {
        guard id == keyID else { throw ShadowFailure.appleInvalidKey }
        counter += 1
        var auth = Data(SHA256.hash(data: Data("TEST.app".utf8))) + [0x80]
        auth.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: counter >> $0) })
        auth += cborMap([
            ("apple_cd_hash_hash_01", Data(repeating: 0xcc, count: 32)),
            ("apple_cd_hash_type_01", Data([2])),
            ("apple_validation_category_01", Data([6, 0, 0, 0])),
        ])
        let nonce = Data(SHA256.hash(data: auth + hash))
        let signature = try key.signature(for: nonce).derRepresentation
        return cborMap([("signature", signature), ("authenticatorData", auth)])
    }
    func operationHeldSince() -> Date? { nil }
    func assertionCount() -> UInt32 { counter }
}

/// The fixture emits just the canonical CBOR map/string/bytes shapes Apple
/// supplies. No product transcript or verification implementation is duplicated.
private func cborMap(_ entries: [(String, Data)]) -> Data {
    var data = Data([0xa0 | UInt8(entries.count)])
    func head(_ major: UInt8, _ count: Int) -> Data {
        if count < 24 { return Data([major | UInt8(count)]) }
        if count < 256 { return Data([major | 24, UInt8(count)]) }
        return Data([major | 25, UInt8(count >> 8), UInt8(count & 255)])
    }
    for (name, value) in entries {
        let text = Data(name.utf8)
        data += head(0x60, text.count) + text
        data += head(0x40, value.count) + value
    }
    return data
}

private final class InteropAttestKeys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ShadowKeyRecord] = [:]
    private let keyID: String
    init(keyID: String) { self.keyID = keyID }
    func load(scope: String) -> ShadowKeyRecord? {
        lock.lock(); defer { lock.unlock() }
        if let record = records[scope] { return record }
        guard scope.contains(":account:") else { return nil }
        return ShadowKeyRecord(keyID: keyID, attested: true, createdAt: Date())
    }
    func save(_ record: ShadowKeyRecord, scope: String) {
        lock.lock(); defer { lock.unlock() }
        records[scope] = record
    }
}

private extension ProviderLoop {
    func installInteropAttestClient(_ service: InteropAppleService) {
        appAttestShadowClient = AppAttestShadowClient(
            scope: loopConfig.coordinatorURL, service: service,
            storage: InteropAttestKeys(keyID: service.keyID))
    }
}
#endif
