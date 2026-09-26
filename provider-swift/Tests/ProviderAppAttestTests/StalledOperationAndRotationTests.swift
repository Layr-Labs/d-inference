import Foundation
import Security
import XCTest
@testable import ProviderAppAttest

private final class Keys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ShadowKeyRecord] = [:]
    func load(scope: String) -> ShadowKeyRecord? { lock.lock(); defer { lock.unlock() }; return values[scope] }
    func save(_ record: ShadowKeyRecord, scope: String) { lock.lock(); defer { lock.unlock() }; values[scope] = record }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

/// Apple callbacks captured so a test can leave one unanswered.
private final class PendingCallbacks: AppAttestCallbacks, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [@Sendable (Result<String, Error>) -> Void] = []
    var answerKeys = false
    func generateKey(_ complete: @escaping @Sendable (Result<String, Error>) -> Void) {
        lock.lock(); let answer = answerKeys; if !answer { keys.append(complete) }; lock.unlock()
        if answer { complete(.success(Data(repeating: 5, count: 32).base64EncodedString())) }
    }
    func attestKey(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {}
    func generateAssertion(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {}
    func finishFirstKey() {
        lock.lock(); let complete = keys.first; answerKeys = true; lock.unlock()
        complete?(.success("late"))
    }
}

/// Availability passes; key calls go through the real Apple adapter.
private actor AvailableAppleService: AppAttestService {
    let apple: AppleAppAttestService
    init(_ apple: AppleAppAttestService) { self.apple = apple }
    func checkAvailability(environment: String) {}
    func generateKey() async throws -> String { try await apple.generateKey() }
    func attestKey(_ id: String, hash: Data) async throws -> Data { try await apple.attestKey(id, hash: hash) }
    func generateAssertion(_ id: String, hash: Data) async throws -> Data { try await apple.generateAssertion(id, hash: hash) }
    func operationHeldSince() async -> Date? { await apple.operationHeldSince() }
}

private actor RotationService: AppAttestService {
    private var generated = 0
    private var attested = 0
    func checkAvailability(environment: String) {}
    func generateKey() -> String { generated += 1; return Data(repeating: UInt8(generated), count: 32).base64EncodedString() }
    func attestKey(_ id: String, hash: Data) -> Data { attested += 1; return Data("attestation-\(id)".utf8) }
    func generateAssertion(_ id: String, hash: Data) -> Data { Data("assertion".utf8) }
    func counts() -> [Int] { [generated, attested] }
    func operationHeldSince() -> Date? { nil }
}

final class StalledOperationAndRotationTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)
    private let endpoint = Data(repeating: 7, count: 32).base64EncodedString()
    private let status = AppAttestStatus(osVersion: "27.2.0", osBuild: "test", appVersion: "0.9.9", chip: "test", binaryHash: String(repeating: "b", count: 64))
    private let context = AppAttestRuntimeContext(launchSession: .background, bootTime: 1_789_430_804)

    private func request(_ action: String, session: UInt8 = 3, key: String? = nil) -> AppAttestShadowPayload {
        var p = AppAttestShadowPayload(action: action, session: Data(repeating: session, count: 32).base64EncodedString())
        p.protocolVersion = 3; p.accountScope = account; p.environment = "production"; p.keyID = key
        if action != "prepare" { p.challenge = Data(repeating: 4, count: 32).base64EncodedString() }
        return p
    }

    func testStalledAppleCallAnswersBusyWithStallSecondsOnlyAfterThreshold() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
        let callbacks = PendingCallbacks()
        let apple = AppleAppAttestService(callbacks: callbacks, operationTimeout: 0.01, now: { clock.now })
        let context = self.context
        let client = AppAttestShadowClient(scope: "test", service: AvailableAppleService(apple), storage: Keys(),
                                           runtimeContext: { context }, now: { clock.now })
        // Apple never answers generateKey; our deadline fires but the gate stays held.
        let first = await client.respond(to: request("prepare"), publicKey: endpoint)
        XCTAssertEqual(first.result, "operation_timeout")
        XCTAssertNil(first.operationStalledSeconds)

        clock.advance(AppleOperationStall.threshold)
        let atThreshold = await client.respond(to: request("prepare", session: 4), publicKey: endpoint)
        XCTAssertNil(atThreshold.operationStalledSeconds, "a gate held exactly the threshold is not yet stalled")

        clock.advance(1)
        let stalled = await client.respond(to: request("prepare", session: 5), publicKey: endpoint)
        XCTAssertEqual(stalled.action, "ready")
        XCTAssertEqual(stalled.result, "busy")
        XCTAssertEqual(stalled.operationStalledSeconds, Int(AppleOperationStall.threshold) + 1)
        XCTAssertEqual(stalled.launchSession, .background)
        XCTAssertEqual(stalled.bootTime, 1_789_430_804)
        let local = await client.currentLocalStatus()
        XCTAssertEqual(local?.operationStalledSeconds, Int(AppleOperationStall.threshold) + 1)
        XCTAssertEqual(local?.launchSession, .background)

        clock.advance(10 * 86_400)
        let capped = await client.respond(to: request("prepare", session: 6), publicKey: endpoint)
        XCTAssertEqual(capped.operationStalledSeconds, AppleOperationStall.maxReportedSeconds)

        // Apple finally answers: admission is released and the stall clears.
        callbacks.finishFirstKey()
        let held = await client.appleOperationHeldSince()
        XCTAssertNil(held)
        let recovered = await client.respond(to: request("prepare", session: 7), publicKey: endpoint)
        XCTAssertNil(recovered.operationStalledSeconds)
        // The timed-out generation keeps its existing one-hour cooldown.
        XCTAssertEqual(recovered.result, "busy")
        XCTAssertEqual(recovered.launchSession, .background)
    }

    func testReadyRepliesCarryLaunchSessionAndBootTimeOnSuccessAndFailureOnly() async throws {
        let service = RotationService()
        let context = self.context
        let client = AppAttestShadowClient(scope: "test", service: service, storage: Keys(), runtimeContext: { context })
        let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
        XCTAssertEqual(ready.result, "ok")
        XCTAssertEqual(ready.launchSession, .background)
        XCTAssertEqual(ready.bootTime, 1_789_430_804)
        XCTAssertNil(ready.operationStalledSeconds)

        var invalid = request("prepare", session: 8); invalid.accountScope = "short"
        let failed = await client.respond(to: invalid, publicKey: endpoint)
        XCTAssertEqual(failed.result, "invalid_request")
        XCTAssertEqual(failed.launchSession, .background)
        XCTAssertEqual(failed.bootTime, 1_789_430_804)

        let attestation = await client.respond(to: request("attest", key: ready.keyID), publicKey: endpoint, status: status)
        XCTAssertEqual(attestation.result, "ok")
        XCTAssertNil(attestation.launchSession)
        XCTAssertNil(attestation.bootTime)
    }

    /// The coordinator retires a dead accepted key by sending `attest` for it.
    /// Released 0.9.8/0.9.9 clients answer `key_unregistered` and generate a
    /// fresh key on the next `prepare`; coordinator rotation depends on this.
    func testCoordinatorAttestForAttestedKeyRetiresItAndNextPrepareEnrollsReplacement() async throws {
        let storage = Keys(); let service = RotationService()
        let scope = "test:production:account:" + account
        var accepted = ShadowKeyRecord(keyID: Data(repeating: 9, count: 32).base64EncodedString(), attested: true,
                                       createdAt: Date(timeIntervalSinceNow: -30 * 86_400))
        storage.save(accepted, scope: scope)
        // A fleet Mac restarted after its key died: the old record is weeks old.
        let context = self.context
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage, runtimeContext: { context })
        let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
        XCTAssertEqual(ready.keyID, accepted.keyID)

        let retired = await client.respond(to: request("attest", key: accepted.keyID), publicKey: endpoint, status: status)
        XCTAssertEqual(retired.result, "key_unregistered")
        XCTAssertNil(retired.proof)
        XCTAssertEqual(storage.load(scope: scope)?.keyID, "")
        var counts = await service.counts(); XCTAssertEqual(counts, [0, 0], "retirement makes no Apple call")

        // Coordinator retry: fresh session id, new prepare, then attest.
        let next = await client.respond(to: request("prepare", session: 11), publicKey: endpoint)
        XCTAssertEqual(next.result, "ok")
        let replacement = try XCTUnwrap(next.keyID)
        XCTAssertNotEqual(replacement, accepted.keyID)
        let enrolled = await client.respond(to: request("attest", session: 11, key: replacement), publicKey: endpoint, status: status)
        XCTAssertEqual(enrolled.result, "ok")
        XCTAssertNotNil(enrolled.proof)
        XCTAssertEqual(storage.load(scope: scope)?.keyID, replacement)
        XCTAssertEqual(storage.load(scope: "test:production:generation-budget")?.generationCount, 1)
        counts = await service.counts(); XCTAssertEqual(counts, [1, 1])
    }

    func testRotationRespectsHourlyGenerationBudget() async {
        let storage = Keys(); let service = RotationService()
        let scope = "test:production:account:" + account
        storage.save(ShadowKeyRecord(keyID: Data(repeating: 9, count: 32).base64EncodedString(), attested: true,
                                     createdAt: Date(timeIntervalSinceNow: -7200)), scope: scope)
        var budget = ShadowKeyRecord(keyID: "budget", attested: false, createdAt: Date(timeIntervalSinceNow: -600))
        budget.generationCount = KeyGenerationBudget.limit
        storage.save(budget, scope: "test:production:generation-budget")
        let context = self.context
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage, runtimeContext: { context })
        let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
        let retired = await client.respond(to: request("attest", key: ready.keyID), publicKey: endpoint, status: status)
        XCTAssertEqual(retired.result, "key_unregistered")
        let limited = await client.respond(to: request("prepare", session: 12), publicKey: endpoint)
        XCTAssertEqual(limited.result, "busy")
        XCTAssertNil(limited.operationStalledSeconds)
        let counts = await service.counts(); XCTAssertEqual(counts, [0, 0])
        let local = await client.currentLocalStatus()
        XCTAssertEqual(local?.key?.recordPresent, false)
        XCTAssertEqual(try XCTUnwrap(local?.key?.generationBlockedUntil),
                       budget.createdAt.addingTimeInterval(KeyGenerationBudget.window).timeIntervalSince1970, accuracy: 0.001)
    }

    func testLocalKeyStateReportsPresenceAttestationAndCooldown() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let present = AppAttestKeyState(record: ShadowKeyRecord(keyID: "k", attested: true, createdAt: now), budget: nil, now: now)
        XCTAssertEqual(present, AppAttestKeyState(recordPresent: true, attested: true, generationBlockedUntil: nil))
        XCTAssertEqual(AppAttestKeyState(record: nil, budget: nil, now: now),
                       AppAttestKeyState(recordPresent: false, attested: false, generationBlockedUntil: nil))

        let retired = ShadowKeyRecord(keyID: "", attested: false, createdAt: now.addingTimeInterval(-600))
        XCTAssertEqual(AppAttestKeyState(record: retired, budget: nil, now: now).generationBlockedUntil,
                       now.addingTimeInterval(3000).timeIntervalSince1970)
        var shortRetry = retired; shortRetry.generationRetryAfter = now.addingTimeInterval(30)
        XCTAssertEqual(AppAttestKeyState(record: shortRetry, budget: nil, now: now).generationBlockedUntil,
                       now.addingTimeInterval(30).timeIntervalSince1970)
        XCTAssertNil(AppAttestKeyState(record: ShadowKeyRecord(keyID: "", attested: false, createdAt: now.addingTimeInterval(-3601)),
                                       budget: nil, now: now).generationBlockedUntil)

        // The shared budget extends a shorter per-key retry, and resets hourly.
        var exhausted = ShadowKeyRecord(keyID: "budget", attested: false, createdAt: now.addingTimeInterval(-60))
        exhausted.generationCount = KeyGenerationBudget.limit
        XCTAssertEqual(AppAttestKeyState(record: shortRetry, budget: exhausted, now: now).generationBlockedUntil,
                       now.addingTimeInterval(3540).timeIntervalSince1970)
        exhausted.createdAt = now.addingTimeInterval(-3600)
        XCTAssertEqual(AppAttestKeyState(record: shortRetry, budget: exhausted, now: now).generationBlockedUntil,
                       now.addingTimeInterval(30).timeIntervalSince1970)
    }

    func testLocalStatusDecodesUnknownEnumValuesFromNewerDaemons() throws {
        let json = #"{"observedAt":1,"launchSession":"future","availabilityReason":"future","bootTime":2,"key":{"recordPresent":true,"attested":false}}"#
        let status = try JSONDecoder().decode(AppAttestLocalStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.launchSession, .unknown)
        XCTAssertNil(status.availabilityReason)
        XCTAssertEqual(status.bootTime, 2)
        XCTAssertEqual(status.key, AppAttestKeyState(recordPresent: true, attested: false, generationBlockedUntil: nil))
    }

    func testRuntimeContextMapsSessionInfo() {
        XCTAssertEqual(AppAttestRuntimeContext.launchSession(status: errSecSuccess, attributes: [.sessionHasGraphicAccess, .sessionHasTTY]), .gui)
        XCTAssertEqual(AppAttestRuntimeContext.launchSession(status: errSecSuccess, attributes: [.sessionHasTTY]), .background)
        XCTAssertEqual(AppAttestRuntimeContext.launchSession(status: errSecParam, attributes: [.sessionHasGraphicAccess]), .unknown)
        let boot = AppAttestRuntimeContext.systemBootTime()
        XCTAssertNotNil(boot)
        XCTAssertLessThanOrEqual(boot ?? .max, Int64(Date().timeIntervalSince1970))
    }
}

