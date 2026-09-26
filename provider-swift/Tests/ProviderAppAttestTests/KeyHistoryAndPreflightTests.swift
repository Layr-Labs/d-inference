import Foundation
import XCTest
@testable import ProviderAppAttest

final class KeyHistoryAndPreflightTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Keychain record compatibility

    func testRecordsFromOlderProvidersDecodeWithNilHistory() throws {
        // Exactly what a 0.9.9 provider stored (JSONEncoder default date strategy).
        let old = Data(#"{"keyID":"k","attested":true,"createdAt":780000000,"generationCount":2}"#.utf8)
        let record = try JSONDecoder().decode(ShadowKeyRecord.self, from: old)
        XCTAssertEqual(record.keyID, "k")
        XCTAssertNil(record.createdBootTime)
        XCTAssertNil(record.createdAppVersion)
        XCTAssertNil(record.lastSuccessAt)
        XCTAssertNil(record.consecutiveAssertionFailures)
        XCTAssertNil(record.generationHistory)
        let history = AppAttestKeyHistory.build(record: record, budget: nil, now: now, bootTime: 1)
        XCTAssertEqual(history?.keyAgeSeconds, Int(now.timeIntervalSince(record.createdAt)))
        XCTAssertNil(history?.createdBootMatches, "unknown for keys created before the field existed")
        XCTAssertNil(history?.createdAppVersion)
    }

    // MARK: - key_history builder

    func testHistoryCountsTrailing24hGenerationsAndAges() {
        var budget = ShadowKeyRecord(keyID: "budget", attested: false, createdAt: now)
        budget.generationHistory = [now.addingTimeInterval(-90_000), now.addingTimeInterval(-3_600), now.addingTimeInterval(-60)]
        var record = ShadowKeyRecord(keyID: "k", attested: true, createdAt: now.addingTimeInterval(-60))
        record.createdBootTime = 1_789_990_000
        record.createdAppVersion = "0.9.10"
        record.lastSuccessAt = now.addingTimeInterval(-30)
        record.consecutiveAssertionFailures = 2
        let history = AppAttestKeyHistory.build(record: record, budget: budget, now: now, bootTime: 1_789_990_030)
        XCTAssertEqual(history, AppAttestKeyHistory(generationsLast24h: 2, lastGenerationAgeSeconds: 60, lastSuccessAgeSeconds: 30,
                                                    consecutiveAssertionFailures: 2, keyAgeSeconds: 60,
                                                    createdBootMatches: true, createdAppVersion: "0.9.10"))
        let rebooted = AppAttestKeyHistory.build(record: record, budget: budget, now: now, bootTime: 1_789_999_000)
        XCTAssertEqual(rebooted?.createdBootMatches, false)
    }

    func testHistoryOmitsKeyMembersWithoutUsableKeyAndFutureAges() {
        var retired = ShadowKeyRecord(keyID: "", attested: false, createdAt: now)
        retired.consecutiveAssertionFailures = 5
        var budget = ShadowKeyRecord(keyID: "budget", attested: false, createdAt: now)
        budget.generationHistory = [now.addingTimeInterval(600)]
        let history = AppAttestKeyHistory.build(record: retired, budget: budget, now: now, bootTime: nil)
        XCTAssertEqual(history, AppAttestKeyHistory(generationsLast24h: 0))
        XCTAssertEqual(AppAttestKeyHistory.build(record: nil, budget: nil, now: now, bootTime: nil),
                       AppAttestKeyHistory(generationsLast24h: 0), "no budget record means no generation ever happened")
    }

    func testGenerationHistoryIsCappedAndSurvivesTheHourlyBudgetReset() async throws {
        let storage = HistoryKeys()
        var budget = ShadowKeyRecord(keyID: "budget", attested: false, createdAt: Date(timeIntervalSinceNow: -7200))
        budget.generationCount = KeyGenerationBudget.limit
        budget.generationHistory = (0..<KeyGenerationHistory.cap).map { Date(timeIntervalSinceNow: Double(-7200 - $0)) }
        storage.save(budget, scope: "s:production:generation-budget")
        let generation = ShadowKeyGeneration(service: HistoryService(), storage: storage, budgetScope: "s:production:generation-budget",
                                             keyScope: "s:production", bootTime: 42, appVersion: String(repeating: "9", count: 40))
        let key = try await generation.generate(replacing: nil)
        let saved = try XCTUnwrap(storage.load(scope: "s:production:generation-budget"))
        XCTAssertEqual(saved.generationCount, 1, "the hourly budget still resets")
        XCTAssertEqual(saved.generationHistory?.count, KeyGenerationHistory.cap)
        XCTAssertEqual(saved.generationHistory?.last, key.createdAt)
        XCTAssertEqual(key.createdBootTime, 42)
        XCTAssertEqual(key.createdAppVersion?.count, AppAttestKeyHistory.maxVersionLength)
    }

    func testAssertionFailuresCountAppleCallsAndResetOnSuccess() async throws {
        let storage = HistoryKeys()
        let service = HistoryService()
        let client = AppAttestShadowClient(scope: "s", service: service, storage: storage,
                                           runtimeContext: { AppAttestRuntimeContext(launchSession: .gui, bootTime: 7) })
        let session = Data(repeating: 0, count: 32).base64EncodedString()
        let publicKey = Data(repeating: 3, count: 32).base64EncodedString()
        func request(_ action: String, key: String? = nil) -> AppAttestShadowPayload {
            var p = AppAttestShadowPayload(action: action, session: session)
            p.environment = "production"; p.keyID = key
            if action != "prepare" { p.challenge = Data(repeating: 2, count: 32).base64EncodedString() }
            return p
        }
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(ready.keyHistory?.generationsLast24h, 1)
        XCTAssertEqual(ready.keyHistory?.createdBootMatches, true)
        _ = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey)
        await service.failAssertions(with: ShadowFailure.operationTimeout)
        _ = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        _ = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(storage.load(scope: "s:production")?.consecutiveAssertionFailures, 2)
        await service.failAssertions(with: ShadowFailure.busy)
        _ = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(storage.load(scope: "s:production")?.consecutiveAssertionFailures, 2, "local admission is not an Apple failure")
        await service.failAssertions(with: nil)
        _ = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(storage.load(scope: "s:production")?.consecutiveAssertionFailures, 0)
        XCTAssertNotNil(storage.load(scope: "s:production")?.lastSuccessAt)
    }

    // MARK: - preflight

    func testPreflightClassifiesEntitlementsProfileAndLocation() {
        let home = "/Users/op"
        let full = AppAttestPreflight.build(
            entitlements: [AppAttestEntitlementPolicy.optIn: ["CDhash"], AppAttestEntitlementPolicy.environment: "production"],
            profile: nil, bundlePath: home + "/.darkbloom/Darkbloom.app", home: home, now: now)
        XCTAssertEqual(full, AppAttestPreflight(optInEntitlement: true, environmentEntitlement: .production, profilePresent: false,
                                                profileExpired: nil, bundlePathClass: .userInstall))
        let invalid = AppAttestPreflight.build(entitlements: [AppAttestEntitlementPolicy.environment: 1], profile: Data("junk".utf8),
                                               bundlePath: "/Applications/Darkbloom.app", home: home, now: now)
        XCTAssertEqual(invalid.optInEntitlement, false)
        XCTAssertEqual(invalid.environmentEntitlement, .invalid)
        XCTAssertEqual(invalid.profilePresent, true)
        XCTAssertNil(invalid.profileExpired, "undecodable profile: expiry unknown, not guessed")
        XCTAssertEqual(invalid.bundlePathClass, .applications)
        let unsigned = AppAttestPreflight.build(entitlements: nil, profile: nil, bundlePath: "/tmp/x.app", home: home, now: now)
        XCTAssertNil(unsigned.optInEntitlement)
        XCTAssertNil(unsigned.environmentEntitlement)
        XCTAssertEqual(unsigned.bundlePathClass, .other)
        XCTAssertEqual(AppAttestPreflight.build(entitlements: [:], profile: nil, bundlePath: nil, home: home, now: now).environmentEntitlement, .absent)
        XCTAssertEqual(AppAttestPreflight.pathClass(home + "/.darkbloomX/a.app", home: home), .other)
        XCTAssertEqual(AppAttestPreflight.pathClass(home + "/Applications/Darkbloom.app", home: home), .applications)
    }

    func testRealEmbeddedProfileExpiryDecodesWhenInstalled() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/Darkbloom.app/Contents/embedded.provisionprofile")
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw XCTSkip("no installed Darkbloom.app on this machine")
        }
        XCTAssertNotNil(ProvisioningProfileDecoder.expirationDate(data))
    }

    func testDaemonStateSnakeCaseRoundTripKeepsNestedDiagnostics() throws {
        var payload = AppAttestShadowPayload(action: "ready", session: "s")
        payload.attachAllDeepDiagnostics()
        let status = AppAttestLocalStatus(
            observedAt: 1, launchSession: .background,
            process: AppAttestProcessDiagnostics(processStartedAt: payload.processStartedAt, previousExit: payload.previousExit,
                                                 startReason: payload.startReason, consoleUserActive: payload.consoleUserActive,
                                                 sipEnabled: payload.sipEnabled, authenticatedRoot: payload.authenticatedRoot,
                                                 preflight: payload.preflight, pushHistory: payload.pushHistory),
            keyHistory: payload.keyHistory,
            lastAppleFailure: AppAttestLastAppleFailure(observedAt: 1, action: .assertion, result: "apple_error",
                                                        nativeErrorChain: payload.nativeErrorChain))
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(try decoder.decode(AppAttestLocalStatus.self, from: encoder.encode(status)), status)
        XCTAssertEqual(try JSONDecoder().decode(AppAttestLocalStatus.self, from: JSONEncoder().encode(status)), status)
    }
}

private actor HistoryService: AppAttestService {
    private var assertionFailure: (any Error)?
    func failAssertions(with error: (any Error)?) { assertionFailure = error }
    func checkAvailability(environment: String) throws {}
    func generateKey() -> String { Data(repeating: 1, count: 32).base64EncodedString() }
    func attestKey(_ id: String, hash: Data) -> Data { Data("attestation".utf8) }
    func generateAssertion(_ id: String, hash: Data) throws -> Data {
        if let assertionFailure { throw assertionFailure }
        return Data("assertion".utf8)
    }
    func operationHeldSince() -> Date? { nil }
}

private final class HistoryKeys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ShadowKeyRecord] = [:]
    func load(scope: String) -> ShadowKeyRecord? { lock.withLock { records[scope] } }
    func save(_ record: ShadowKeyRecord, scope: String) { lock.withLock { records[scope] = record } }
}
