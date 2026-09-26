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

    func testSaturatedDayRetainsGenerationsBeyondTwentyAndAgesThemOut() {
        var attempts: [Date] = []
        for hour in 0..<24 {
            for attempt in 0..<KeyGenerationBudget.limit {
                attempts = KeyGenerationHistory.appending(now.addingTimeInterval(Double(hour * 3601 + attempt)), to: attempts)
            }
        }
        var budget = ShadowKeyRecord(keyID: "budget", attested: false, createdAt: now)
        budget.generationHistory = attempts
        XCTAssertEqual(attempts.count, 120)
        XCTAssertEqual(AppAttestKeyHistory.build(record: nil, budget: budget, now: now.addingTimeInterval(86400), bootTime: nil)?.generationsLast24h, 100)
        XCTAssertEqual(AppAttestKeyHistory.build(record: nil, budget: budget, now: now.addingTimeInterval(169230), bootTime: nil)?.generationsLast24h, 0)
        budget.generationHistory = Array(attempts.prefix(30))
        XCTAssertEqual(AppAttestKeyHistory.build(record: nil, budget: budget, now: now.addingTimeInterval(22000), bootTime: nil)?.generationsLast24h, 30)
    }

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

    func testProofsRefreshLocalKeyStateHistoryAndRecoveryWithoutPrepare() async throws {
        let storage = HistoryKeys()
        let service = HistoryService()
        let clock = HistoryClock(now)
        var key = ShadowKeyRecord(keyID: "history-key", attested: false, createdAt: now.addingTimeInterval(-60))
        key.createdBootTime = 7
        storage.save(key, scope: "s:production")
        var budget = ShadowKeyRecord(keyID: "budget", attested: false, createdAt: key.createdAt)
        budget.generationHistory = [key.createdAt]
        storage.save(budget, scope: "s:production:generation-budget")
        let client = AppAttestShadowClient(scope: "s", service: service, storage: storage,
                                           runtimeContext: { AppAttestRuntimeContext(launchSession: .gui, bootTime: 7) },
                                           now: { clock.read() })
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
        let prepared = await client.currentLocalStatus()
        XCTAssertEqual(prepared?.key?.attested, false)
        XCTAssertNil(prepared?.keyHistory?.lastSuccessAgeSeconds)
        let readsAfterPrepare = storage.loadCount

        let attested = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(attested.result, "ok")
        XCTAssertNil(attested.keyHistory, "history is ready-only on the wire")
        let enrolled = await client.currentLocalStatus()
        XCTAssertEqual(enrolled?.key?.attested, true)
        XCTAssertEqual(enrolled?.keyHistory?.lastSuccessAgeSeconds, 0)

        clock.advance(600)
        let assertion = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(assertion.result, "ok")
        XCTAssertNil(assertion.keyHistory)
        let succeeded = await client.currentLocalStatus()
        XCTAssertEqual(succeeded?.keyHistory?.lastSuccessAgeSeconds, 0)
        XCTAssertEqual(succeeded?.keyHistory?.keyAgeSeconds, 660)
        XCTAssertEqual(succeeded?.keyHistoryObservedAt, now.timeIntervalSince1970 + 600)
        XCTAssertEqual(succeeded?.resolvingKeyHistoryAges(at: now.timeIntervalSince1970 + 620).keyHistory?.lastSuccessAgeSeconds, 20)

        await service.failAssertions(with: ShadowFailure.operationTimeout)
        clock.advance(10)
        _ = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        let firstFailure = await client.currentLocalStatus()
        XCTAssertEqual(firstFailure?.keyHistory?.consecutiveAssertionFailures, 1)
        XCTAssertEqual(firstFailure?.keyHistory?.lastSuccessAgeSeconds, 10)
        clock.advance(10)
        _ = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        let secondFailure = await client.currentLocalStatus()
        XCTAssertEqual(secondFailure?.keyHistory?.consecutiveAssertionFailures, 2)
        XCTAssertEqual(secondFailure?.keyHistory?.lastSuccessAgeSeconds, 20)
        await service.failAssertions(with: ShadowFailure.busy)
        _ = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        let busy = await client.currentLocalStatus()
        XCTAssertEqual(busy?.keyHistory?.consecutiveAssertionFailures, 2, "local admission is not an Apple failure")

        await service.failAssertions(with: nil)
        clock.advance(10)
        _ = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        let recovered = await client.currentLocalStatus()
        XCTAssertEqual(recovered?.keyHistory?.consecutiveAssertionFailures, 0)
        XCTAssertEqual(recovered?.keyHistory?.lastSuccessAgeSeconds, 0)
        XCTAssertEqual(recovered?.lastAppleFailure, secondFailure?.lastAppleFailure, "success retains the last failure for diagnosis")
        XCTAssertEqual(storage.loadCount, readsAfterPrepare, "proof diagnostics reuse the authoritative record and generation budget")
        XCTAssertEqual(storage.load(scope: "s:production")?.consecutiveAssertionFailures, 0)
        XCTAssertEqual(storage.load(scope: "s:production")?.lastSuccessAt, clock.read())
    }

    func testLocalHistoryAgesAdvanceFromOwnAnchorAndKeepUnknowns() {
        let status = AppAttestLocalStatus(observedAt: 100, launchSession: .gui, operationStalledSeconds: 800,
                                         keyHistory: AppAttestKeyHistory(lastGenerationAgeSeconds: 30, lastSuccessAgeSeconds: 0),
                                         keyHistoryObservedAt: 200)
        let rendered = status.resolvingKeyHistoryAges(at: 220)
        XCTAssertEqual(rendered.keyHistory?.lastGenerationAgeSeconds, 50)
        XCTAssertEqual(rendered.keyHistory?.lastSuccessAgeSeconds, 20)
        XCTAssertNil(rendered.keyHistory?.keyAgeSeconds)
        XCTAssertEqual(rendered.keyHistoryObservedAt, 220)
        XCTAssertEqual(rendered.observedAt, 100)
        XCTAssertEqual(rendered.operationStalledSeconds, 800)
        XCTAssertEqual(rendered.resolvingKeyHistoryAges(at: 230).keyHistory?.lastSuccessAgeSeconds, 30)
        XCTAssertNil(status.resolvingKeyHistoryAges(at: 199).keyHistory?.lastSuccessAgeSeconds,
                     "a backwards clock cannot establish a current age")
    }

    func testOlderDaemonHistoryUsesObservationTimeAsAgeAnchor() throws {
        let data = Data(#"{"observed_at":100,"launch_session":"gui","key_history":{"key_age_seconds":30,"last_success_age_seconds":0}}"#.utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try decoder.decode(AppAttestLocalStatus.self, from: data)
        XCTAssertNil(status.keyHistoryObservedAt)
        let rendered = status.resolvingKeyHistoryAges(at: 120)
        XCTAssertEqual(rendered.keyHistory?.keyAgeSeconds, 50)
        XCTAssertEqual(rendered.keyHistory?.lastSuccessAgeSeconds, 20)
        XCTAssertNil(rendered.keyHistory?.lastGenerationAgeSeconds)
        XCTAssertNil(rendered.keyHistory?.consecutiveAssertionFailures)
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
    private var reads = 0
    var loadCount: Int { lock.withLock { reads } }
    func load(scope: String) -> ShadowKeyRecord? {
        lock.withLock { reads += 1; return records[scope] }
    }
    func save(_ record: ShadowKeyRecord, scope: String) { lock.withLock { records[scope] = record } }
}

private final class HistoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
