import Foundation
import XCTest
@preconcurrency import DeviceCheck
@testable import ProviderAppAttest

extension AppAttestShadowPayload {
    /// Every deep diagnostic populated with non-default values.
    mutating func attachAllDeepDiagnostics() {
        attach(AppAttestProcessDiagnostics(
            processStartedAt: 1_789_430_900, previousExit: .unclean, startReason: .stallRestart,
            consoleUserActive: true, sipEnabled: false, authenticatedRoot: true,
            preflight: AppAttestPreflight(optInEntitlement: true, environmentEntitlement: .absent, profilePresent: true,
                                          profileExpired: false, bundlePathClass: .userInstall),
            pushHistory: AppAttestPushHistory(deviceTokenPresent: false, pushesReceivedLast24h: 0,
                                              lastPushReceivedAgeSeconds: 86_400, lastReplySentAgeSeconds: 90_000)))
        keyHistory = AppAttestKeyHistory(generationsLast24h: 3, lastGenerationAgeSeconds: 60, lastSuccessAgeSeconds: 0,
                                         consecutiveAssertionFailures: 2, keyAgeSeconds: 7200, createdBootMatches: false,
                                         createdAppVersion: "0.9.9")
        nativeErrorChain = [.init(domain: .devicecheck, code: 0), .init(domain: .cryptotokenkit, code: -3),
                            .init(domain: .aks, code: -536_362_989)]
    }
}

final class NativeErrorChainTests: XCTestCase {
    /// The devicecheckd failure one operator captured after a provider restart:
    /// DeviceCheck code 0 over CryptoTokenKit -3 "unable to sign digest"
    /// with AKSError=-536362989 (0xe007c013).
    private func capturedKeyLossError(aks: Any = NSNumber(value: -536_362_989)) -> NSError {
        let ctk = NSError(domain: "CryptoTokenKit", code: -3, userInfo: [
            NSLocalizedDescriptionKey: "unable to sign digest", "AKSError": aks,
        ])
        return NSError(domain: DCErrorDomain, code: 0, userInfo: [NSUnderlyingErrorKey: ctk])
    }

    func testCapturedCryptoTokenKitKeyLossChainKeepsAKSCodeAsSignedInt32() throws {
        let chain = AppAttestNativeErrorChain.entries(capturedKeyLossError())
        XCTAssertEqual(chain, [.init(domain: .devicecheck, code: 0), .init(domain: .cryptotokenkit, code: -3),
                               .init(domain: .aks, code: -536_362_989)])
        let json = String(decoding: try JSONEncoder().encode(chain), as: UTF8.self)
        XCTAssertTrue(json.contains("-536362989"))
        XCTAssertFalse(json.contains("unable to sign digest"))
    }

    func testUnsignedAKSBitPatternEncodesAsSameSignedInt32() {
        // Some frameworks surface 0xe007c013 as the positive UInt32 value; the
        // coordinator rejects anything outside int32, so reinterpret the bits.
        let chain = AppAttestNativeErrorChain.entries(capturedKeyLossError(aks: NSNumber(value: UInt32(0xe007_c013))))
        XCTAssertEqual(chain.last, .init(domain: .aks, code: -536_362_989))
    }

    func testCodesWiderThan32BitsAreDroppedNotClamped() {
        XCTAssertNil(AppAttestNativeErrorChain.int32(Int(UInt32.max) + 1))
        XCTAssertNil(AppAttestNativeErrorChain.int32(Int(Int32.min) - 1))
        XCTAssertEqual(AppAttestNativeErrorChain.int32(Int(UInt32.max)), -1)
        let wide = NSError(domain: NSCocoaErrorDomain, code: Int(Int64(1) << 40),
                           userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -25_300)])
        XCTAssertEqual(AppAttestNativeErrorChain.entries(wide), [.init(domain: .osstatus, code: -25_300)])
    }

    func testUnknownDomainsBucketAsOtherAndNonNumericAKSIsIgnored() {
        let inner = NSError(domain: "com.example.private", code: 7, userInfo: ["AKSError": "0xe007c013"])
        let top = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSUnderlyingErrorKey: inner])
        XCTAssertEqual(AppAttestNativeErrorChain.entries(top), [.init(domain: .url, code: -1009), .init(domain: .other, code: 7)])
        let boolean = NSError(domain: "CryptoTokenKit", code: -3, userInfo: ["AKSError": true])
        XCTAssertEqual(AppAttestNativeErrorChain.entries(boolean), [.init(domain: .cryptotokenkit, code: -3)])
    }

    func testChainStopsAtFourEntries() {
        var error = NSError(domain: "leaf", code: 99)
        for code in (1...6).reversed() {
            error = NSError(domain: NSCocoaErrorDomain, code: code, userInfo: [NSUnderlyingErrorKey: error])
        }
        let chain = AppAttestNativeErrorChain.entries(error)
        XCTAssertEqual(chain.count, AppAttestNativeErrorChain.maxEntries)
        XCTAssertEqual(chain.map(\.code), [1, 2, 3, 4])

        // An AKS entry counts toward the cap.
        let akss = NSError(domain: "CryptoTokenKit", code: -3, userInfo: [
            "AKSError": NSNumber(value: -536_362_989),
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -1,
                                          userInfo: [NSUnderlyingErrorKey: NSError(domain: "x", code: 2,
                                                     userInfo: [NSUnderlyingErrorKey: NSError(domain: "y", code: 3)])]),
        ])
        XCTAssertEqual(AppAttestNativeErrorChain.entries(akss).map(\.domain), [.cryptotokenkit, .aks, .osstatus, .other])
    }

    func testFailedAssertionReplyCarriesChainAndKeepsResult() async throws {
        let service = ChainService(assertionError: capturedKeyLossError())
        let client = AppAttestShadowClient(scope: "test", service: service, storage: ChainKeys())
        let session = Data(repeating: 0, count: 32).base64EncodedString()
        let publicKey = Data(repeating: 3, count: 32).base64EncodedString()
        func request(_ action: String, key: String? = nil) -> AppAttestShadowPayload {
            var p = AppAttestShadowPayload(action: action, session: session)
            p.environment = "production"; p.keyID = key
            if action != "prepare" { p.challenge = Data(repeating: 2, count: 32).base64EncodedString() }
            return p
        }
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertNil(ready.nativeErrorChain)
        _ = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey)
        let failed = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(failed.result, "apple_error")
        XCTAssertEqual(failed.nativeErrorChain?.map(\.domain), [.devicecheck, .cryptotokenkit, .aks])
        XCTAssertEqual(failed.appleError?.underlyingDomain, "other")
        var stripped = failed; stripped.nativeErrorChain = nil
        XCTAssertEqual(failed.clientHash(publicKey: publicKey), stripped.clientHash(publicKey: publicKey))
    }
}

private actor ChainService: AppAttestService {
    let assertionError: NSError
    init(assertionError: NSError) { self.assertionError = assertionError }
    func checkAvailability(environment: String) throws {}
    func generateKey() -> String { Data(repeating: 1, count: 32).base64EncodedString() }
    func attestKey(_ id: String, hash: Data) -> Data { Data("attestation".utf8) }
    func generateAssertion(_ id: String, hash: Data) throws -> Data { throw AppleAppAttestFailure(assertionError) }
    func operationHeldSince() -> Date? { nil }
}

private final class ChainKeys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ShadowKeyRecord] = [:]
    func load(scope: String) -> ShadowKeyRecord? { lock.withLock { records[scope] } }
    func save(_ record: ShadowKeyRecord, scope: String) { lock.withLock { records[scope] = record } }
}