final class AppAttestStallRestartPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let stalled = Int(AppleOperationStall.threshold) + 1

    private func decide(stalledSeconds: Int?, inference: Bool = false, lifecycle: Bool = false, deferred: Bool = false,
                        last: Date? = nil) -> AppAttestStallRestartPolicy.Decision {
        AppAttestStallRestartPolicy.decide(stalledSeconds: stalledSeconds, inferenceActive: inference,
                                           lifecycleBusy: lifecycle, lastRestartAt: last, retryDeferred: deferred, now: now)
    }

    func testRestartsOnlyWhenStalledIdleAndOutsideTheInterval() {
        XCTAssertEqual(decide(stalledSeconds: stalled), .restart)
        XCTAssertEqual(decide(stalledSeconds: nil), .skip(.notStalled))
        XCTAssertEqual(decide(stalledSeconds: Int(AppleOperationStall.threshold)), .skip(.notStalled))
        XCTAssertEqual(decide(stalledSeconds: stalled, inference: true), .skip(.inferenceActive))
        XCTAssertEqual(decide(stalledSeconds: stalled, lifecycle: true), .skip(.lifecycleBusy))
    }

    func testAtMostOneRestartPerInterval() {
        let interval = AppAttestStallRestartPolicy.minimumInterval
        XCTAssertEqual(decide(stalledSeconds: stalled, last: now.addingTimeInterval(-interval + 1)), .skip(.recentlyRestarted))
        XCTAssertEqual(decide(stalledSeconds: stalled, last: now.addingTimeInterval(-interval)), .restart)
        // A clock that moved backwards cannot unlock an immediate second restart.
        XCTAssertEqual(decide(stalledSeconds: stalled, last: now.addingTimeInterval(3600)), .skip(.recentlyRestarted))
        // The interval outranks inference, so an unchanged limit is logged once.
        XCTAssertEqual(decide(stalledSeconds: stalled, inference: true, last: now.addingTimeInterval(-60)), .skip(.recentlyRestarted))
    }

    func testFailedAttemptDefersTheNextDrainInThisProcess() {
        XCTAssertEqual(decide(stalledSeconds: stalled, deferred: true), .skip(.retryDeferred))
        // No drain is attempted while deferred, whatever else is going on.
        XCTAssertEqual(decide(stalledSeconds: stalled, inference: true, lifecycle: true, deferred: true), .skip(.retryDeferred))
        // The persisted interval still wins, so an unchanged limit is logged once.
        XCTAssertEqual(decide(stalledSeconds: stalled, deferred: true, last: now.addingTimeInterval(-60)), .skip(.recentlyRestarted))
        XCTAssertEqual(decide(stalledSeconds: nil, deferred: true), .skip(.notStalled))
        // A marker that cannot be written forbids the restart, so the next drain
        // waits a full interval: at most one drain per interval, as if it restarted.
        XCTAssertEqual(AppAttestStallRestartPolicy.retryDelay(after: .markerNotPersisted),
                       AppAttestStallRestartPolicy.minimumInterval)
        XCTAssertLessThan(AppAttestStallRestartPolicy.retryDelay(after: .drainNotAcknowledged),
                          AppAttestStallRestartPolicy.minimumInterval)
    }

    func testCallbackArrivingDuringDrainCancelsTheRestart() {
        let threshold = AppleOperationStall.threshold
        // Gate released during the drain: nothing is held any more.
        XCTAssertFalse(AppAttestStallRestartPolicy.stillStalled(heldSince: nil, now: now))
        // A newer operation holds the gate, but only briefly: not a stall.
        XCTAssertFalse(AppAttestStallRestartPolicy.stillStalled(heldSince: now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(AppAttestStallRestartPolicy.stillStalled(heldSince: now.addingTimeInterval(-threshold), now: now))
        // The original call is still unanswered after the drain.
        XCTAssertTrue(AppAttestStallRestartPolicy.stillStalled(heldSince: now.addingTimeInterval(-threshold - 120), now: now))
    }

    func testLifecycleTakeoverDuringDrainCancelsTheRestart() {
        let stuck = now.addingTimeInterval(-AppleOperationStall.threshold - 120)
        XCTAssertEqual(AppAttestStallRestartPolicy.afterDrain(updateOwnsDrain: true, heldSince: stuck, now: now), .restart)
        XCTAssertEqual(AppAttestStallRestartPolicy.afterDrain(updateOwnsDrain: true, heldSince: nil, now: now), .recovered)
        // A stop or shutdown that took over the drain wins even while the
        // Apple call is still stuck: the provider must not be relaunched.
        XCTAssertEqual(AppAttestStallRestartPolicy.afterDrain(updateOwnsDrain: false, heldSince: stuck, now: now), .lifecycleTookOver)
        XCTAssertEqual(AppAttestStallRestartPolicy.afterDrain(updateOwnsDrain: false, heldSince: nil, now: now), .lifecycleTookOver)
    }

    func testMarkerPersistsAcrossInstancesAndFailsClosedWhenDamaged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = AppAttestStallRestartMarker(directory: directory)
        XCTAssertNil(marker.lastRestart())
        try marker.record(now)
        XCTAssertEqual(AppAttestStallRestartMarker(directory: directory).lastRestart(), now)
        let mode = try FileManager.default.attributesOfItem(atPath: marker.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        try Data("not json".utf8).write(to: marker.url)
        let damaged = try XCTUnwrap(marker.lastRestart())
        XCTAssertLessThan(abs(damaged.timeIntervalSinceNow), 60, "a damaged marker counts as a restart just now")
    }
}
